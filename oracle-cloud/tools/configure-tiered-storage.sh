#!/bin/bash
#
# configure-tiered-storage.sh - Configure Redpanda cluster for tiered storage
#
# This script configures an existing Redpanda cluster to use S3-compatible
# object storage for tiered storage (cloud storage feature).
#
# Usage:
#   ./configure-tiered-storage.sh [options]
#
# Examples:
#   # Linode Object Storage
#   ./configure-tiered-storage.sh \
#     --broker-ip 172.1.1.1 \
#     --jumpbox 97.107.137.207 \
#     --bucket my-redpanda-bucket \
#     --region us-east-1 \
#     --endpoint us-east-1.linodeobjects.com \
#     --access-key LINODE_ACCESS_KEY \
#     --secret-key LINODE_SECRET_KEY
#
#   # AWS S3
#   ./configure-tiered-storage.sh \
#     --broker-ip 172.1.1.1 \
#     --bucket my-redpanda-bucket \
#     --region us-west-2 \
#     --access-key AWS_ACCESS_KEY \
#     --secret-key AWS_SECRET_KEY

set -euo pipefail

# Default values
BROKER_IP=""
JUMPBOX=""
SSH_KEY="~/.ssh/id_rsa"
SSH_USER="root"
BUCKET=""
REGION=""
ACCESS_KEY=""
SECRET_KEY=""
ENDPOINT=""
PORT="443"
DISABLE_TLS="false"
SEGMENT_SIZE="134217728"  # 128MB default
UPLOAD_INTERVAL="300"     # 5 minutes

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --broker-ip)
            BROKER_IP="$2"
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
        --bucket)
            BUCKET="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --access-key)
            ACCESS_KEY="$2"
            shift 2
            ;;
        --secret-key)
            SECRET_KEY="$2"
            shift 2
            ;;
        --endpoint)
            ENDPOINT="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --disable-tls)
            DISABLE_TLS="true"
            shift
            ;;
        --segment-size)
            SEGMENT_SIZE="$2"
            shift 2
            ;;
        --upload-interval)
            UPLOAD_INTERVAL="$2"
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
if [[ -z "$BROKER_IP" ]]; then
    echo -e "${RED}Error: --broker-ip is required${NC}"
    exit 1
fi

if [[ -z "$BUCKET" || -z "$REGION" || -z "$ACCESS_KEY" || -z "$SECRET_KEY" ]]; then
    echo -e "${RED}Error: --bucket, --region, --access-key, and --secret-key are required${NC}"
    exit 1
fi

echo -e "${GREEN}=== Redpanda Tiered Storage Configuration ===${NC}"
echo "Broker IP: $BROKER_IP"
echo "Bucket: $BUCKET"
echo "Region: $REGION"
if [[ -n "$ENDPOINT" ]]; then
    echo "Endpoint: $ENDPOINT:$PORT"
fi
echo "TLS: $([ "$DISABLE_TLS" = "false" ] && echo "enabled" || echo "disabled")"
echo

# Function to execute rpk command on broker
run_rpk() {
    local command=$1

    if [[ -n "$JUMPBOX" ]]; then
        ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SSH_USER@$JUMPBOX" \
            "ssh -o StrictHostKeyChecking=no -i $SSH_KEY $SSH_USER@$BROKER_IP '$command'"
    else
        ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" "$SSH_USER@$BROKER_IP" "$command"
    fi
}

# Function to set cluster config
set_config() {
    local key=$1
    local value=$2

    echo -n "  Setting $key... "
    if run_rpk "rpk cluster config set $key '$value'" >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        echo -e "${RED}Error: Failed to set $key${NC}"
        return 1
    fi
}

echo -e "${YELLOW}Step 1: Checking cluster health${NC}"
if run_rpk "rpk cluster health" >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Cluster is healthy${NC}"
else
    echo -e "${RED}✗ Cluster is not healthy. Fix cluster before configuring tiered storage.${NC}"
    exit 1
fi
echo

echo -e "${YELLOW}Step 2: Checking for enterprise license${NC}"
LICENSE_CHECK=$(run_rpk "rpk cluster license info" 2>&1 || echo "NO_LICENSE")

