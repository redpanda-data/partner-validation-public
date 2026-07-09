#!/bin/bash
# gcp.sh — capacity module (SCAFFOLD — not yet validated on a real project)
# NVMe on GCP = Local SSD attached to N2/C3 etc. (--local-ssd), not a shape
# family. Capacity errors: ZONE_RESOURCE_POOL_EXHAUSTED (only visible by probe).
#
#   ./check-capacity.sh --provider gcp [--region us-east1]
#   ./check-capacity.sh --provider gcp --probe n2-standard-8 --zone us-east1-b
set -uo pipefail
REGION="us-east1" PROBE="" ZONE=""
while [[ $# -gt 0 ]]; do case $1 in
    --region) REGION="$2"; shift 2 ;; --probe) PROBE="$2"; shift 2 ;;
    --zone) ZONE="$2"; shift 2 ;;
    *) echo "unknown: $1"; exit 1 ;;
esac; done

TYPES="${TYPES:-n2-standard-8 n2-standard-16 c3-standard-8}"

echo "=== REGIONAL QUOTAS (CPU + Local SSD, $REGION) ==="
gcloud compute regions describe "$REGION" --format=json 2>/dev/null | python3 -c "
import json,sys
r=json.load(sys.stdin)
for q in r.get('quotas',[]):
    if q['metric'] in ('CPUS','N2_CPUS','C3_CPUS','LOCAL_SSD_TOTAL_GB','SSD_TOTAL_GB'):
        print(f\"  {q['metric']:<20} {q['usage']:.0f}/{q['limit']:.0f}\")
"
echo ""
echo "=== MACHINE TYPE OFFERED PER ZONE ==="
for t in $TYPES; do
    printf "%-18s " "$t"
    gcloud compute machine-types list --filter="name=$t AND zone:$REGION-*" --format="value(zone)" 2>/dev/null | tr '\n' ' '; echo
done

if [[ -n "$PROBE" ]]; then
    [[ -z "$ZONE" ]] && ZONE="$REGION-b"
    echo ""
    echo "=== LAUNCH PROBE: $PROBE + 1x local NVMe SSD in $ZONE ==="
    if gcloud compute instances create capacity-probe --machine-type "$PROBE" --zone "$ZONE" \
        --local-ssd interface=NVME --image-family=ubuntu-2204-lts --image-project=ubuntu-os-cloud \
        --format="value(name)" 2>&1 | grep -q capacity-probe; then
        echo "✅ CAPACITY AVAILABLE — deleting probe"
        gcloud compute instances delete capacity-probe --zone "$ZONE" --quiet >/dev/null 2>&1
    else
        echo "❌ launch failed (ZONE_RESOURCE_POOL_EXHAUSTED = no capacity; QUOTA_EXCEEDED = limits)"
    fi
fi
