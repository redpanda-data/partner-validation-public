#!/bin/bash
set -euo pipefail

source config.sh

echo "========================================="
echo "Cluster Health Validation"
echo "========================================="

PASS=0
FAIL=0

check() {
    local test_name="$1"
    shift
    echo -n "Testing: $test_name... "
    if "$@" &>/dev/null; then
        echo "✓ PASS"
        PASS=$((PASS + 1))
        return 0
    else
        echo "✗ FAIL"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

# Test 1: Kubernetes API is accessible
check "Kubernetes API accessible" kubectl cluster-info

# Test 2: All nodes are Ready
check_nodes() {
    local ready=$(kubectl get nodes --no-headers | grep -c Ready || true)
    [ "$ready" -ge "${NODE_COUNT}" ]
}
check "All nodes Ready (${NODE_COUNT}+)" check_nodes

# Test 3: Redpanda namespace exists
check "Redpanda namespace exists" kubectl get namespace "${REDPANDA_NAMESPACE}"

# Test 4: Redpanda pods are Running
check_pods() {
    local running=$(kubectl get pods -n "${REDPANDA_NAMESPACE}" -l app.kubernetes.io/name=redpanda --no-headers | grep -c Running || true)
    [ "$running" -eq "${REDPANDA_REPLICAS}" ]
}
check "Redpanda pods Running (${REDPANDA_REPLICAS})" check_pods

# Test 5: PVCs are Bound
check_pvcs() {
    local bound=$(kubectl get pvc -n "${REDPANDA_NAMESPACE}" --no-headers | grep -c Bound || true)
    [ "$bound" -ge "${REDPANDA_REPLICAS}" ]
}
check "PersistentVolumeClaims Bound (${REDPANDA_REPLICAS}+)" check_pvcs

# Test 6: LoadBalancer service has external IP
check_lb() {
    kubectl get svc -n "${REDPANDA_NAMESPACE}" -l app.kubernetes.io/name=redpanda --no-headers | grep -q LoadBalancer
}
check "LoadBalancer service exists" check_lb

# Test 7: Redpanda cluster is healthy
check_redpanda_health() {
    kubectl exec -it redpanda-0 -n "${REDPANDA_NAMESPACE}" -- rpk cluster health 2>/dev/null | grep -q "Healthy:.*true"
}
check "Redpanda cluster healthy" check_redpanda_health

# Summary
echo ""
echo "========================================="
echo "Cluster Health Summary"
echo "========================================="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

if [ $FAIL -eq 0 ]; then
    echo "Status: ✓ ALL TESTS PASSED"
    exit 0
else
    echo "Status: ✗ SOME TESTS FAILED"
    exit 1
fi
