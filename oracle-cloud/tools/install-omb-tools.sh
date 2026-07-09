#!/bin/bash
#
# install-omb-tools.sh - Automated OpenMessaging Benchmark installation
#
# Installs OMB on client machines and automatically configures:
#   - Java 11+ (required for OMB)
#   - Maven (for building from source)
#   - OMB benchmark tools
#   - JMX agent JARs (critical for worker metrics)
#   - workers.yaml configuration file
#
# Usage:
#   ./install-omb-tools.sh [--client-ips IP1,IP2,...] [--jumpbox HOST] [--ssh-key PATH] [--omb-source PATH]
#
# Examples:
#   # Install on remote clients via jumpbox
#   ./install-omb-tools.sh \
#     --client-ips 172.1.1.10,172.1.1.11,172.1.1.12 \
#     --jumpbox 97.107.137.207 \
#     --ssh-key ~/.ssh/redpanda_aws
#
#   # Use existing OMB build from jumpbox
#   ./install-omb-tools.sh \
#     --client-ips 172.1.1.10,172.1.1.11 \
#     --jumpbox 97.107.137.207 \
#     --omb-source /root/bench/openmessaging-benchmark
#

set -euo pipefail

# Default values
CLIENT_IPS=""
JUMPBOX=""
SSH_KEY="~/.ssh/id_rsa"
SSH_USER="root"
OMB_SOURCE=""
OMB_VERSION="main"
OMB_INSTALL_DIR="/opt/benchmark"
WORKER_PORT="8080"
STATS_PORT="9091"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --client-ips)
            CLIENT_IPS="$2"
            shift 2
            ;;
        --jumpbox)
            JUMPBOX="$2"
            shift 2
            ;;
        --ssh-key)
            SSH_KEY="$2"
            shift 2
            ;;
        --ssh-user)
            SSH_USER="$2"
            shift 2
            ;;
        --omb-source)
            OMB_SOURCE="$2"
            shift 2
            ;;
        --omb-version)
            OMB_VERSION="$2"
            shift 2
            ;;
        --install-dir)
            OMB_INSTALL_DIR="$2"
            shift 2
            ;;
        -h|--help)
            grep '^#' "$0" | grep -v '#!/bin/bash' | sed 's/^# *//'
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown option $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate required parameters
if [[ -z "$CLIENT_IPS" ]]; then
    echo -e "${RED}Error: --client-ips is required${NC}"
    exit 1
fi

# Convert client IPs to array
IFS=',' read -ra CLIENT_ARRAY <<< "$CLIENT_IPS"

echo -e "${GREEN}=== OpenMessaging Benchmark Installation ===${NC}"
echo "Client count: ${#CLIENT_ARRAY[@]}"
echo "Install directory: $OMB_INSTALL_DIR"
echo "Worker port: $WORKER_PORT"
echo "Stats port: $STATS_PORT"
if [[ -n "$JUMPBOX" ]]; then
    echo "Jumpbox: $JUMPBOX"
fi
if [[ -n "$OMB_SOURCE" ]]; then
    echo "OMB source: $OMB_SOURCE (existing build)"
else
    echo "OMB version: $OMB_VERSION (will build from source)"
fi
echo

# Function to execute command on remote host
run_remote() {
    local client_ip=$1
    local command=$2

    if [[ -n "$JUMPBOX" ]]; then
        ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SSH_USER@$JUMPBOX" \
            "ssh -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@$client_ip '$command'"
    else
        ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SSH_USER@$client_ip" "$command"
    fi
}