if echo "$LICENSE_CHECK" | grep -q "NO_LICENSE\|expired\|invalid"; then
    echo -e "${RED}⚠ No valid enterprise license detected${NC}"
    echo -e "${YELLOW}Tiered storage requires an enterprise license.${NC}"
    echo -e "${YELLOW}Continuing anyway - you may need to add a license later.${NC}"
    echo
else
    echo -e "${GREEN}✓ Enterprise license found${NC}"
    echo
fi

echo -e "${YELLOW}Step 3: Configuring object storage credentials${NC}"

# Core configuration
set_config "cloud_storage_region" "$REGION"
set_config "cloud_storage_bucket" "$BUCKET"
set_config "cloud_storage_access_key" "$ACCESS_KEY"
set_config "cloud_storage_secret_key" "$SECRET_KEY"

# Endpoint configuration (for S3-compatible services)
if [[ -n "$ENDPOINT" ]]; then
    set_config "cloud_storage_api_endpoint" "$ENDPOINT"
    set_config "cloud_storage_api_endpoint_port" "$PORT"
fi

# TLS configuration
set_config "cloud_storage_disable_tls" "$DISABLE_TLS"

echo

echo -e "${YELLOW}Step 4: Enabling tiered storage${NC}"

# Enable remote write and read
set_config "cloud_storage_enable_remote_write" "true"
set_config "cloud_storage_enable_remote_read" "true"

# Enable cloud storage globally
set_config "cloud_storage_enabled" "true"

# Configure segment size and upload interval
set_config "cloud_storage_segment_max_upload_interval_sec" "$UPLOAD_INTERVAL"
set_config "log_segment_size" "$SEGMENT_SIZE"

echo

echo -e "${YELLOW}Step 5: Restarting Redpanda to apply changes${NC}"
echo -e "${BLUE}Note: This will restart the Redpanda service on $BROKER_IP${NC}"
echo -n "Restarting... "

if run_rpk "sudo systemctl restart redpanda" 2>/dev/null; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${YELLOW}⚠ Could not restart via systemctl${NC}"
    echo -e "${YELLOW}You may need to restart manually${NC}"
fi

echo "Waiting for cluster to come back online..."
sleep 15

# Wait for cluster to be healthy again
for i in {1..12}; do
    if run_rpk "rpk cluster health" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Cluster is healthy after restart${NC}"
        break
    fi

    if [[ $i -eq 12 ]]; then
        echo -e "${RED}✗ Cluster did not come back healthy within 60 seconds${NC}"
        echo "Check manually with: rpk cluster health"
        exit 1
    fi

    sleep 5
done

echo

echo -e "${YELLOW}Step 6: Verifying configuration${NC}"

CONFIG=$(run_rpk "rpk cluster config get cloud_storage_enabled")
if echo "$CONFIG" | grep -q "true"; then
    echo -e "${GREEN}✓ Tiered storage is enabled${NC}"
else
    echo -e "${RED}✗ Tiered storage is not enabled${NC}"
    exit 1
fi

echo

echo -e "${GREEN}=== Tiered Storage Configuration Complete ===${NC}"
echo
echo "Configuration summary:"
echo "  - Object storage: $BUCKET ($REGION)"
if [[ -n "$ENDPOINT" ]]; then
    echo "  - Endpoint: $ENDPOINT:$PORT"
fi
echo "  - Segment size: $(($SEGMENT_SIZE / 1048576))MB"
echo "  - Upload interval: ${UPLOAD_INTERVAL}s"
echo
echo "Next steps:"
echo "  1. Create topics with tiered storage enabled:"
echo "     rpk topic create my-topic -c redpanda.remote.write=true -c redpanda.remote.read=true"
echo
echo "  2. Or enable for all new topics by default:"
echo "     rpk cluster config set cloud_storage_enable_remote_write true"
echo "     rpk cluster config set cloud_storage_enable_remote_read true"
echo
echo "  3. Verify data is being uploaded:"
echo "     rpk cluster config get cloud_storage_enabled"
echo "     # Check your object storage bucket for uploaded segments"
echo
echo "  4. Run benchmarks and monitor object storage usage"
