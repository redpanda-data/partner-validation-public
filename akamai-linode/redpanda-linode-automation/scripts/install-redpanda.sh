#!/bin/bash
set -euo pipefail

source config.sh

echo "Installing Redpanda via Helm..."

# Add Redpanda Helm repository
echo "Adding Redpanda Helm repository..."
helm repo add redpanda https://charts.redpanda.com
helm repo update

# Create namespace
echo "Creating namespace: ${REDPANDA_NAMESPACE}..."
kubectl create namespace "${REDPANDA_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Get Object Storage credentials from Terraform
TERRAFORM_DIR="$(dirname "$0")/../terraform"
cd "$TERRAFORM_DIR"
OBJECT_STORAGE_ACCESS_KEY=$(terraform output -raw object_storage_access_key)
OBJECT_STORAGE_SECRET_KEY=$(terraform output -raw object_storage_secret_key)
OBJECT_STORAGE_ENDPOINT=$(terraform output -raw object_storage_endpoint)
OBJECT_STORAGE_BUCKET=$(terraform output -raw object_storage_bucket)
cd - > /dev/null

echo "Object Storage configuration:"
echo "  Bucket: ${OBJECT_STORAGE_BUCKET}"
echo "  Endpoint: ${OBJECT_STORAGE_ENDPOINT}"

# Create Helm values file
echo "Creating Helm values..."
cat > /tmp/redpanda-values.yaml <<EOF
statefulset:
  replicas: ${REDPANDA_REPLICAS}

resources:
  cpu:
    cores: 6  # Dedicated 16GB has 8 vCPUs, leave 2 for system
  memory:
    container:
      max: 14Gi
      min: 14Gi
    redpanda:
      memory: 13Gi
      reserveMemory: 1Gi

storage:
  persistentVolume:
    enabled: true
    size: ${VOLUME_SIZE_GB}Gi
    storageClass: linode-block-storage-retain

  tiered:
    config:
      cloud_storage_enabled: true
      cloud_storage_region: us-east-1
      cloud_storage_bucket: ${OBJECT_STORAGE_BUCKET}
      cloud_storage_access_key: ${OBJECT_STORAGE_ACCESS_KEY}
      cloud_storage_secret_key: ${OBJECT_STORAGE_SECRET_KEY}
      cloud_storage_api_endpoint: ${OBJECT_STORAGE_ENDPOINT}
      cloud_storage_api_endpoint_port: 443
      cloud_storage_disable_tls: false

external:
  enabled: true
  type: LoadBalancer

console:
  enabled: true

monitoring:
  enabled: true
  scrapeInterval: 30s
EOF

echo "Installing Redpanda Helm chart..."
helm upgrade --install redpanda redpanda/redpanda \
  --namespace "${REDPANDA_NAMESPACE}" \
  --values /tmp/redpanda-values.yaml \
  --wait \
  --timeout 15m

echo "Redpanda Helm installation complete"

# Show status
echo ""
echo "Redpanda resources:"
kubectl get pods,pvc,svc -n "${REDPANDA_NAMESPACE}"
