#!/bin/bash
#
# fix-omb-dependencies.sh - Autonomous OMB dependency issue resolver
#
# Diagnoses and fixes common OpenMessaging Benchmark dependency conflicts,
# particularly Netty version mismatches between coordinator and workers.
#
# Usage:
#   ./fix-omb-dependencies.sh [options]
#
# Examples:
#   # Auto-detect and fix
#   ./fix-omb-dependencies.sh \
#     --omb-path ~/bench/openmessaging-benchmark \
#     --client-ips 172.1.1.10,172.1.1.11,172.1.1.12 \
#     --ssh-key ~/.ssh/redpanda_linode
#
#   # Force specific Netty version
#   ./fix-omb-dependencies.sh \
#     --omb-path ~/bench/openmessaging-benchmark \
#     --netty-version 4.1.79.Final \
#     --strategy rebuild

set -euo pipefail

# Defaults
OMB_PATH=""
CLIENT_IPS=""
SSH_KEY="~/.ssh/id_rsa"
SSH_USER="root"
NETTY_VERSION="4.1.79.Final"
STRATEGY="auto"  # auto, rebuild, copy-libs, download-missing
FORCE_REBUILD="false"
SKIP_VALIDATION="false"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --omb-path) OMB_PATH="$2"; shift 2 ;;
        --client-ips) CLIENT_IPS="$2"; shift 2 ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --ssh-user) SSH_USER="$2"; shift 2 ;;
        --netty-version) NETTY_VERSION="$2"; shift 2 ;;
        --strategy) STRATEGY="$2"; shift 2 ;;
        --force-rebuild) FORCE_REBUILD="true"; shift ;;
        --skip-validation) SKIP_VALIDATION="true"; shift ;;
        -h|--help)
            grep '^#' "$0" | grep -v '#!/bin/bash' | sed 's/^# *//'
            exit 0
            ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

# Validate
if [[ -z "$OMB_PATH" ]]; then
    echo -e "${RED}Error: --omb-path required${NC}"
    exit 1
fi

if [[ -z "$CLIENT_IPS" ]]; then
    echo -e "${RED}Error: --client-ips required${NC}"
    exit 1
fi

IFS=',' read -ra CLIENT_ARRAY <<< "$CLIENT_IPS"

echo -e "${GREEN}=== OMB Dependency Fixer ===${NC}"
echo "OMB path: $OMB_PATH"
echo "Clients: ${#CLIENT_ARRAY[@]}"
echo "Strategy: $STRATEGY"
echo

# Function to run command on client
run_on_client() {
    local client_ip=$1
    local command=$2
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SSH_USER@$client_ip" "$command"
}

# Function to detect issue type
detect_issue() {
    echo -e "${YELLOW}Step 1: Detecting issue type...${NC}"

    # Check first client's worker log
    local first_client="${CLIENT_ARRAY[0]}"
    local worker_log=$(run_on_client "$first_client" "tail -200 /opt/benchmark/worker.log 2>/dev/null || tail -200 /tmp/worker.log 2>/dev/null || echo 'NO_LOG'")

    if echo "$worker_log" | grep -q "NoSuchMethodError.*ByteBuf.isContiguous"; then
        echo -e "${BLUE}  Detected: Netty version conflict${NC}"
        DETECTED_ISSUE="netty"
        return 0
    elif echo "$worker_log" | grep -q "NoClassDefFoundError.*jmx"; then
        echo -e "${BLUE}  Detected: JMX agent missing${NC}"
        DETECTED_ISSUE="jmx"
        return 0
    elif echo "$worker_log" | grep -q "ClassNotFoundException\|NoClassDefFoundError"; then
        echo -e "${BLUE}  Detected: Missing dependency${NC}"
        DETECTED_ISSUE="missing-dep"
        return 0
    else
        echo -e "${YELLOW}  Could not auto-detect issue. Defaulting to Netty fix.${NC}"
        DETECTED_ISSUE="netty"
        return 0
    fi
}

# Function: Rebuild OMB with fixed Netty version
rebuild_omb_with_netty_fix() {
    echo -e "${YELLOW}Step 2: Rebuilding OMB with Netty $NETTY_VERSION...${NC}"

    # Backup current build
    local backup_dir="/tmp/omb-backup-$(date +%Y%m%d-%H%M%S)"
    echo "  Creating backup at $backup_dir..."
    cp -r "$OMB_PATH" "$backup_dir"

    # Modify pom.xml to force Netty version
    cd "$OMB_PATH"

    # Find root pom.xml
    if [[ ! -f "pom.xml" ]]; then
        echo -e "${RED}  Error: pom.xml not found in $OMB_PATH${NC}"
        return 1
    fi

    echo "  Modifying pom.xml to force Netty version..."

    # Create properties section if needed and set Netty version
    if grep -q "<netty.version>" pom.xml; then
        # Update existing
        sed -i "s/<netty.version>.*<\/netty.version>/<netty.version>$NETTY_VERSION<\/netty.version>/" pom.xml
    else
        # Add to properties
        sed -i '/<properties>/a\    <netty.version>'"$NETTY_VERSION"'</netty.version>' pom.xml
    fi

    echo "  Running Maven build..."
    if mvn clean install -DskipTests -Dlicense.skip=true -Dnetty.version="$NETTY_VERSION" -U > /tmp/maven-build.log 2>&1; then
        echo -e "${GREEN}  ✓ Maven build successful${NC}"
    else
        echo -e "${RED}  ✗ Maven build failed. Check /tmp/maven-build.log${NC}"
        tail -50 /tmp/maven-build.log
        return 1
    fi

    echo -e "${GREEN}  ✓ OMB rebuilt with Netty $NETTY_VERSION${NC}"
}

