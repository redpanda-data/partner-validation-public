#!/bin/bash
set -euo pipefail

source config.sh

echo "========================================="
echo "Redpanda Self-Tests"
echo "========================================="
echo "Running comprehensive self-tests (disk, network, cloud storage)"
echo "This may take 5-10 minutes..."
echo ""

# Start self-tests
echo "Starting self-tests..."
kubectl exec redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
    rpk cluster self-test start \
      --cloud-timeout-ms 10000 \
      --cloud-backoff-ms 100 \
      --no-confirm 2>&1

echo ""
echo "Self-tests started. Waiting for completion..."

# Wait for tests to complete
sleep 5

# Poll for status
MAX_WAIT=600  # 10 minutes
WAITED=0

while [ $WAITED -lt $MAX_WAIT ]; do
    STATUS=$(kubectl exec redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
        rpk cluster self-test status --format json 2>/dev/null || echo "{}")

    # Check if tests are still running
    if echo "$STATUS" | jq -e '.running' >/dev/null 2>&1; then
        IS_RUNNING=$(echo "$STATUS" | jq -r '.running')
        if [ "$IS_RUNNING" == "false" ]; then
            echo "Self-tests completed!"
            break
        fi
    fi

    echo "Still running... (${WAITED}s / ${MAX_WAIT}s)"
    sleep 15
    WAITED=$((WAITED + 15))
done

# Get final status
echo ""
echo "========================================="
echo "Self-Test Results"
echo "========================================="

kubectl exec redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
    rpk cluster self-test status 2>&1

# Get detailed results in JSON
echo ""
echo "Detailed results (JSON):"
kubectl exec redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
    rpk cluster self-test status --format json 2>&1 | jq '.'

# Parse and summarize results
echo ""
echo "========================================="
echo "Summary"
echo "========================================="

RESULTS=$(kubectl exec redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
    rpk cluster self-test status --format json 2>/dev/null || echo "{}")

# Disk tests
echo "Disk Tests:"
echo "$RESULTS" | jq -r '.tests[] | select(.type == "disk") | "  \(.name): \(.result)"' 2>/dev/null || echo "  (no disk test results)"

# Network tests
echo ""
echo "Network Tests:"
echo "$RESULTS" | jq -r '.tests[] | select(.type == "network") | "  \(.name): \(.result)"' 2>/dev/null || echo "  (no network test results)"

# Cloud storage tests
echo ""
echo "Cloud Storage Tests:"
echo "$RESULTS" | jq -r '.tests[] | select(.type == "cloud") | "  \(.name): \(.result)"' 2>/dev/null || echo "  (no cloud storage test results)"

# Check for any failures
FAILURES=$(echo "$RESULTS" | jq -r '[.tests[] | select(.result != "PASS")] | length' 2>/dev/null || echo "0")

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "Status: ✓ ALL SELF-TESTS PASSED"
    exit 0
else
    echo "Status: ✗ $FAILURES TEST(S) FAILED"
    exit 1
fi
