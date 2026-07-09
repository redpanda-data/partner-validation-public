#!/bin/bash
# run-benchmark.sh — Stage, launch, monitor, and collect an OMB benchmark run.
# Encodes every operational trap from the July 2026 OCI/OKE sessions so the
# operator (human or model) makes zero judgment calls:
#   - verifies all workers respond BEFORE launching (restarts wedged ones —
#     workers wedge if a previous run was hard-killed)
#   - sets bootstrap.servers in the driver from --bootstrap
#   - regenerates workers.yaml from the client list
#   - launches with nohup inside parens (survives disconnect; note the
#     `(cd && cmd &)` pattern — `cd && cmd &` backgrounds the WHOLE list)
#   - polls until the result JSON exists, then downloads JSON + log and
#     runs the report generator
#
# Run FROM THE REPO ROOT on the operator machine.
#
# Usage:
#   ./skills/run-omb-benchmark/run-benchmark.sh \
#     --orchestrator <client-0-public-ip> \
#     --clients <priv-ip1,priv-ip2,...> \
#     --bootstrap <broker1:port,broker2:port,...> \
#     --workload workload-blended-r2.yaml \
#     --driver redpanda-blended-r2.yaml \
#     --run-name blended-r2 \
#     [--provider oci] [--tier 1] [--ssh-key ~/.ssh/redpanda_oci]
set -euo pipefail

ORCH="" CLIENTS="" BOOTSTRAP="" WORKLOAD="" DRIVER="" RUN_NAME=""
PROVIDER="oci" TIER="" SSH_KEY="$HOME/.ssh/redpanda_oci"

while [[ $# -gt 0 ]]; do
    case $1 in
        --orchestrator) ORCH="$2"; shift 2 ;;
        --clients) CLIENTS="$2"; shift 2 ;;
        --bootstrap) BOOTSTRAP="$2"; shift 2 ;;
        --workload) WORKLOAD="$2"; shift 2 ;;
        --driver) DRIVER="$2"; shift 2 ;;
        --run-name) RUN_NAME="$2"; shift 2 ;;
        --provider) PROVIDER="$2"; shift 2 ;;
        --tier) TIER="$2"; shift 2 ;;
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done
for v in ORCH CLIENTS BOOTSTRAP WORKLOAD DRIVER RUN_NAME; do
    [[ -z "${!v}" ]] && { echo "Error: --$(echo $v | tr 'A-Z_' 'a-z-') is required"; exit 1; }
done

S="ssh -o StrictHostKeyChecking=no -i $SSH_KEY root@$ORCH"
LOG="${RUN_NAME}.log"

echo "── 1/6 stage configs on orchestrator"
scp -o StrictHostKeyChecking=no -i "$SSH_KEY" \
    "providers/oci/configs/workloads/$WORKLOAD" "providers/oci/configs/drivers/$DRIVER" \
    root@$ORCH:/tmp/
$S "cp /tmp/$WORKLOAD /opt/benchmark/workloads/ && cp /tmp/$DRIVER /opt/benchmark/driver-redpanda/ \
    && sed -i 's|bootstrap.servers=.*|bootstrap.servers=$BOOTSTRAP|' /opt/benchmark/driver-redpanda/$DRIVER \
    && grep bootstrap /opt/benchmark/driver-redpanda/$DRIVER"

echo "── 2/6 regenerate workers.yaml"
$S "printf 'workers:\n' > /opt/benchmark/workers.yaml
for c in $(echo $CLIENTS | tr ',' ' '); do printf '  - http://%s:8080\n' \$c >> /opt/benchmark/workers.yaml; done
cat /opt/benchmark/workers.yaml"

echo "── 3/6 verify workers (restart any that do not answer)"
$S 'ok=0; total=0
for c in '"$(echo $CLIENTS | tr ',' ' ')"'; do
  total=$((total+1))
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://$c:8080/counters-stats)
  if [ "$code" != "200" ]; then
    echo "  restarting wedged worker on $c"
    ssh -o StrictHostKeyChecking=no -i /root/.ssh/redpanda_oci root@$c \
      "pkill -9 -f BenchmarkWorke[r]; sleep 2; cd /opt/benchmark && KAFKA_OPTS=\" \" nohup bin/benchmark-worker --port 8080 --stats-port 9091 > /tmp/worker.log 2>&1 & sleep 5"
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://$c:8080/counters-stats)
  fi
  [ "$code" = "200" ] && ok=$((ok+1)) || echo "  ❌ worker on $c still down"
