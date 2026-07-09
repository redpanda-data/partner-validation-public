#!/bin/bash
# collect-metrics.sh — Pull the standard Prometheus battery for a benchmark
# run window and write metrics.md into the run's results directory.
#
# This was done by hand after every run; a less capable model gets it wrong.
# CRITICAL LESSONS ENCODED:
#   - always TIME-ANCHOR queries to the run window (now-anchored rate() reads
#     miss the run entirely once it's over)
#   - report BROKER-side produce p99 (handler histogram) as the headline —
#     OMB's client-side p99 includes producer queuing and reads seconds when
#     offered load exceeds capacity
#   - for counters (tiered uploads), read BOTH the rate profile at several
#     points AND the cumulative counter — a single spot-rate of 0 misled us
#     once when uploads simply hadn't ramped yet
#
# Usage:
#   ./collect-metrics.sh --monitoring-host <grafana-node-ip> \
#     --start 2026-07-08T21:30:00Z --end 2026-07-08T22:01:00Z \
#     --out results/oci/2026-07-08_2125 [--ssh-key path]
set -euo pipefail

MON="" START="" END="" OUT="" SSH_KEY="$HOME/.ssh/redpanda_oci"
while [[ $# -gt 0 ]]; do case $1 in
    --monitoring-host) MON="$2"; shift 2 ;;
    --start) START="$2"; shift 2 ;;
    --end) END="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --ssh-key) SSH_KEY="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Unknown: $1"; exit 1 ;;
esac; done
for v in MON START END OUT; do [[ -z "${!v}" ]] && { echo "Error: --$(echo $v | tr A-Z a-z) required"; exit 1; }; done
mkdir -p "$OUT"

q() { # q <promql> <iso-time>  → scalar or 'nodata'
    ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" root@$MON \
      "docker exec prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=$1&time=$2'" 2>/dev/null \
      | python3 -c "import json,sys
try:
    r=json.load(sys.stdin)['data']['result']
    print(float(r[0]['value'][1]) if r else 'nodata')
except Exception: print('nodata')"
}
enc() { python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$1"; }

MID=$(python3 -c "
from datetime import datetime,timezone
a=datetime.fromisoformat('$START'.replace('Z','+00:00')); b=datetime.fromisoformat('$END'.replace('Z','+00:00'))
print((a+(b-a)/2).strftime('%Y-%m-%dT%H:%M:%SZ'))")

P99Q=$(enc 'histogram_quantile(0.99,sum by (le) (rate(redpanda_kafka_handler_latency_seconds_bucket{handler="produce"}[10m])))')
P50Q=$(enc 'histogram_quantile(0.5,sum by (le) (rate(redpanda_kafka_handler_latency_seconds_bucket{handler="produce"}[10m])))')
CPUQ=$(enc 'avg(rate(redpanda_cpu_busy_seconds_total[10m]))')
INQ=$(enc 'sum(rate(redpanda_kafka_request_bytes_total{redpanda_request="produce"}[10m]))')
OUTQ=$(enc 'sum(rate(redpanda_kafka_request_bytes_total{redpanda_request="consume"}[10m]))')
UPRQ=$(enc 'sum(rate(redpanda_cloud_client_uploads[10m]))')
UPTQ=$(enc 'sum(redpanda_cloud_client_uploads)')
BOQ=$(enc 'sum(increase(redpanda_cloud_client_upload_backoff[35m]))')
URPQ=$(enc 'sum(redpanda_kafka_under_replicated_replicas)')

fmt_ms(){ python3 -c "v='$1'; print(f'{float(v)*1000:,.1f} ms' if v!='nodata' else 'no data')"; }
fmt_mb(){ python3 -c "v='$1'; print(f'{float(v)/1048576:,.0f} MB/s' if v!='nodata' else 'no data')"; }
fmt_pc(){ python3 -c "v='$1'; print(f'{float(v)*100:,.0f}%' if v!='nodata' else 'no data')"; }
fmt_n(){ python3 -c "v='$1'; print(f'{float(v):,.1f}' if v!='nodata' else 'no data')"; }

{
echo "# Run Metrics (Prometheus, time-anchored) — window $START .. $END"
echo ""
echo "| Metric | mid-window | end-of-window |"
echo "|---|---|---|"
echo "| Broker produce p50 | $(fmt_ms $(q $P50Q $MID)) | $(fmt_ms $(q $P50Q $END)) |"
echo "| **Broker produce p99** | **$(fmt_ms $(q $P99Q $MID))** | **$(fmt_ms $(q $P99Q $END))** |"
echo "| Broker CPU (busy) | $(fmt_pc $(q $CPUQ $MID)) | $(fmt_pc $(q $CPUQ $END)) |"
echo "| Produce wire rate | $(fmt_mb $(q $INQ $MID)) | $(fmt_mb $(q $INQ $END)) |"
echo "| Fetch wire rate | $(fmt_mb $(q $OUTQ $MID)) | $(fmt_mb $(q $OUTQ $END)) |"
echo "| Tiered uploads/s | $(fmt_n $(q $UPRQ $MID)) | $(fmt_n $(q $UPRQ $END)) |"
echo "| Under-replicated partitions | $(fmt_n $(q $URPQ $MID)) | $(fmt_n $(q $URPQ $END)) |"
echo ""
echo "- Tiered uploads (cumulative counter at end): $(fmt_n $(q $UPTQ $END))"
echo "- Tiered upload backoffs over window: $(fmt_n $(q $BOQ $END)) (must be 0)"
echo ""
echo "Notes: broker-side p99 is the headline latency (client-side OMB p99"
echo "includes producer queuing). Wire rates are post-compression; with"
echo "compression=none they equal logical rates."
} > "$OUT/metrics.md"
cat "$OUT/metrics.md"
echo ""
echo "✅ written to $OUT/metrics.md"
