#!/bin/bash
# run-blended.sh — Run a BLENDED (multi-topic, mixed-durability) benchmark:
# two OMB coordinators on one cluster (OMB supports one replicationFactor per
# coordinator), disjoint worker fleets, synchronized launch, marker-based
# completion, per-topic collection into a date-time run dir with README.
#
# Encodes every trap from the July 2026 blended runs:
#   - workers split into workers-a.yaml / workers-b.yaml (never share!)
#   - B (bigger topic) launches first, A ~20s later (topic creation cost)
#   - completion = result JSONs newer than launch marker (coordinators linger)
#   - SSH probe failures are blips, never exit signals (sentinel pattern)
#   - optional start-of-run topic analyze (in-cluster if KUBECONFIG set —
#     NodePort clients time out on 500-partition topics), --no-analyze to skip
#
# Usage:
#   ./run-blended.sh --orchestrator <ip> \
#     --clients-a <ip,ip,...> --clients-b <ip,ip,...> \
#     --bootstrap <host:port,...> \
#     --workload-a <file> --driver-a <file> \
#     --workload-b <file> --driver-b <file> \
#     --run-name <name> [--no-analyze] [--provider oci] [--ssh-key path]
set -euo pipefail

ORCH="" CA="" CB="" BOOTSTRAP="" WA="" DA="" WB="" DB="" RUN_NAME=""
PROVIDER="oci" SSH_KEY="$HOME/.ssh/redpanda_oci" NO_ANALYZE="no"

while [[ $# -gt 0 ]]; do case $1 in
    --orchestrator) ORCH="$2"; shift 2 ;;
    --clients-a) CA="$2"; shift 2 ;;
    --clients-b) CB="$2"; shift 2 ;;
    --bootstrap) BOOTSTRAP="$2"; shift 2 ;;
    --workload-a) WA="$2"; shift 2 ;;
    --driver-a) DA="$2"; shift 2 ;;
    --workload-b) WB="$2"; shift 2 ;;
    --driver-b) DB="$2"; shift 2 ;;
    --run-name) RUN_NAME="$2"; shift 2 ;;
    --no-analyze) NO_ANALYZE="yes"; shift ;;
    --provider) PROVIDER="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown: $1"; exit 1 ;;
esac; done
for v in ORCH CA CB BOOTSTRAP WA DA WB DB RUN_NAME; do
    [[ -z "${!v}" ]] && { echo "Error: missing required arg ($v)"; exit 1; }
done
S="ssh -o StrictHostKeyChecking=no -i $SSH_KEY root@$ORCH"

echo "── 1/6 stage configs + worker files"
scp -o StrictHostKeyChecking=no -i "$SSH_KEY" \
    "providers/oci/configs/workloads/$WA" "providers/oci/configs/workloads/$WB" \
    "providers/oci/configs/drivers/$DA" "providers/oci/configs/drivers/$DB" root@$ORCH:/tmp/
$S "cp /tmp/$WA /tmp/$WB /opt/benchmark/workloads/ && cp /tmp/$DA /tmp/$DB /opt/benchmark/driver-redpanda/
sed -i 's|bootstrap.servers=.*|bootstrap.servers=$BOOTSTRAP|' /opt/benchmark/driver-redpanda/$DA /opt/benchmark/driver-redpanda/$DB
printf 'workers:\n' > /opt/benchmark/workers-a.yaml
for c in $(echo $CA | tr ',' ' '); do printf '  - http://%s:8080\n' \$c >> /opt/benchmark/workers-a.yaml; done
printf 'workers:\n' > /opt/benchmark/workers-b.yaml
for c in $(echo $CB | tr ',' ' '); do printf '  - http://%s:8080\n' \$c >> /opt/benchmark/workers-b.yaml; done
echo staged"

echo "── 2/6 verify/heal all workers"
$S 'ok=0; total=0
for c in '"$(echo $CA,$CB | tr ',' ' ')"'; do
  total=$((total+1))
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://$c:8080/counters-stats)
  if [ "$code" != "200" ]; then
    ssh -o StrictHostKeyChecking=no -i /root/.ssh/redpanda_oci root@$c \
      "pkill -9 -f BenchmarkWorke[r]; sleep 2; cd /opt/benchmark && KAFKA_OPTS=\" \" nohup bin/benchmark-worker --port 8080 --stats-port 9091 > /tmp/worker.log 2>&1 & sleep 5"
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://$c:8080/counters-stats)
  fi
  [ "$code" = "200" ] && ok=$((ok+1)) || echo "  ❌ worker $c down"
done
echo "  workers healthy: $ok/$total"; [ "$ok" = "$total" ]'

echo "── 3/6 launch (B first — bigger topic — then A)"
$S "cd /opt/benchmark && rm -f ${RUN_NAME}-a.log ${RUN_NAME}-b.log && touch .run-started-$RUN_NAME
(nohup bin/benchmark --drivers driver-redpanda/$DB --workers-file workers-b.yaml workloads/$WB > ${RUN_NAME}-b.log 2>&1 &)
sleep 20
(nohup bin/benchmark --drivers driver-redpanda/$DA --workers-file workers-a.yaml workloads/$WA > ${RUN_NAME}-a.log 2>&1 &)
echo launched"

