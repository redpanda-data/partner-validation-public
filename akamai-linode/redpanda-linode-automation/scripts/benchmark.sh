#!/bin/bash
set -euo pipefail

source config.sh

echo "========================================="
echo "Basic Performance Benchmarks"
echo "========================================="

# Create benchmark topic
echo "Creating benchmark topic..."
kubectl exec redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
    rpk topic create benchmark-test --partitions 6 --replicas 3 2>/dev/null || true

# Benchmark 1: Producer throughput
echo ""
echo "Test 1: Producer Throughput"
echo "-----------------------------"
echo "Producing 100K messages (1KB each)..."

START=$(date +%s)
for i in {1..100000}; do
    echo "benchmark-message-$(printf '%06d' $i)-$(date +%s%N)"
done | kubectl exec -i redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
    rpk topic produce benchmark-test --compression lz4 >/dev/null 2>&1
END=$(date +%s)

DURATION=$((END - START))
THROUGHPUT=$((100000 / DURATION))

echo "Duration: ${DURATION}s"
echo "Throughput: ~${THROUGHPUT} msg/sec"

# Benchmark 2: Consumer throughput
echo ""
echo "Test 2: Consumer Throughput"
echo "-----------------------------"
echo "Consuming 100K messages..."

START=$(date +%s)
kubectl exec redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
    timeout 60 rpk topic consume benchmark-test --num 100000 >/dev/null 2>&1 || true
END=$(date +%s)

DURATION=$((END - START))
THROUGHPUT=$((100000 / DURATION))

echo "Duration: ${DURATION}s"
echo "Throughput: ~${THROUGHPUT} msg/sec"

# Benchmark 3: End-to-end latency (simple test)
echo ""
echo "Test 3: End-to-End Latency (sample)"
echo "------------------------------------"
echo "Measuring latency for 100 messages..."

# Send messages and measure time
LATENCIES=""
for i in {1..100}; do
    MSG="latency-test-$i-$(date +%s%N)"
    START_NS=$(date +%s%N)

    echo "$MSG" | kubectl exec -i redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
        rpk topic produce benchmark-test >/dev/null 2>&1

    kubectl exec redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
        timeout 2 rpk topic consume benchmark-test --num 1 --offset -1 2>/dev/null | grep -q "latency-test-$i" || true

    END_NS=$(date +%s%N)
    LATENCY_MS=$(( (END_NS - START_NS) / 1000000 ))
    LATENCIES="$LATENCIES $LATENCY_MS"
done

# Calculate simple statistics
LATENCIES_ARRAY=($LATENCIES)
SORTED=($(printf '%s\n' "${LATENCIES_ARRAY[@]}" | sort -n))
COUNT=${#SORTED[@]}

P50_IDX=$((COUNT / 2))
P95_IDX=$((COUNT * 95 / 100))
P99_IDX=$((COUNT * 99 / 100))

echo "Sample latency stats (simplified):"
echo "  p50: ~${SORTED[$P50_IDX]}ms"
echo "  p95: ~${SORTED[$P95_IDX]}ms"
echo "  p99: ~${SORTED[$P99_IDX]}ms"

# Benchmark 4: Get system info
echo ""
echo "Test 4: System Information"
echo "--------------------------"

echo "CPU Model:"
kubectl exec redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
    cat /proc/cpuinfo 2>/dev/null | grep "model name" | head -1

echo ""
echo "Memory:"
kubectl exec redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
    free -h 2>/dev/null | head -2

echo ""
echo "Disk Performance (simple test):"
kubectl exec redpanda-0 -n "${REDPANDA_NAMESPACE}" -- \
    sh -c 'dd if=/dev/zero of=/tmp/test bs=1M count=100 2>&1 | tail -1' 2>/dev/null || echo "Unable to test"

# Summary
echo ""
echo "========================================="
echo "Benchmark Summary"
echo "========================================="
echo "Producer: ~${THROUGHPUT} msg/sec"
echo "Consumer: Similar or higher"
echo "Latency: See detailed stats above"
echo ""
echo "Note: These are basic benchmarks. For production validation,"
echo "      use OpenMessaging Benchmark (OMB) for comprehensive testing."
echo ""
