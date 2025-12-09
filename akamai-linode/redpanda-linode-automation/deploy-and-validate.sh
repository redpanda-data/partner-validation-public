#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR"

# Load configuration
if [ ! -f "config.sh" ]; then
    echo -e "${RED}Error: config.sh not found. Copy config.example.sh to config.sh and configure it.${NC}"
    exit 1
fi

source config.sh

# Setup
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "${SCRIPT_DIR}/${REPORT_DIR}"
REPORT_FILE="${SCRIPT_DIR}/${REPORT_DIR}/validation-report-${TIMESTAMP}.txt"
LOG_FILE="${SCRIPT_DIR}/${REPORT_DIR}/validation-full-${TIMESTAMP}.log"
METRICS_FILE="${SCRIPT_DIR}/${REPORT_DIR}/metrics-${TIMESTAMP}.json"

# Logging functions
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "${LOG_FILE}"
}

log_success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✓${NC} $*" | tee -a "${LOG_FILE}"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ✗${NC} $*" | tee -a "${LOG_FILE}"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠${NC} $*" | tee -a "${LOG_FILE}"
}

section() {
    echo -e "\n${BLUE}========================================${NC}" | tee -a "${LOG_FILE}"
    echo -e "${BLUE}$*${NC}" | tee -a "${LOG_FILE}"
    echo -e "${BLUE}========================================${NC}" | tee -a "${LOG_FILE}"
}

# Check prerequisites
check_prerequisites() {
    section "Checking Prerequisites"

    local missing=0

    for cmd in terraform kubectl helm jq; do
        if command -v "$cmd" &> /dev/null; then
            log_success "$cmd is installed"
        else
            log_error "$cmd is NOT installed"
            missing=1
        fi
    done

    # Check for rpk (optional, will install if missing)
    if command -v rpk &> /dev/null; then
        log_success "rpk is installed"
    else
        log_warning "rpk is NOT installed - will attempt to install"
    fi

    if [ $missing -eq 1 ]; then
        log_error "Missing required tools. Please install them and try again."
        exit 1
    fi

    log_success "All prerequisites met"
}

# Deploy infrastructure with Terraform
deploy_infrastructure() {
    section "Deploying Infrastructure with Terraform"

    cd terraform

    log "Initializing Terraform..."
    terraform init >> "${LOG_FILE}" 2>&1

    log "Creating terraform.tfvars..."
    cat > terraform.tfvars <<EOF
linode_token          = "${LINODE_TOKEN}"
cluster_name          = "${CLUSTER_NAME}"
k8s_version           = "${K8S_VERSION}"
region                = "${REGION}"
node_type             = "${NODE_TYPE}"
node_count            = ${NODE_COUNT}
object_storage_bucket = "${OBJECT_STORAGE_BUCKET}"
EOF

    log "Planning infrastructure..."
    terraform plan -out=tfplan >> "${LOG_FILE}" 2>&1

    log "Applying infrastructure (this takes 15-20 minutes)..."
    terraform apply -auto-approve tfplan | tee -a "${LOG_FILE}"

    log_success "Infrastructure deployed"

    # Export outputs
    export KUBECONFIG=$(terraform output -raw kubeconfig_path)
    export OBJECT_STORAGE_ENDPOINT=$(terraform output -raw object_storage_endpoint)
    export OBJECT_STORAGE_ACCESS_KEY=$(terraform output -raw object_storage_access_key)
    export OBJECT_STORAGE_SECRET_KEY=$(terraform output -raw object_storage_secret_key)
    export OBJECT_STORAGE_BUCKET=$(terraform output -raw object_storage_bucket)

    log "Kubeconfig: $KUBECONFIG"
    log "Object Storage Endpoint: $OBJECT_STORAGE_ENDPOINT"
    log "Object Storage Bucket: $OBJECT_STORAGE_BUCKET"

    cd ..
}

# Wait for cluster to be ready
wait_for_cluster() {
    section "Waiting for Cluster to be Ready"

    log "Waiting for nodes to be Ready..."
    local max_wait=300  # 5 minutes
    local waited=0

    while [ $waited -lt $max_wait ]; do
        if kubectl get nodes 2>/dev/null | grep -q Ready; then
            local ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c Ready || true)
            if [ "$ready_nodes" -ge "${NODE_COUNT}" ]; then
                log_success "All ${NODE_COUNT} nodes are Ready"
                kubectl get nodes | tee -a "${LOG_FILE}"
                return 0
            fi
        fi
        sleep 10
        waited=$((waited + 10))
        log "Waiting... (${waited}s / ${max_wait}s)"
    done

    log_error "Cluster did not become ready in time"
    return 1
}

