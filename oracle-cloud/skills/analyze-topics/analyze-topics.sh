#!/bin/bash
# analyze-topics.sh — Scale-aware `rpk topic analyze` wrapper.
#
# LESSONS ENCODED (July 2026):
#   - >150 partitions through an external/NodePort client times out no
#     matter the --timeout: run IN-CLUSTER (kubectl exec on redpanda-0)
#   - analyze topics ONE AT A TIME (a combined 650-partition pass never
#     finished even at 600s)
#   - --batches 5 is enough for balance/batch-size stats and much faster
#   - rpk install on Ubuntu needs unzip first (silent failure otherwise)
#   - wrap in `timeout -k` so a stuck analyze can never linger into a
#     benchmark's measured window
#
# Usage (in-cluster mode — preferred, needs KUBECONFIG):
#   ./analyze-topics.sh --time-range '-5m:end' --out <dir>
# Usage (external mode — small topics only):
#   ./analyze-topics.sh --bootstrap host:port,... --orchestrator <ip> --time-range '-5m:end' --out <dir>
set -euo pipefail

BOOTSTRAP="" ORCH="" RANGE="-5m:end" OUTDIR="." SSH_KEY="$HOME/.ssh/redpanda_oci" CEILING=480
while [[ $# -gt 0 ]]; do case $1 in
    --bootstrap) BOOTSTRAP="$2"; shift 2 ;;
    --orchestrator) ORCH="$2"; shift 2 ;;
    --time-range) RANGE="$2"; shift 2 ;;
    --out) OUTDIR="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    --ceiling) CEILING="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown: $1"; exit 1 ;;
esac; done
mkdir -p "$OUTDIR"

if [ -n "${KUBECONFIG:-}" ] && kubectl get ns redpanda >/dev/null 2>&1; then
    echo "mode: in-cluster (kubectl exec, preferred)"
    TOPICS=$(kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk topic list 2>/dev/null | tail -n +2 | awk '$1!~/^_/{print $1}')
    for T in $TOPICS; do
        echo "=== $T ==="
        timeout -k 10 "$CEILING" kubectl exec -n redpanda redpanda-0 -c redpanda -- \
            rpk topic analyze "$T" --time-range "$RANGE" --batches 5 --timeout $((CEILING-30))s --print-summary 2>&1 | tail -6
        timeout -k 10 "$CEILING" kubectl exec -n redpanda redpanda-0 -c redpanda -- \
            rpk topic analyze "$T" --time-range "$RANGE" --batches 5 --timeout $((CEILING-30))s --print-all --format json \
            > "$OUTDIR/topic-analysis-${T}.json" 2>/dev/null || echo "  (json pass hit ceiling — summary above still valid)"
    done
elif [ -n "$BOOTSTRAP" ] && [ -n "$ORCH" ]; then
    echo "mode: external via orchestrator (small topics only — <150 partitions)"
    S="ssh -o StrictHostKeyChecking=no -i $SSH_KEY root@$ORCH"
    $S 'command -v rpk >/dev/null 2>&1 || {
        command -v unzip >/dev/null 2>&1 || apt-get install -y -qq unzip >/dev/null 2>&1 || dnf install -y -q unzip >/dev/null 2>&1
        curl -sLo /tmp/rpk.zip https://github.com/redpanda-data/redpanda/releases/latest/download/rpk-linux-amd64.zip \
        && cd /tmp && unzip -oq rpk.zip && install -m755 rpk /usr/local/bin/rpk; }
      command -v rpk >/dev/null || echo "RPK INSTALL FAILED"'
    for T in $($S "rpk topic list -X brokers=$BOOTSTRAP 2>/dev/null | tail -n +2 | awk '\$1!~/^_/{print \$1}'"); do
        echo "=== $T ==="
        $S "timeout -k 10 $CEILING rpk topic analyze $T -X brokers=$BOOTSTRAP --time-range '$RANGE' --batches 5 --timeout $((CEILING-30))s --print-summary" 2>&1 | tail -6
    done
else
    echo "Error: need KUBECONFIG (in-cluster mode) or --bootstrap + --orchestrator (external)"
    exit 1
fi
echo "✅ analyze complete — JSONs in $OUTDIR/"
