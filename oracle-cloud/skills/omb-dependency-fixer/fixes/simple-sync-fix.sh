#!/bin/bash
#
# simple-sync-fix.sh - Simple OMB synchronization fix
#
# Strategy: Use the EXISTING successful OMB build and deploy identical
# copies to all clients. No pom.xml modifications, no rebuilds.
# This ensures coordinator and workers have identical libraries.

set -euo pipefail

OMB_PATH="${1:-}"
CLIENT_IPS="${2:-}"
SSH_KEY="${3:-~/.ssh/id_rsa}"

if [[ -z "$OMB_PATH" ]] || [[ -z "$CLIENT_IPS" ]]; then
    echo "Usage: $0 <omb-path> <client-ips> [ssh-key]"
    exit 1
fi

IFS=',' read -ra CLIENTS <<< "$CLIENT_IPS"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== Simple OMB Synchronization Fix ===${NC}"
echo "Strategy: Deploy identical OMB installation to all clients"
echo "Clients: ${#CLIENTS[@]}"
echo

# Step 1: Find or create OMB build
echo -e "${YELLOW}Step 1: Locating OMB build${NC}"

BUILD_DIR=$(find "$OMB_PATH/benchmark-framework/target" -maxdepth 2 -type d -name "benchmark-framework-*" ! -name "*.jar" 2>/dev/null | head -1)

if [[ -z "$BUILD_DIR" ]]; then
    echo "  No existing build found. Building now..."
    cd "$OMB_PATH"

    if mvn clean install -DskipTests -Dlicense.skip=true > /tmp/omb-build.log 2>&1; then
        BUILD_DIR=$(find "$OMB_PATH/benchmark-framework/target" -maxdepth 2 -type d -name "benchmark-framework-*" ! -name "*.jar" | head -1)
        echo -e "${GREEN}  ✓ Build completed${NC}"
    else
        echo -e "${RED}  ✗ Build failed${NC}"
        tail -30 /tmp/omb-build.log
        exit 1
    fi
else
    echo -e "${GREEN}  ✓ Found existing build: $BUILD_DIR${NC}"
fi

# Step 2: Create complete package
echo -e "${YELLOW}Step 2: Creating deployment package${NC}"

cd "$BUILD_DIR"
PACKAGE_SIZE=$(du -sh . | cut -f1)
echo "  Package size: $PACKAGE_SIZE"

tar czf /tmp/omb-deployment.tar.gz . 2>/dev/null

TARBALL_SIZE=$(du -h /tmp/omb-deployment.tar.gz | cut -f1)
echo -e "${GREEN}  ✓ Package created: $TARBALL_SIZE${NC}"

# Step 3: Deploy to all clients
echo -e "${YELLOW}Step 3: Deploying to clients${NC}"

for client_ip in "${CLIENTS[@]}"; do
    echo "  → $client_ip"

    # Stop workers
    ssh -i "$SSH_KEY" root@"$client_ip" "pkill -f benchmark-worker || pkill -f java || true" >/dev/null 2>&1
    sleep 1

    # Backup existing installation (just in case)
    ssh -i "$SSH_KEY" root@"$client_ip" "if [ -d /opt/benchmark ]; then mv /opt/benchmark /opt/benchmark.backup-\$(date +%s) 2>/dev/null || true; fi" >/dev/null 2>&1

    # Create fresh directory
    ssh -i "$SSH_KEY" root@"$client_ip" "mkdir -p /opt/benchmark" >/dev/null 2>&1

    # Copy package
    echo -n "    Copying... "
    scp -q -i "$SSH_KEY" /tmp/omb-deployment.tar.gz root@"$client_ip":/tmp/ 2>/dev/null
    echo "done"

    # Extract
    echo -n "    Extracting... "
    ssh -i "$SSH_KEY" root@"$client_ip" "cd /opt/benchmark && tar xzf /tmp/omb-deployment.tar.gz && rm /tmp/omb-deployment.tar.gz" >/dev/null 2>&1
    echo "done"

    # Start worker
    echo -n "    Starting worker... "
    ssh -i "$SSH_KEY" root@"$client_ip" "cd /opt/benchmark && nohup bin/benchmark-worker --port 8080 --stats-port 9091 > /tmp/worker.log 2>&1 & echo \$! > /tmp/worker.pid" >/dev/null 2>&1
    echo "done"

    echo -e "${GREEN}    ✓ Complete${NC}"
done

# Step 4: Wait and validate
echo -e "${YELLOW}Step 4: Validating workers${NC}"
echo "  Waiting 20 seconds for initialization..."
sleep 20

HEALTHY=0
FAILED=0

for client_ip in "${CLIENTS[@]}"; do
    echo -n "  $client_ip: "

    # Check HTTP endpoint
    if ssh -i "$SSH_KEY" root@"$client_ip" "curl -s --max-time 3 http://localhost:8080/stats >/dev/null 2>&1"; then
        # Check for Netty errors in logs
        NETTY_ERRORS=$(ssh -i "$SSH_KEY" root@"$client_ip" "tail -50 /tmp/worker.log 2>/dev/null | grep -c 'NoSuchMethodError.*isContiguous' || echo 0")

        if [[ "$NETTY_ERRORS" -eq 0 ]]; then
            echo -e "${GREEN}✓ healthy (no Netty errors)${NC}"
            ((HEALTHY++))
        else
            echo -e "${RED}✗ Netty errors still present${NC}"
            ((FAILED++))
        fi
    else
        echo -e "${RED}✗ not responding${NC}"
        ((FAILED++))
    fi
done

echo
echo "Results: $HEALTHY healthy, $FAILED failed"

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}=== Fix Successful ===${NC}"
    echo -e "${GREEN}All ${#CLIENTS[@]} workers are healthy and Netty issue resolved!${NC}"
    echo
    echo "Next step: Run benchmark"
    echo "  ssh root@${CLIENTS[0]}"
    echo "  cd /opt/benchmark"
    echo "  bin/benchmark --drivers driver-redpanda/<driver>.yaml --workers-file workers.yaml workloads/<workload>.yaml"
    exit 0
else
    echo -e "${YELLOW}=== Partial Success ===${NC}"
    echo "Some workers still have issues. May need deeper debugging."
    exit 1
fi