done
echo "  workers healthy: $ok/$total"
[ "$ok" = "$total" ]'

echo "── 4/6 launch"
$S "cd /opt/benchmark && rm -f $LOG && touch .run-started-$RUN_NAME && (nohup bin/benchmark --drivers driver-redpanda/$DRIVER --workers-file workers.yaml workloads/$WORKLOAD > $LOG 2>&1 &) && echo launched"

echo "── 5/6 monitor (prints one rate line per minute; exits when run completes)"
WARMUP_ANALYZED="no"
MIN=0
while true; do
    sleep 60
    MIN=$((MIN+1))
    # completion = result JSON newer than the launch marker (fast path —
    # coordinators can linger minutes after writing results) OR CONFIRMED
    # process exit. A failed SSH probe is a blip, never an exit signal.
    # NOTE the bracket trick in the pgrep pattern — an unbracketed pattern
    # matches the ssh wrapper itself and waits forever.
    STATE=$($S "if find /opt/benchmark -maxdepth 1 -name '*.json' -newer /opt/benchmark/.run-started-$RUN_NAME 2>/dev/null | grep -q .; then echo DONE; elif pgrep -f 'io.openmessaging.benchmark.Benchmar[k]' >/dev/null; then echo RUNNING; else echo EXITED; fi" 2>/dev/null)
    if [ "$STATE" = "DONE" ]; then
        echo "  result JSON detected — run complete"
        break
    elif [ "$STATE" = "EXITED" ]; then
        echo "  benchmark process exited"
        break
    fi
    # empty STATE = ssh blip: keep waiting
    # START-OF-WORKLOAD partition-balance check: fires at minute 1 (earliest
    # point with data). Allowed to finish naturally (rpk --timeout 300s does
    # the work), with an 8-minute hard ceiling (`timeout -k`) purely as the
    # don't-interfere-with-the-benchmark guard.
    if [ "$WARMUP_ANALYZED" = "no" ] && [ "$MIN" -ge 1 ]; then
        WARMUP_ANALYZED="yes"
        echo "  ── start-of-workload topic analyze (partition balance; finishes naturally, 8-min ceiling):"
        $S 'command -v rpk >/dev/null 2>&1 || {
          command -v unzip >/dev/null 2>&1 || apt-get install -y -qq unzip >/dev/null 2>&1 || dnf install -y -q unzip >/dev/null 2>&1
          curl -sLo /tmp/rpk.zip https://github.com/redpanda-data/redpanda/releases/latest/download/rpk-linux-amd64.zip 2>/dev/null \
          && cd /tmp && unzip -oq rpk.zip && install -m755 rpk /usr/local/bin/rpk; }
       command -v rpk >/dev/null 2>&1 && echo "  rpk ready" || echo "  ⚠ RPK INSTALL FAILED — analyze will be skipped"' || true
        $S "timeout -k 10 480 rpk topic analyze -r '.*' -X brokers=$BOOTSTRAP --time-range -1m:end --timeout 300s --print-all --format json > /tmp/${RUN_NAME}-topic-analysis-warmup.json 2>/dev/null; timeout -k 10 150 rpk topic analyze -r '.*' -X brokers=$BOOTSTRAP --time-range -1m:end --timeout 140s --print-summary 2>/dev/null | sed 's/^/    /' | head -14; pkill -f 'rpk topic analyz[e]' 2>/dev/null; true" || echo "    ⚠ start-of-workload analyze failed (non-fatal)"
    fi
    $S "grep -E 'Pub rate' /opt/benchmark/$LOG | tail -1 | cut -c1-150" || true
    if $S "grep -qE 'Exception|Worker request failed' /opt/benchmark/$LOG"; then
        echo "  ❌ ERROR detected in log:"
        $S "grep -B1 -A3 -E 'Exception' /opt/benchmark/$LOG | head -12"
        exit 1
    fi
done