# Install Redpanda with Helm
install_redpanda() {
    section "Installing Redpanda with Helm"

    ./scripts/install-redpanda.sh | tee -a "${LOG_FILE}"

    if [ $? -eq 0 ]; then
        log_success "Redpanda installation complete"
    else
        log_error "Redpanda installation failed"
        return 1
    fi
}

# Wait for Redpanda to be ready
wait_for_redpanda() {
    section "Waiting for Redpanda to be Ready"

    log "Waiting for Redpanda pods to be Running..."
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=redpanda -n "${REDPANDA_NAMESPACE}" --timeout=600s | tee -a "${LOG_FILE}"

    log_success "Redpanda pods are ready"
    kubectl get pods -n "${REDPANDA_NAMESPACE}" | tee -a "${LOG_FILE}"
}

# Run validation tests
run_validations() {
    section "Running Validation Tests"

    # Cluster health
    log "Running cluster health checks..."
    ./scripts/validate-cluster.sh | tee -a "${LOG_FILE}"

    # Tiered storage
    log "Testing tiered storage integration..."
    ./scripts/test-tiered-storage.sh | tee -a "${LOG_FILE}"

    # Redpanda self-tests
    log "Running Redpanda self-tests..."
    ./scripts/run-self-tests.sh | tee -a "${LOG_FILE}"

    # Basic benchmarks
    log "Running basic performance benchmarks..."
    ./scripts/benchmark.sh | tee -a "${LOG_FILE}"

    log_success "All validations complete"
}

# Generate report
generate_report() {
    section "Generating Report"

    cat > "${REPORT_FILE}" <<EOF
================================================================================
Redpanda on Linode - Validation Report
================================================================================
Generated: $(date)
Cluster: ${CLUSTER_NAME}
Region: ${REGION}
Node Type: ${NODE_TYPE}
Node Count: ${NODE_COUNT}

================================================================================
INFRASTRUCTURE
================================================================================
EOF

    echo "LKE Cluster:" >> "${REPORT_FILE}"
    kubectl cluster-info >> "${REPORT_FILE}" 2>&1
    echo "" >> "${REPORT_FILE}"

    echo "Nodes:" >> "${REPORT_FILE}"
    kubectl get nodes -o wide >> "${REPORT_FILE}" 2>&1
    echo "" >> "${REPORT_FILE}"

    echo "CPU Architecture:" >> "${REPORT_FILE}"
    kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' >> "${REPORT_FILE}" 2>&1
    echo "" >> "${REPORT_FILE}"

    cat >> "${REPORT_FILE}" <<EOF

================================================================================
REDPANDA CLUSTER
================================================================================
EOF

    echo "Pods:" >> "${REPORT_FILE}"
    kubectl get pods -n "${REDPANDA_NAMESPACE}" -o wide >> "${REPORT_FILE}" 2>&1
    echo "" >> "${REPORT_FILE}"

    echo "Services:" >> "${REPORT_FILE}"
    kubectl get svc -n "${REDPANDA_NAMESPACE}" >> "${REPORT_FILE}" 2>&1
    echo "" >> "${REPORT_FILE}"

    echo "PersistentVolumeClaims:" >> "${REPORT_FILE}"
    kubectl get pvc -n "${REDPANDA_NAMESPACE}" >> "${REPORT_FILE}" 2>&1
    echo "" >> "${REPORT_FILE}"

    cat >> "${REPORT_FILE}" <<EOF

================================================================================
VALIDATION RESULTS
================================================================================
See full log: ${LOG_FILE}
See metrics: ${METRICS_FILE}

EOF

    log_success "Report generated: ${REPORT_FILE}"

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Deployment and Validation Complete!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "Reports:"
    echo "  - Summary: ${REPORT_FILE}"
    echo "  - Full Log: ${LOG_FILE}"
    echo "  - Metrics: ${METRICS_FILE}"
    echo ""
    echo "Next steps:"
    echo "  - View Redpanda Console: kubectl port-forward svc/redpanda-console -n ${REDPANDA_NAMESPACE} 8080:8080"
    echo "  - Access cluster: export KUBECONFIG=${KUBECONFIG}"
    echo "  - Cleanup: cd terraform && terraform destroy"
    echo ""
}

# Main execution
main() {
    log "Starting Redpanda on Linode deployment and validation"
    log "Timestamp: ${TIMESTAMP}"

    check_prerequisites
    deploy_infrastructure
    wait_for_cluster
    install_redpanda
    wait_for_redpanda
    run_validations
    generate_report

    log_success "All steps completed successfully!"
}

# Trap errors
trap 'log_error "Script failed at line $LINENO"' ERR

# Run main
main
