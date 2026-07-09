#!/bin/bash
#
# install-redpanda.sh - Automated Redpanda installation for Ubuntu and RHEL
#
# Usage:
#   ./install-redpanda.sh [--broker-ips IP1,IP2,IP3] [--jumpbox HOST] [--ssh-key PATH] [--version VERSION]
#
# Examples:
#   # Install on remote brokers via jumpbox
#   ./install-redpanda.sh \
#     --broker-ips 172.1.1.1,172.1.1.2,172.1.1.3 \
#     --jumpbox 97.107.137.207 \
#     --ssh-key ~/.ssh/redpanda_aws
#
#   # Install specific version
#   ./install-redpanda.sh \
#     --broker-ips 172.1.1.1,172.1.1.2 \
#     --version 24.2.4
#

set -euo pipefail

# Default values
BROKER_IPS=""
JUMPBOX=""
SSH_KEY="~/.ssh/id_rsa"
REDPANDA_VERSION="latest"
SSH_USER="root"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --broker-ips)
            BROKER_IPS="$2"
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
        --version)
            REDPANDA_VERSION="$2"
            shift 2
            ;;
        --ssh-user)
            SSH_USER="$2"
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
if [[ -z "$BROKER_IPS" ]]; then
    echo -e "${RED}Error: --broker-ips is required${NC}"
    exit 1
fi

# Convert broker IPs to array
IFS=',' read -ra BROKER_ARRAY <<< "$BROKER_IPS"

echo -e "${GREEN}=== Redpanda Installation Script ===${NC}"
echo "Broker count: ${#BROKER_ARRAY[@]}"
echo "Version: $REDPANDA_VERSION"
echo "SSH Key: $SSH_KEY"
if [[ -n "$JUMPBOX" ]]; then
    echo "Jumpbox: $JUMPBOX"
fi
echo

# Function to execute command on remote host
run_remote() {
    local broker_ip=$1
    local command=$2

    if [[ -n "$JUMPBOX" ]]; then
        # Execute via jumpbox
        ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SSH_USER@$JUMPBOX" \
            "ssh -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@$broker_ip '$command'"
    else
        # Direct SSH
        ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SSH_USER@$broker_ip" "$command"
    fi
}

# Function to detect OS and install Redpanda
install_redpanda_on_broker() {
    local broker_ip=$1

    echo -e "${YELLOW}Installing Redpanda on $broker_ip...${NC}"

    # Detect OS
    OS_TYPE=$(run_remote "$broker_ip" "cat /etc/os-release | grep '^ID=' | cut -d'=' -f2 | tr -d '\"'")

    echo "  Detected OS: $OS_TYPE"

    case "$OS_TYPE" in
        ubuntu|debian)
            install_redpanda_ubuntu "$broker_ip"
            ;;
        rhel|centos|rocky|almalinux|fedora|ol)
            install_redpanda_rhel "$broker_ip"
            ;;
        *)
            echo -e "${RED}  Error: Unsupported OS: $OS_TYPE${NC}"
            return 1
            ;;
    esac

    echo -e "${GREEN}  ✓ Redpanda installed on $broker_ip${NC}"
}

# Install Redpanda on Ubuntu/Debian
install_redpanda_ubuntu() {
    local broker_ip=$1

    # Multi-line installation script
    run_remote "$broker_ip" "
        set -euo pipefail

        # Install dependencies
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y curl gnupg2 apt-transport-https ca-certificates

        # Add Redpanda repository
        curl -1sLf 'https://linux.pkg.redpanda.com/setup-redpanda.deb.sh' | bash

        # Install Redpanda
        if [[ '$REDPANDA_VERSION' == 'latest' ]]; then
            apt-get install -y redpanda
        else
            apt-get install -y redpanda=$REDPANDA_VERSION
        fi

        # Enable service (but don't start yet - cluster formation will do that)
        systemctl enable redpanda

        echo 'Redpanda installed successfully'
    "
}

# Install Redpanda on RHEL/CentOS/Rocky/AlmaLinux
install_redpanda_rhel() {
    local broker_ip=$1

    # Multi-line installation script
    run_remote "$broker_ip" "
        set -euo pipefail

        # Install dependencies
        yum install -y curl gnupg2 ca-certificates

        # Add Redpanda repository
        curl -1sLf 'https://linux.pkg.redpanda.com/setup-redpanda.rpm.sh' | bash

        # Install Redpanda
        if [[ '$REDPANDA_VERSION' == 'latest' ]]; then
            yum install -y redpanda
        else
            yum install -y redpanda-$REDPANDA_VERSION
        fi

        # Enable service (but don't start yet - cluster formation will do that)
        systemctl enable redpanda

        echo 'Redpanda installed successfully'
    "
}

# Function to verify installation
verify_installation() {
    local broker_ip=$1

    echo -n "  Verifying installation on $broker_ip... "

    # Check if rpk is available
    if run_remote "$broker_ip" "which rpk >/dev/null 2>&1"; then
        VERSION=$(run_remote "$broker_ip" "rpk version 2>&1 | grep 'rpk' | awk '{print \$2}' || echo 'unknown'")
        echo -e "${GREEN}✓ (rpk $VERSION)${NC}"
        return 0
    else
        echo -e "${RED}✗ rpk not found${NC}"
        return 1
    fi
}

# Main installation loop
echo -e "${GREEN}Step 1: Installing Redpanda on all brokers${NC}"
echo

FAILED_BROKERS=()

for broker_ip in "${BROKER_ARRAY[@]}"; do
    if install_redpanda_on_broker "$broker_ip"; then
        :  # Success
    else
        echo -e "${RED}  ✗ Failed to install on $broker_ip${NC}"
        FAILED_BROKERS+=("$broker_ip")
    fi
    echo
done

# Verification step
echo -e "${GREEN}Step 2: Verifying installations${NC}"
echo

for broker_ip in "${BROKER_ARRAY[@]}"; do
    verify_installation "$broker_ip" || true
done

echo

# Summary
if [[ ${#FAILED_BROKERS[@]} -eq 0 ]]; then
    echo -e "${GREEN}=== Installation Complete ===${NC}"
    echo -e "${GREEN}✓ Successfully installed Redpanda on all ${#BROKER_ARRAY[@]} brokers${NC}"
    echo
    echo "Next steps:"
    echo "  1. Use form-redpanda-cluster.sh to form the cluster"
    echo "  2. Verify cluster health with: rpk cluster health"
    exit 0
else
    echo -e "${RED}=== Installation Failed ===${NC}"
    echo -e "${RED}Failed to install on ${#FAILED_BROKERS[@]} broker(s):${NC}"
    for broker in "${FAILED_BROKERS[@]}"; do
        echo "  - $broker"
    done
    exit 1
fi
