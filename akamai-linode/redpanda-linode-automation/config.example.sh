#!/bin/bash
# Configuration for Redpanda Linode Deployment
# Copy this file to config.sh and fill in your values

# Linode API Token (required)
export LINODE_TOKEN="your_linode_api_token_here"

# Cluster Configuration
export CLUSTER_NAME="redpanda-validation"
export REGION="us-east"
export K8S_VERSION="1.28"

# Node Pool Configuration
export NODE_TYPE="g6-dedicated-32"  # Dedicated 64GB (32 vCPUs, 64GB RAM)
export NODE_COUNT=3

# Redpanda Configuration
export REDPANDA_NAMESPACE="redpanda"
export REDPANDA_REPLICAS=3
export VOLUME_SIZE_GB=100
export OBJECT_STORAGE_BUCKET="redpanda-tiered-storage-${CLUSTER_NAME}"

# Output Configuration
export REPORT_DIR="reports"
export KUBECONFIG_PATH="${HOME}/.kube/redpanda-linode-kubeconfig"