echo "── 6/7 topic analysis (rpk topic analyze — batch rate/size per partition)"
# https://docs.redpanda.com/current/reference/rpk/rpk-topic-analyze/
# Consumes a sample from every partition to report batch rate, batch sizes,
# and per-partition balance — catches partition skew and batching problems
# that throughput averages hide. Time range = the whole run window.
$S 'command -v rpk >/dev/null 2>&1 || {
  command -v unzip >/dev/null 2>&1 || apt-get install -y -qq unzip >/dev/null 2>&1 || dnf install -y -q unzip >/dev/null 2>&1
  curl -sLo /tmp/rpk.zip https://github.com/redpanda-data/redpanda/releases/latest/download/rpk-linux-amd64.zip 2>/dev/null \
  && cd /tmp && unzip -oq rpk.zip && install -m755 rpk /usr/local/bin/rpk; }' || true
ANALYZE_JSON="/tmp/${RUN_NAME}-topic-analysis.json"
$S "rpk topic analyze -r '.*' -X brokers=$BOOTSTRAP --time-range -45m:end --timeout 240s --print-all --format json > $ANALYZE_JSON 2>/dev/null && echo analysis_ok; rpk topic analyze -r '.*' -X brokers=$BOOTSTRAP --time-range -45m:end --timeout 240s --print-summary 2>/dev/null | head -20" || echo "  ⚠ rpk topic analyze unavailable (topic may be deleted or rpk install failed) — skipping"

echo "── 7/7 collect results"
JSON=$($S "ls -t /opt/benchmark/*.json | head -1")
# Run directories are named by UTC date+time; README.md explains the run.
STAMP=$(date -u +%Y-%m-%d_%H%M)
OUT="results/${PROVIDER}/${STAMP}"
mkdir -p "$OUT"
cp "providers/oci/configs/workloads/$WORKLOAD" "$OUT/" 2>/dev/null || true
cp "providers/oci/configs/drivers/$DRIVER" "$OUT/" 2>/dev/null || true
cat > "$OUT/README.md" <<READMEEOF
# Benchmark Run — ${STAMP} UTC

**Run name:** ${RUN_NAME}
**Provider:** ${PROVIDER}
**Workload:** \`${WORKLOAD}\` (copy in this directory)
**Driver:** \`${DRIVER}\` (copy in this directory; bootstrap used: \`${BOOTSTRAP}\`)
**Clients:** ${CLIENTS}
**Orchestrator:** ${ORCH}

## Contents
- OMB result JSON — every 10s sample (rates, latency percentiles, backlog)
- \`run-log.txt\` — full coordinator log
- \`topic-analysis-warmup.json\` — rpk topic analyze at workload start
- \`topic-analysis.json\` — rpk topic analyze over the full window
- workload + driver YAML copies (exact configs of this run)

## Notes
(purpose / findings — fill in with the run report)
READMEEOF
# parallel + compressed transfers (collection speed)
scp -C -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ORCH:$JSON" "$OUT/" &
scp -C -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ORCH:/opt/benchmark/$LOG" "$OUT/run-log.txt" &
scp -C -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ORCH:$ANALYZE_JSON" "$OUT/topic-analysis.json" 2>/dev/null &
scp -C -o StrictHostKeyChecking=no -i "$SSH_KEY" "root@$ORCH:/tmp/${RUN_NAME}-topic-analysis-warmup.json" "$OUT/topic-analysis-warmup.json" 2>/dev/null &
wait || true
if [[ -n "$TIER" ]]; then
    python3 tools/generate-benchmark-report.py "$TIER" "$OUT/$(basename $JSON)" --provider "$PROVIDER" || true
fi
echo ""
echo "✅ run complete — results in $OUT/"
python3 - "$OUT/$(basename $JSON)" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
pr, cr = d['publishRate'], d['consumeRate']
print(f"  avg pub:  {sum(pr)/len(pr)*1024/1024**2:,.0f} MB/s   avg cons: {sum(cr)/len(cr)*1024/1024**2:,.0f} MB/s")
for k in ('aggregatedPublishLatency50pct','aggregatedPublishLatency99pct','aggregatedEndToEndLatency99pct'):
    print(f"  {k}: {d.get(k,0):,.1f} ms")
PY
