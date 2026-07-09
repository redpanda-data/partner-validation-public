#!/bin/bash
# Universal Benchmark Monitoring Script
# Monitors any tier benchmark to completion and generates reports

usage() {
    cat << EOF
Usage: $0 --tier <1-9> --jumpbox <ip> --client <ip> --provider <linode|aws>

Options:
  --tier <number>       Tier number (1-9)
  --jumpbox <ip>        Jumpbox IP address
  --client <ip>         Primary client IP address
  --provider <name>     Cloud provider (linode or aws)
  --log-file <path>     Log file on client (default: tier\${TIER}.log)
  --results-dir <path>  Local results directory (default: results/\${PROVIDER}/tier-\${TIER})

Example:
  $0 --tier 5 --jumpbox 97.107.137.207 --client 172.234.199.116 --provider linode
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --tier) TIER="$2"; shift 2 ;;
        --jumpbox) JUMPBOX="$2"; shift 2 ;;
        --client) CLIENT="$2"; shift 2 ;;
        --provider) PROVIDER="$2"; shift 2 ;;
        --log-file) LOG_FILE="$2"; shift 2 ;;
        --results-dir) RESULTS_DIR="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Validate required arguments
if [ -z "$TIER" ] || [ -z "$JUMPBOX" ] || [ -z "$CLIENT" ] || [ -z "$PROVIDER" ]; then
    echo "Error: Missing required arguments"
    usage
fi

# Set defaults
LOG_FILE="${LOG_FILE:-tier${TIER}.log}"
RESULTS_DIR="${RESULTS_DIR:-results/${PROVIDER}/tier-${TIER}}"

echo "=============================================="
echo "Monitoring Tier $TIER Benchmark"
echo "=============================================="
echo "Jumpbox:     $JUMPBOX"
echo "Client:      $CLIENT"
echo "Provider:    $PROVIDER"
echo "Log file:    /opt/benchmark/$LOG_FILE"
echo "Results dir: $RESULTS_DIR"
echo ""

# Function to check if benchmark is still running
check_running() {
    ssh -o StrictHostKeyChecking=no root@${JUMPBOX} \
        "ssh -o StrictHostKeyChecking=no root@${CLIENT} 'pgrep -f \"bin/benchmark\" >/dev/null && echo running || echo stopped'" 2>/dev/null
}

# Function to get last few lines of log
get_log_tail() {
    ssh -o StrictHostKeyChecking=no root@${JUMPBOX} \
        "ssh -o StrictHostKeyChecking=no root@${CLIENT} 'tail -30 /opt/benchmark/$LOG_FILE'" 2>/dev/null
}

# Wait for benchmark to complete
echo "Waiting for benchmark to complete..."
LAST_UPDATE=$(date +%s)
CHECK_INTERVAL=60  # Check every 60 seconds

while true; do
    STATUS=$(check_running)
    CURRENT_TIME=$(date +%s)

    if [[ "$STATUS" == "stopped" ]]; then
        echo ""
        echo "✅ Benchmark completed!"
        echo ""
        break
    fi

    # Show update every 5 minutes
    TIME_DIFF=$((CURRENT_TIME - LAST_UPDATE))
    if [ $TIME_DIFF -ge 300 ]; then
        echo "[$(date '+%H:%M:%S')] Still running... (last 10 lines of log:)"
        get_log_tail | tail -10
        echo ""
        LAST_UPDATE=$CURRENT_TIME
    fi

    sleep $CHECK_INTERVAL
done

# Download results
echo "=============================================="
echo "Downloading Results"
echo "=============================================="
echo ""

mkdir -p "$RESULTS_DIR"

echo "Downloading JSON results..."
ssh -o StrictHostKeyChecking=no root@${JUMPBOX} \
    "scp -o StrictHostKeyChecking=no root@${CLIENT}:/opt/benchmark/workload-tier-${TIER}*.json /tmp/" 2>/dev/null

scp -o StrictHostKeyChecking=no root@${JUMPBOX}:/tmp/workload-tier-${TIER}*.json "$RESULTS_DIR/" 2>/dev/null

echo "Downloading log file..."
ssh -o StrictHostKeyChecking=no root@${JUMPBOX} \
    "ssh -o StrictHostKeyChecking=no root@${CLIENT} 'cat /opt/benchmark/$LOG_FILE'" > "$RESULTS_DIR/${LOG_FILE}" 2>/dev/null

echo ""
echo "✅ Results downloaded to $RESULTS_DIR"
echo ""

# Find the JSON file
JSON_FILE=$(ls -t "$RESULTS_DIR"/*.json 2>/dev/null | head -1)

if [ -z "$JSON_FILE" ]; then
    echo "❌ No JSON results file found in $RESULTS_DIR"
    exit 1
fi

echo "Found results file: $JSON_FILE"
echo ""

# Generate reports using universal report tool
echo "=============================================="
echo "Generating Reports"
echo "=============================================="
echo ""

python3 tools/generate-benchmark-report.py $TIER "$JSON_FILE" --provider $PROVIDER

if [ $? -eq 0 ]; then
    echo ""
    echo "=============================================="
    echo "✅ Tier $TIER Complete!"
    echo "=============================================="
    echo ""
    echo "Results saved to: $RESULTS_DIR"
    echo ""
    echo "View reports:"
    echo "  cat $RESULTS_DIR/QUICKVIEW.txt"
    echo "  cat $RESULTS_DIR/TIER_${TIER}_REPORT.txt"
    echo "  cat $RESULTS_DIR/TIER_${TIER}_ANALYSIS.md"
    echo ""

    # Display QUICKVIEW
    cat "$RESULTS_DIR/QUICKVIEW.txt"
else
    echo ""
    echo "❌ Report generation failed"
    exit 1
fi