echo "── 4/6 monitor (sentinel probe; per-topic rates every 5 min)"
MIN=0; ANALYZED="$NO_ANALYZE"
while true; do
    sleep 60; MIN=$((MIN+1))
    STATE=$($S "J=\$(find /opt/benchmark -maxdepth 1 -name '*.json' -newer /opt/benchmark/.run-started-$RUN_NAME 2>/dev/null | wc -l); if [ \"\$J\" -ge 2 ]; then echo DONE; elif pgrep -f 'io.openmessaging.benchmark.Benchmar[k]' >/dev/null; then echo RUNNING; else echo EXITED; fi" 2>/dev/null)
    case "$STATE" in
        DONE) echo "  both result JSONs written — run complete"; break ;;
        EXITED) echo "  ⚠ coordinators exited (check logs for errors)"; break ;;
        RUNNING) : ;;
        *) : ;; # ssh blip — never an exit signal
    esac
    if [ "$ANALYZED" = "no" ] && [ "$MIN" -ge 1 ]; then
        ANALYZED="yes"
        echo "  ── start-of-run topic analyze:"
        if [ -n "${KUBECONFIG:-}" ] && kubectl get ns redpanda >/dev/null 2>&1; then
            for T in $(kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk topic list 2>/dev/null | grep test-topic | awk '{print $1}'); do
                timeout -k 10 480 kubectl exec -n redpanda redpanda-0 -c redpanda -- \
                  rpk topic analyze $T --time-range -1m:end --batches 5 --timeout 300s --print-summary 2>/dev/null | tail -4 | sed 's/^/    /'
            done
        else
            echo "    (KUBECONFIG unset — skipping; in-cluster analyze required for large topics)"
        fi
    fi
    if [ $((MIN % 5)) -eq 0 ] && [ "$STATE" = "RUNNING" ]; then
        $S "grep 'Pub rate' /opt/benchmark/${RUN_NAME}-a.log | tail -1 | cut -c1-110 | sed 's/^/  A: /'; grep 'Pub rate' /opt/benchmark/${RUN_NAME}-b.log | tail -1 | cut -c1-110 | sed 's/^/  B: /'" || true
    fi
done

echo "── 5/6 collect (parallel, compressed)"
STAMP=$(date -u +%Y-%m-%d_%H%M)
OUT="results/${PROVIDER}/${STAMP}"
mkdir -p "$OUT"
JS=$($S "find /opt/benchmark -maxdepth 1 -name '*.json' -newer /opt/benchmark/.run-started-$RUN_NAME" 2>/dev/null)
for j in $JS; do scp -C -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ORCH:$j" "$OUT/" & done
scp -C -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ORCH:/opt/benchmark/${RUN_NAME}-a.log" "$OUT/topicA-run-log.txt" &
scp -C -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ORCH:/opt/benchmark/${RUN_NAME}-b.log" "$OUT/topicB-run-log.txt" &
wait || true
cp "providers/oci/configs/workloads/$WA" "providers/oci/configs/workloads/$WB" \
   "providers/oci/configs/drivers/$DA" "providers/oci/configs/drivers/$DB" "$OUT/" 2>/dev/null || true

echo "── 6/6 README + summary"
cat > "$OUT/README.md" <<EOF
# Benchmark Run — ${STAMP} UTC (blended, dual-coordinator)

**Run name:** ${RUN_NAME}
**Topic A:** \`$WA\` + \`$DA\` on workers: ${CA}
**Topic B:** \`$WB\` + \`$DB\` on workers: ${CB}
**Bootstrap:** \`${BOOTSTRAP}\` · **Orchestrator:** ${ORCH}
**Analyze at start:** $([ "$NO_ANALYZE" = "yes" ] && echo "disabled per test owner" || echo "enabled")

## Contents
Two OMB result JSONs (one per coordinator/topic), both coordinator logs,
workload + driver YAML copies.

## Notes
(purpose / findings — fill in with the run report)
EOF
for f in "$OUT"/workload-*-Redpanda-*.json; do
  [ -f "$f" ] || continue
  python3 - "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
pr, cr = d['publishRate'], d['consumeRate']
name = 'A' if 'topicA' in sys.argv[1] or 'topica' in sys.argv[1].lower() else 'B'
print(f"  Topic {name}: pub {sum(pr)/len(pr):,.0f} msg/s ({sum(pr)/len(pr)*1024/1024**2:,.1f} MB/s) | cons {sum(cr)/len(cr)*1024/1024**2:,.1f} MB/s")
PY
done
WSTART=$($S "grep -m1 'Pub rate' /opt/benchmark/${RUN_NAME}-b.log | cut -d' ' -f1" 2>/dev/null || true)
WEND=$($S "grep 'Pub rate' /opt/benchmark/${RUN_NAME}-b.log | tail -1 | cut -d' ' -f1" 2>/dev/null || true)
TODAY=$(date -u +%Y-%m-%d)
echo "✅ blended run complete — $OUT/"
echo "   MEASURED WINDOW (for collect-run-metrics): start=${TODAY}T${WSTART%%.*}Z(+5m warmup) end=${TODAY}T${WEND%%.*}Z"
echo "   Next: skills/collect-run-metrics for the Prometheus battery (broker p99, CPU, tiered)."
echo "   Report format: follow results/blended/BLENDED_3GBPS_FLEX16_REPORT.md as the template." 
