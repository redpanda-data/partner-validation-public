#!/bin/bash
# linode.sh — capacity module (informed by the Feb 2026 Linode tier runs)
# Linode storage is host-local NVMe by default — no separate NVMe shape family.
# matrix: plan catalog + per-region plan availability
# probe:  create+delete a linode (capacity errors surface at create)
#
#   ./check-capacity.sh --provider linode [--region us-ord]
#   ./check-capacity.sh --provider linode --probe g7-dedicated-16gb --zone us-ord
# Requires: linode-cli configured (LINODE_CLI_TOKEN or ~/.config/linode-cli)
set -uo pipefail
REGION="us-ord" PROBE=""
while [[ $# -gt 0 ]]; do case $1 in
    --region|--zone) REGION="$2"; shift 2 ;; --probe) PROBE="$2"; shift 2 ;;
    *) echo "unknown: $1"; exit 1 ;;
esac; done

PLANS="${PLANS:-g7-dedicated-8gb g7-dedicated-16gb g7-dedicated-128gb}"

echo "=== PLAN CATALOG (benchmark tiers) ==="
linode-cli linodes types --json 2>/dev/null | python3 -c "
import json,sys
plans='$PLANS'.split()
for t in json.load(sys.stdin):
    if t['id'] in plans:
        print(f\"{t['id']:<24} vcpus={t['vcpus']:<4} mem={t['memory']//1024}GB disk={t['disk']//1024}GB \\${t['price']['hourly']}/hr\")
"
echo ""
echo "=== REGION CAPABILITIES ($REGION) ==="
linode-cli regions view "$REGION" --json 2>/dev/null | python3 -c "
import json,sys
r=json.load(sys.stdin)[0]
print(' ', r['id'], '-', ', '.join(r['capabilities'][:8]))
print('  status:', r['status'])
"
echo ""
echo "=== PLAN AVAILABILITY PER REGION (if API supports) ==="
linode-cli regions availability --json 2>/dev/null | python3 -c "
import json,sys
plans='$PLANS'.split()
try:
    for e in json.load(sys.stdin):
        if e.get('plan') in plans and e.get('region')=='$REGION':
            print(f\"  {e['plan']:<24} available={e['available']}\")
except Exception: print('  (endpoint not available in this CLI version — rely on probe)')
"

if [[ -n "$PROBE" ]]; then
    echo ""
    echo "=== LAUNCH PROBE: $PROBE in $REGION ==="
    OUT=$(linode-cli linodes create --type "$PROBE" --region "$REGION" --image linode/ubuntu22.04 \
        --root_pass "Probe-$(head -c8 /dev/urandom | base64 | tr -dc a-zA-Z0-9)aA1!" \
        --label capacity-probe --json 2>&1)
    ID=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['id'])" 2>/dev/null)
    if [[ -n "$ID" ]]; then
        echo "✅ CAPACITY AVAILABLE — deleting probe $ID"
        linode-cli linodes delete "$ID" >/dev/null 2>&1
    else
        echo "❌ $(echo "$OUT" | head -2)"
    fi
fi