# Function: Copy lib directory to all workers
sync_libs_to_workers() {
    echo -e "${YELLOW}Step 3: Synchronizing libraries to all workers...${NC}"

    # Find the benchmark build directory
    local benchmark_dir=$(find "$OMB_PATH/benchmark-framework/target" -maxdepth 2 -type d -name "benchmark-framework-*" | grep -v "\.jar$" | head -1)

    if [[ -z "$benchmark_dir" ]]; then
        echo -e "${RED}  Error: Benchmark build directory not found${NC}"
        return 1
    fi

    local lib_dir="$benchmark_dir/lib"

    if [[ ! -d "$lib_dir" ]]; then
        echo -e "${RED}  Error: lib directory not found at $lib_dir${NC}"
        return 1
    fi

    echo "  Creating tarball of lib directory..."
    tar czf /tmp/omb-lib-fixed.tar.gz -C "$benchmark_dir" lib/

    echo "  Deploying to workers..."
    for client_ip in "${CLIENT_ARRAY[@]}"; do
        echo "    → $client_ip"

        # Copy tarball
        scp -q -i "$SSH_KEY" /tmp/omb-lib-fixed.tar.gz "$SSH_USER@$client_ip:/tmp/"

        # Stop worker, extract, restart
        run_on_client "$client_ip" "
            pkill -f benchmark-worker || true
            sleep 2
            cd /opt/benchmark
            rm -rf lib
            tar xzf /tmp/omb-lib-fixed.tar.gz
            nohup bin/benchmark-worker --port 8080 --stats-port 9091 > /tmp/worker.log 2>&1 &
            echo \$! > /tmp/worker.pid
        " >/dev/null 2>&1

        echo -e "${GREEN}      ✓ Deployed${NC}"
    done

    echo -e "${GREEN}  ✓ All workers updated${NC}"
}

# Function: Validate workers are healthy
validate_workers() {
    if [[ "$SKIP_VALIDATION" == "true" ]]; then
        echo "  Skipping validation (--skip-validation)"
        return 0
    fi

    echo -e "${YELLOW}Step 4: Validating workers...${NC}"

    echo "  Waiting 15 seconds for workers to initialize..."
    sleep 15

    local failures=0

    for client_ip in "${CLIENT_ARRAY[@]}"; do
        echo -n "  $client_ip: "

        if run_on_client "$client_ip" "curl -s --max-time 3 http://localhost:8080/stats >/dev/null 2>&1"; then
            # Check for errors in log
            local recent_errors=$(run_on_client "$client_ip" "tail -50 /tmp/worker.log 2>/dev/null | grep -i 'NoSuchMethodError\|NoClassDefFoundError\|Exception' | wc -l")

            if [[ "$recent_errors" -gt 0 ]]; then
                echo -e "${YELLOW}⚠ responding but has errors${NC}"
                ((failures++))
            else
                echo -e "${GREEN}✓ healthy${NC}"
            fi
        else
            echo -e "${RED}✗ not responding${NC}"
            ((failures++))
        fi
    done

    if [[ $failures -eq 0 ]]; then
        echo -e "${GREEN}  ✓ All workers healthy${NC}"
        return 0
    else
        echo -e "${YELLOW}  ⚠ $failures worker(s) have issues${NC}"
        return 1
    fi
}

# Main execution
main() {
    # Detect issue
    detect_issue

    # Choose strategy
    if [[ "$STRATEGY" == "auto" ]]; then
        case "$DETECTED_ISSUE" in
            netty) STRATEGY="rebuild" ;;
            jmx) STRATEGY="download-jmx" ;;
            *) STRATEGY="rebuild" ;;
        esac
        echo -e "${BLUE}Auto-selected strategy: $STRATEGY${NC}"
        echo
    fi

    # Apply fix
    case "$STRATEGY" in
        rebuild)
            rebuild_omb_with_netty_fix
            sync_libs_to_workers
            ;;
        copy-libs)
            sync_libs_to_workers
            ;;
        download-jmx)
            echo "  JMX fix not yet implemented"
            return 1
            ;;
        *)
            echo -e "${RED}Unknown strategy: $STRATEGY${NC}"
            return 1
            ;;
    esac

    # Validate
    validate_workers

    local validation_result=$?

    echo
    if [[ $validation_result -eq 0 ]]; then
        echo -e "${GREEN}=== Fix Complete ===${NC}"
        echo -e "${GREEN}OMB is ready for benchmark execution${NC}"
        echo
        echo "Next steps:"
        echo "  1. Start benchmark on primary client"
        echo "  2. Monitor with: ssh root@${CLIENT_ARRAY[0]} 'tail -f /opt/benchmark/*.log'"
        return 0
    else
        echo -e "${YELLOW}=== Fix Applied with Warnings ===${NC}"
        echo -e "${YELLOW}Some workers may still have issues. Check logs manually.${NC}"
        return 1
    fi
}

# Execute
main