# Function to copy file to remote host
copy_to_remote() {
    local client_ip=$1
    local local_file=$2
    local remote_file=$3

    if [[ -n "$JUMPBOX" ]]; then
        # Copy via jumpbox (two-stage)
        local temp_file="/tmp/$(basename "$local_file")"
        scp -o StrictHostKeyChecking=no -i "$SSH_KEY" "$local_file" "$SSH_USER@$JUMPBOX:$temp_file"
        ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SSH_USER@$JUMPBOX" \
            "scp -o StrictHostKeyChecking=no -i $SSH_KEY $temp_file $SSH_USER@$client_ip:$remote_file"
    else
        scp -o StrictHostKeyChecking=no -i "$SSH_KEY" "$local_file" "$SSH_USER@$client_ip:$remote_file"
    fi
}

# Function to install Java on client
install_java() {
    local client_ip=$1

    echo -e "${YELLOW}  Installing Java 11...${NC}"

    OS_TYPE=$(run_remote "$client_ip" "cat /etc/os-release | grep '^ID=' | cut -d'=' -f2 | tr -d '\"'")

    case "$OS_TYPE" in
        ubuntu|debian)
            run_remote "$client_ip" "
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -qq
                apt-get install -y openjdk-11-jdk maven curl
            "
            ;;
        rhel|centos|rocky|almalinux|fedora)
            run_remote "$client_ip" "
                yum install -y java-11-openjdk java-11-openjdk-devel maven curl
            "
            ;;
        *)
            echo -e "${RED}  Error: Unsupported OS: $OS_TYPE${NC}"
            return 1
            ;;
    esac

    echo -e "${GREEN}  ✓ Java installed${NC}"
}

