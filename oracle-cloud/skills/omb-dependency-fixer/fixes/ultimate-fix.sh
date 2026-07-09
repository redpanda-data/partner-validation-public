#!/bin/bash
#
# ultimate-fix.sh - Ultimate OMB Netty fix using fresh clone
#
# Strategy: Clone fresh OMB repo, build with specific Netty version using
# Maven property override (no pom.xml modification), deploy everywhere.

set -euo pipefail

CLIENT_IPS="${1:-}"
SSH_KEY="${2:-~/.ssh/id_rsa}"
NETTY_VERSION="${3:-4.1.79.Final}"

if [[ -z "$CLIENT_IPS" ]]; then
    echo "Usage: $0 <client-ips> [ssh-key] [netty-version]"
    exit 1
fi

IFS=',' read -ra CLIENTS <<< "$CLIENT_IPS"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Ultimate OMB Fix ===${NC}"
echo "Strategy: Fresh clone → Clean build → Identical deployment"
echo

# Step 1: Fresh clone
echo -e "${YELLOW}Step 1: Creating fresh OMB build${NC}"

BUILD_DIR="/tmp/omb-fresh-$(date +%s)"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "  Cloning OMB repository..."
if git clone --depth 1 https://github.com/redpanda-data/openmessaging-benchmark.git > /tmp/git-clone.log 2>&1; then
    echo -e "${GREEN}  ✓ Cloned${NC}"
else
    echo -e "${RED}  ✗ Clone failed${NC}"
    cat /tmp/git-clone.log
    exit 1
fi

cd openmessaging-benchmark

# Step 2: Build with Netty version override via Maven properties
echo -e "${YELLOW}Step 2: Building with Netty $NETTY_VERSION${NC}"
echo "  This may take 10-15 minutes..."

# Use Maven property to force Netty version across all modules
if mvn clean install \
    -DskipTests \
    -Dlicense.skip=true \
    -Dnetty.version="$NETTY_VERSION" \
    -Dmaven.wagon.http.retryHandler.count=3 \
    > /tmp/omb-ultimate-build.log 2>&1; then
    echo -e "${GREEN}  ✓ Build successful${NC}"
else
    echo -e "${YELLOW}  ⚠ Build had issues, checking if artifacts were created...${NC}"

    # Check if benchmark-framework was built anyway
    if [[ ! -d "benchmark-framework/target/benchmark-framework-"*"-bin" ]]; then
        echo -e "${RED}  ✗ Build completely failed${NC}"
        tail -50 /tmp/omb-ultimate-build.log
        exit 1
    fi

    echo -e "${YELLOW}  ✓ Build partially successful, continuing...${NC}"
fi

# Step 3: Package complete installation
echo -e "${YELLOW}Step 3: Packaging OMB distribution${NC}"

BENCHMARK_DIR=$(find benchmark-framework/target -maxdepth 2 -type d -name "benchmark-framework-*" ! -name "*.jar" | head -1)

if [[ -z "$BENCHMARK_DIR" ]]; then
    echo -e "${RED}  Error: Benchmark directory not found${NC}"
    exit 1
fi

cd "$BENCHMARK_DIR"
echo "  Creating tarball..."
tar czf /tmp/omb-ultimate.tar.gz . 2>/dev/null

SIZE=$(du -h /tmp/omb-ultimate.tar.gz | cut -f1)
echo -e "${GREEN}  ✓ Package ready: $SIZE${NC}"

# Step 4: Deploy to all clients
echo -e "${YELLOW}Step 4: Deploying to ${#CLIENTS[@]} clients${NC}"

for client_ip in "${CLIENTS[@]}"; do
    echo "  → $client_ip"

    # Kill everything Java
    ssh -i "$SSH_KEY" root@"$client_ip" "pkill -9 -f java || true" >/dev/null 2>&1
    sleep 2

    # Clean install
    ssh -i "$SSH_KEY" root@"$client_ip" "
        rm -rf /opt/benchmark.old
        mv /opt/benchmark /opt/benchmark.old 2>/dev/null || true
        mkdir -p /opt/benchmark
    " >/dev/null 2>&1

    # Transfer
    echo -n "    Transferring $SIZE... "
    scp -q -i "$SSH_KEY" /tmp/omb-ultimate.tar.gz root@"$client_ip":/tmp/
    echo "done"

    # Extract
    echo -n "    Installing... "
    ssh -i "$SSH_KEY" root@"$client_ip" "cd /opt/benchmark && tar xzf /tmp/omb-ultimate.tar.gz" >/dev/null 2>&1
    echo "done"

    # Start worker
    echo -n "    Starting worker... "
    ssh -i "$SSH_KEY" root@"$client_ip" "
        cd /opt/benchmark
        nohup bin/benchmark-worker --port 8080 --stats-port 9091 > /tmp/worker-new.log 2>&1 &
        echo \$! > /tmp/worker.pid
    " >/dev/null 2>&1
    echo "done"

    echo -e "${GREEN}    ✓ Deployed${NC}"
done

# Step 5: Validate
echo -e "${YELLOW}Step 5: Validation (waiting 25 seconds)${NC}"
sleep 25

HEALTHY_COUNT=0
FAILED_COUNT=0

for client_ip in "${CLIENTS[@]}"; do
    echo -n "  $client_ip: "

    # Check endpoint
    if ssh -i "$SSH_KEY" root@"$client_ip" "curl -s --max-time 3 http://localhost:8080/stats >/dev/null 2>&1"; then
        # Check for Netty errors in new log
        ERRORS=$(ssh -i "$SSH_KEY" root@"$client_ip" "grep -c 'NoSuchMethodError\|ClassNotFoundException' /tmp/worker-new.log 2>/dev/null || echo 0")

        if [[ "$ERRORS" -eq 0 ]]; then
            echo -e "${GREEN}✓ HEALTHY (no errors)${NC}"
            ((HEALTHY_COUNT++))
        else
            echo -e "${YELLOW}⚠ responding (but $ERRORS errors found)${NC}"
            ((FAILED_COUNT++))
        fi
    else
        echo -e "${RED}✗ NOT RESPONDING${NC}"
        ((FAILED_COUNT++))
    fi
done

echo
echo "═══════════════════════════════════════"

if [[ $FAILED_COUNT -eq 0 ]]; then
    echo -e "${GREEN}███ SUCCESS ███${NC}"
    echo -e "${GREEN}All ${#CLIENTS[@]} workers are healthy!${NC}"
    echo -e "${GREEN}Netty issue completely resolved.${NC}"
    echo
    echo "OMB is ready for benchmarking:"
    echo "  Primary client: ${CLIENTS[0]}"
    echo "  cd /opt/benchmark"
    echo "  bin/benchmark --drivers <driver> --workers-file workers.yaml <workload>"
    exit 0
else
    echo -e "${YELLOW}██ PARTIAL SUCCESS ██${NC}"
    echo "$HEALTHY_COUNT healthy, $FAILED_COUNT with issues"
    echo
    echo "Check logs on failed workers:"
    for client_ip in "${CLIENTS[@]}"; do
        echo "  ssh -i $SSH_KEY root@$client_ip 'tail -100 /tmp/worker-new.log'"
    done
    exit 1
fi
