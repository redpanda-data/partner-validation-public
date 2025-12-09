#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Redpanda Linode Cleanup${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""
echo "This will destroy:"
echo "  - LKE cluster and all resources"
echo "  - Linode Object Storage bucket and data"
echo "  - All Redpanda data"
echo ""
echo -e "${RED}WARNING: This action cannot be undone!${NC}"
echo ""
read -p "Are you sure you want to continue? (type 'yes' to confirm): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo "Destroying infrastructure..."

cd terraform

if [ -f "terraform.tfstate" ]; then
    terraform destroy -auto-approve
    echo "Infrastructure destroyed successfully."
else
    echo "No terraform.tfstate found. Nothing to destroy."
fi

cd ..

# Remove kubeconfig
if [ -f "${HOME}/.kube/redpanda-linode-kubeconfig" ]; then
    echo "Removing kubeconfig..."
    rm -f "${HOME}/.kube/redpanda-linode-kubeconfig"
fi

echo ""
echo "Cleanup complete!"