# Function to build OMB from source on client
build_omb_on_client() {
    local client_ip=$1

    echo -e "${YELLOW}  Building OMB from source...${NC}"

    run_remote "$client_ip" "
        set -euo pipefail

        # Clone repository if not exists
        if [[ ! -d /tmp/openmessaging-benchmark ]]; then
            cd /tmp
            git clone https://github.com/redpanda-data/openmessaging-benchmark.git
        fi

        cd /tmp/openmessaging-benchmark
        git checkout $OMB_VERSION
        git pull

        # Build with Maven
        mvn clean install -DskipTests -Dlicense.skip=true

        # Create installation directory
        mkdir -p $OMB_INSTALL_DIR

        # Copy built artifacts
        cp -r benchmark-framework/target/benchmark-framework-*-bin/benchmark-framework-*/* $OMB_INSTALL_DIR/

        echo 'OMB built and installed successfully'
    "

    echo -e "${GREEN}  ✓ OMB built from source${NC}"
}

# Function to copy pre-built OMB from jumpbox
copy_omb_from_jumpbox() {
    local client_ip=$1

    echo -e "${YELLOW}  Copying pre-built OMB from jumpbox...${NC}"

    if [[ -z "$JUMPBOX" ]]; then
        echo -e "${RED}  Error: --jumpbox required when using --omb-source${NC}"
        return 1
    fi

    # Create tarball on jumpbox and copy to client
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SSH_USER@$JUMPBOX" "
        cd $OMB_SOURCE/benchmark-framework/target

        # Find the built directory
        BUILD_DIR=\$(ls -d benchmark-framework-*-bin/benchmark-framework-* 2>/dev/null | head -1)

        if [[ -z \"\$BUILD_DIR\" ]]; then
            echo 'Error: No built OMB found. Run mvn install first.'
            exit 1
        fi

        # Create tarball
        cd \$BUILD_DIR
        tar czf /tmp/omb-build.tar.gz *
    "

    # Copy tarball to client
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SSH_USER@$JUMPBOX" \
        "scp -o StrictHostKeyChecking=no -i $SSH_KEY /tmp/omb-build.tar.gz $SSH_USER@$client_ip:/tmp/"

    # Extract on client
    run_remote "$client_ip" "
        mkdir -p $OMB_INSTALL_DIR
        tar xzf /tmp/omb-build.tar.gz -C $OMB_INSTALL_DIR
        rm /tmp/omb-build.tar.gz
    "

    echo -e "${GREEN}  ✓ OMB copied from jumpbox${NC}"
}

# Function to copy JMX agent JAR (critical fix)
copy_jmx_agent() {
    local client_ip=$1

    echo -e "${YELLOW}  Copying JMX agent JAR...${NC}"

    # Find JMX agent JAR in OMB installation
    JMX_JAR=$(run_remote "$client_ip" "find $OMB_INSTALL_DIR -name 'jmx_prometheus_javaagent*.jar' 2>/dev/null | head -1 || echo ''")

    if [[ -z "$JMX_JAR" ]]; then
        echo -e "${RED}  Warning: JMX agent JAR not found. Downloading...${NC}"

        run_remote "$client_ip" "
            mkdir -p $OMB_INSTALL_DIR/lib
            curl -L -o $OMB_INSTALL_DIR/lib/jmx_prometheus_javaagent-0.17.2.jar \
                https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/0.17.2/jmx_prometheus_javaagent-0.17.2.jar
        "
        JMX_JAR="$OMB_INSTALL_DIR/lib/jmx_prometheus_javaagent-0.17.2.jar"
    fi

    # Copy to worker directories (if they exist)
    run_remote "$client_ip" "
        for worker_dir in $OMB_INSTALL_DIR/worker-*; do
            if [[ -d \"\$worker_dir\" ]]; then
                cp $JMX_JAR \"\$worker_dir/\"
            fi
        done
    "

    echo -e "${GREEN}  ✓ JMX agent JAR copied${NC}"
}

# Function to create workers.yaml
create_workers_config() {
    echo -e "${YELLOW}Generating workers.yaml configuration...${NC}"

    local config_file="/tmp/workers.yaml"

    cat > "$config_file" << EOF
# OpenMessaging Benchmark Workers Configuration
# Generated by install-omb-tools.sh
# $(date)

EOF

    for client_ip in "${CLIENT_ARRAY[@]}"; do
        echo "- http://${client_ip}:${WORKER_PORT}" >> "$config_file"
    done

    echo -e "${GREEN}✓ workers.yaml created${NC}"
    echo -e "${BLUE}Contents:${NC}"
    cat "$config_file"
    echo

    # Copy to primary client
    PRIMARY_CLIENT="${CLIENT_ARRAY[0]}"
    echo -e "${YELLOW}Copying workers.yaml to primary client ($PRIMARY_CLIENT)...${NC}"

    if [[ -n "$JUMPBOX" ]]; then
        scp -o StrictHostKeyChecking=no -i "$SSH_KEY" "$config_file" "$SSH_USER@$JUMPBOX:/tmp/workers.yaml"
        ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SSH_USER@$JUMPBOX" \
            "scp -o StrictHostKeyChecking=no -i $SSH_KEY /tmp/workers.yaml $SSH_USER@$PRIMARY_CLIENT:$OMB_INSTALL_DIR/"
    else
        scp -o StrictHostKeyChecking=no -i "$SSH_KEY" "$config_file" "$SSH_USER@$PRIMARY_CLIENT:$OMB_INSTALL_DIR/"
    fi

    echo -e "${GREEN}✓ workers.yaml deployed${NC}"
}

# Function to install OMB on a single client
install_omb_on_client() {
    local client_ip=$1

    echo -e "${YELLOW}Installing OMB on $client_ip...${NC}"

    # Step 1: Install Java
    install_java "$client_ip"

    # Step 2: Install OMB
    if [[ -n "$OMB_SOURCE" ]]; then
        copy_omb_from_jumpbox "$client_ip"
    else
        build_omb_on_client "$client_ip"
    fi

    # Step 3: Copy JMX agent (critical fix for worker metrics)
    copy_jmx_agent "$client_ip"

    echo -e "${GREEN}✓ OMB installed on $client_ip${NC}"
}

# Function to verify installation
verify_installation() {
    local client_ip=$1

    echo -n "  Verifying installation on $client_ip... "

    # Check if benchmark script exists
    if run_remote "$client_ip" "test -f $OMB_INSTALL_DIR/bin/benchmark"; then
        # Check Java version
        JAVA_VERSION=$(run_remote "$client_ip" "java -version 2>&1 | head -1 | awk -F'\"' '{print \$2}'")
        echo -e "${GREEN}✓ (Java $JAVA_VERSION)${NC}"
        return 0
    else
        echo -e "${RED}✗ benchmark script not found${NC}"
        return 1
    fi
}

# Function to start workers
start_workers() {
    echo -e "${GREEN}Starting benchmark workers...${NC}"
    echo

    for client_ip in "${CLIENT_ARRAY[@]}"; do
        echo -e "${YELLOW}Starting worker on $client_ip...${NC}"

        # Stop any existing workers
        run_remote "$client_ip" "pkill -f benchmark-worker || true" 2>/dev/null || true

        # Start new worker
        run_remote "$client_ip" "
            cd $OMB_INSTALL_DIR
            nohup bin/benchmark-worker --port $WORKER_PORT --stats-port $STATS_PORT > /tmp/worker.log 2>&1 &
            echo \$! > /tmp/worker.pid
        "

        echo -e "${GREEN}  ✓ Worker started${NC}"
        sleep 2
    done

    echo
    echo -e "${YELLOW}Waiting 10 seconds for workers to initialize...${NC}"
    sleep 10

    # Verify workers
    echo -e "${GREEN}Verifying workers...${NC}"
    for client_ip in "${CLIENT_ARRAY[@]}"; do
        echo -n "  $client_ip: "
        if run_remote "$client_ip" "curl -s --max-time 2 http://localhost:$WORKER_PORT/stats >/dev/null 2>&1"; then
            echo -e "${GREEN}✓ healthy${NC}"
        else
            echo -e "${RED}✗ not responding${NC}"
        fi
    done
}

# Main installation loop
echo -e "${GREEN}Step 1: Installing OMB on all clients${NC}"
echo

FAILED_CLIENTS=()

for client_ip in "${CLIENT_ARRAY[@]}"; do
    if install_omb_on_client "$client_ip"; then
        :  # Success
    else
        echo -e "${RED}  ✗ Failed to install on $client_ip${NC}"
        FAILED_CLIENTS+=("$client_ip")
    fi
    echo
done

# Verification step
echo -e "${GREEN}Step 2: Verifying installations${NC}"
echo

for client_ip in "${CLIENT_ARRAY[@]}"; do
    verify_installation "$client_ip" || true
done

echo

# Create workers.yaml
echo -e "${GREEN}Step 3: Creating workers configuration${NC}"
echo

create_workers_config

echo

# Start workers
echo -e "${GREEN}Step 4: Starting workers${NC}"
echo

start_workers

echo

# Summary
if [[ ${#FAILED_CLIENTS[@]} -eq 0 ]]; then
    echo -e "${GREEN}=== Installation Complete ===${NC}"
    echo -e "${GREEN}✓ Successfully installed OMB on all ${#CLIENT_ARRAY[@]} clients${NC}"
    echo
    echo "Next steps:"
    echo "  1. Copy workload YAML to: $OMB_INSTALL_DIR/workloads/"
    echo "  2. Copy driver YAML to: $OMB_INSTALL_DIR/driver-redpanda/"
    echo "  3. Start benchmark with:"
    echo "     cd $OMB_INSTALL_DIR"
    echo "     bin/benchmark --drivers driver-redpanda/redpanda.yaml --workers-file workers.yaml workloads/workload.yaml"
    exit 0
else
    echo -e "${RED}=== Installation Failed ===${NC}"
    echo -e "${RED}Failed to install on ${#FAILED_CLIENTS[@]} client(s):${NC}"
    for client in "${FAILED_CLIENTS[@]}"; do
        echo "  - $client"
    done
    exit 1
fi
