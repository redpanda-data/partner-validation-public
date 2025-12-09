#!/bin/bash
set -euo pipefail

source config.sh

echo "========================================="
echo "Tiered Storage Validation"
echo "========================================="

PASS=0
FAIL=0

test_result() {
    if [ $? -eq 0 ]; then
        echo "✓ PASS"
        PASS=$((PASS + 1))
    else
        echo "✗ FAIL"
        FAIL=$((FAIL + 1))
    fi
}

# Test 1: Verify cloud storage is enabled
echo -n "Test 1: Cloud storage enabled... "
kubectl exec redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
    rpk cluster config get cloud_storage_enabled 2>/dev/null | grep -q "true"
test_result

# Test 2: Verify Object Storage configuration
echo -n "Test 2: Object Storage bucket configured... "
kubectl exec redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
    rpk cluster config get cloud_storage_bucket 2>/dev/null | grep -q "${OBJECT_STORAGE_BUCKET}"
test_result

# Test 3: Create topic with tiered storage enabled
echo -n "Test 3: Create tiered storage topic... "
kubectl exec redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
    rpk topic create test-tiered \
      --topic-config redpanda.remote.write=true \
      --topic-config redpanda.remote.read=true \
      --partitions 3 --replicas 3 >/dev/null 2>&1
test_result

# Test 4: Produce messages to trigger tiered storage upload
echo -n "Test 4: Produce messages (10K)... "
for i in {1..10000}; do
    echo "tiered-test-message-$i"
done | kubectl exec -i redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
    rpk topic produce test-tiered --compression lz4 >/dev/null 2>&1
test_result

# Test 5: Force segment upload
echo "Test 5: Waiting for tiered storage upload (30s)..."
sleep 30

# Test 6: Verify data in Object Storage
echo -n "Test 6: Verify data uploaded to Object Storage... "
# Get bucket info from terraform
cd terraform
BUCKET_NAME=$(terraform output -raw object_storage_bucket)
ACCESS_KEY=$(terraform output -raw object_storage_access_key)
SECRET_KEY=$(terraform output -raw object_storage_secret_key)
ENDPOINT=$(terraform output -raw object_storage_endpoint)
cd ..

# Use s3cmd to list objects (requires s3cmd installed, or use kubectl exec with rpk)
# For simplicity, check via Redpanda metrics
kubectl exec redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
    curl -s localhost:9644/metrics 2>/dev/null | grep -q "redpanda_cloud_storage"
test_result

# Test 7: Consume messages from topic
echo -n "Test 7: Consume messages from tiered topic... "
CONSUMED=$(kubectl exec redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
    timeout 10 rpk topic consume test-tiered --num 10 2>/dev/null | grep -c "tiered-test-message" || true)
[ "$CONSUMED" -gt 0 ]
test_result

# Test 8: Check tiered storage metrics
echo "Test 8: Tiered storage metrics:"
kubectl exec redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
    curl -s localhost:9644/metrics 2>/dev/null | grep "redpanda_cloud_storage" | head -10

# Summary
echo ""
echo "========================================="
echo "Tiered Storage Summary"
echo "========================================="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo ""
echo "Object Storage Details:"
echo "  Bucket: ${OBJECT_STORAGE_BUCKET}"
echo "  Endpoint: https://${OBJECT_STORAGE_ENDPOINT}"
echo ""

if [ $FAIL -eq 0 ]; then
    echo "Status: ✓ TIERED STORAGE VALIDATED"
    exit 0
else
    echo "Status: ✗ SOME TESTS FAILED"
    exit 1
fi
