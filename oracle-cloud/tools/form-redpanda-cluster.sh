#!/bin/bash
# Form Redpanda Cluster - Repeatable Solution
# Based on lessons learned: manual node_id assignment avoids duplicate ID issues

usage() {
    cat << EOF
Usage: $0 --broker-ips <ip1,ip2,ip3,...> --ssh-key <path>

Forms a Redpanda cluster by configuring each broker with unique node IDs.

This script solves the duplicate node ID issue that occurs when using
'rpk redpanda config bootstrap' incorrectly.

Options:
  --broker-ips <ips>    Comma-separated list of broker IPs
  --ssh-key <path>      Path to SSH private key (default: ~/.ssh/redpanda_linode)
  --seed-ip <ip>        Seed broker IP (default: first in broker list)
  --jumpbox <ip>        Optional jumpbox IP (uses direct SSH if omitted)

Example:
  $0 --broker-ips 172.1.1.1,172.1.1.2,172.1.1.3 --ssh-key ~/.ssh/mykey

  With jumpbox:
  $0 --broker-ips 172.1.1.1,172.1.1.2,172.1.1.3 --jumpbox 97.107.137.207
EOF
    exit 1
}

# Parse arguments
SSH_KEY="~/.ssh/redpanda_linode"
JUMPBOX=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --broker-ips) BROKER_IPS="$2"; shift 2 ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --seed-ip) SEED_IP="$2"; shift 2 ;;
        --jumpbox) JUMPBOX="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [ -z "$BROKER_IPS" ]; then
    echo "Error: --broker-ips required"
    usage
fi

# Convert comma-separated IPs to array
IFS=',' read -ra BROKERS <<< "$BROKER_IPS"
BROKER_COUNT=${#BROKERS[@]}

# Set seed IP to first broker if not specified
SEED_IP="${SEED_IP:-${BROKERS[0]}}"

echo "=============================================="
echo "Forming $BROKER_COUNT-Broker Redpanda Cluster"
echo "=============================================="
echo "Seed broker: $SEED_IP"
echo "All brokers: ${BROKERS[@]}"
echo ""

# SSH prefix (via jumpbox or direct)
if [ -n "$JUMPBOX" ]; then
    SSH_PREFIX="ssh -o StrictHostKeyChecking=no root@${JUMPBOX} ssh -o StrictHostKeyChecking=no -i ${SSH_KEY} root@"
else
    SSH_PREFIX="ssh -o StrictHostKeyChecking=no -i ${SSH_KEY} root@"
fi

# Step 1: Stop all brokers and clean data
echo "=== Step 1: Stopping all brokers and cleaning data ==="
for IP in "${BROKERS[@]}"; do
    echo "Cleaning $IP..."
    ${SSH_PREFIX}${IP} "systemctl stop redpanda 2>/dev/null; pkill -9 redpanda 2>/dev/null; rm -rf /var/lib/redpanda/data/*; rm -f /etc/redpanda/.bootstrap.yaml" &
done
wait
echo "✅ All brokers cleaned"
echo ""

sleep 10

# Step 2: Configure seed broker (node_id 0, empty seed_servers)
echo "=== Step 2: Configuring seed broker ($SEED_IP) ==="
${SSH_PREFIX}${SEED_IP} << 'SEED_CONFIG'
cat > /etc/redpanda/redpanda.yaml << 'RPCONFIG'
redpanda:
  data_directory: /var/lib/redpanda/data
  node_id: 0
  seed_servers: []
  rpc_server:
    address: 0.0.0.0
    port: 33145
  kafka_api:
    - address: 0.0.0.0
      port: 9092
  admin:
    - address: 0.0.0.0
      port: 9644
  advertised_rpc_api:
    address: SEED_IP_PLACEHOLDER
    port: 33145
  advertised_kafka_api:
    - address: SEED_IP_PLACEHOLDER
      port: 9092
  developer_mode: true
rpk:
  overprovisioned: true
RPCONFIG

SEED_CONFIG

# Replace placeholder with actual IP. This must happen OUTSIDE the quoted
# heredoc: inside it, ${BROKER_IPS%%,*} expands on the remote host where the
# variable is unset, leaving the seed advertising an empty address (clients
# then fail with "Timed out waiting for a node assignment").
${SSH_PREFIX}${SEED_IP} "sed -i \"s/SEED_IP_PLACEHOLDER/${SEED_IP}/g\" /etc/redpanda/redpanda.yaml && systemctl start redpanda"

echo "✅ Seed broker configured and started"
echo "Waiting for seed broker to start..."
sleep 30

# Step 3: Configure and start remaining brokers
NODE_ID=1
echo ""
echo "=== Step 3: Adding remaining $((BROKER_COUNT - 1)) brokers ==="

for IP in "${BROKERS[@]:1}"; do
    echo "Configuring broker $IP (node_id: $NODE_ID)..."

    # Create config remotely
    ${SSH_PREFIX}${IP} << BROKER_CONFIG
cat > /etc/redpanda/redpanda.yaml << 'RPCONFIG'
redpanda:
  data_directory: /var/lib/redpanda/data
  node_id: ${NODE_ID}
  seed_servers:
    - host:
        address: ${SEED_IP}
        port: 33145
  rpc_server:
    address: 0.0.0.0
    port: 33145
  kafka_api:
    - address: 0.0.0.0
      port: 9092
  admin:
    - address: 0.0.0.0
      port: 9644
  advertised_rpc_api:
    address: ${IP}
    port: 33145
  advertised_kafka_api:
    - address: ${IP}
      port: 9092
  developer_mode: true
rpk:
  overprovisioned: true
RPCONFIG

systemctl start redpanda
BROKER_CONFIG

    echo "  ✅ Broker $IP started (ID: $NODE_ID)"
    NODE_ID=$((NODE_ID + 1))
    sleep 15
done

echo ""
echo "=== Step 4: Waiting for cluster to stabilize ==="
sleep 60

# Step 5: Verify cluster health
echo ""
echo "=== Step 5: Verifying Cluster Health ==="
${SSH_PREFIX}${SEED_IP} 'rpk cluster info && echo "" && rpk cluster health'

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo ""
    echo "✅ Cluster formed successfully with $BROKER_COUNT brokers!"
else
    echo ""
    echo "⚠️  Cluster formation may have issues. Check logs."
fi

exit $EXIT_CODE
