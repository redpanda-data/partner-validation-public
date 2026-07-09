#!/bin/bash
# azure.sh — capacity module (SCAFFOLD — not yet validated on a real subscription)
# Azure is the one cloud that exposes capacity restrictions WITHOUT launching:
# `az vm list-skus` returns per-zone restrictions (NotAvailableForSubscription).
# NVMe (local temp/nvme disk) families for Redpanda: Lsv3 (Intel), Lasv3 (AMD).
#
#   ./check-capacity.sh --provider azure [--region eastus]
#   ./check-capacity.sh --provider azure --probe Standard_L8s_v3 --zone eastus [--rg my-rg --subnet-id /subscriptions/...]
set -uo pipefail
REGION="eastus" PROBE="" RG="" SUBNET=""
while [[ $# -gt 0 ]]; do case $1 in
    --region|--zone) REGION="$2"; shift 2 ;; --probe) PROBE="$2"; shift 2 ;;
    --rg) RG="$2"; shift 2 ;; --subnet-id) SUBNET="$2"; shift 2 ;;
    *) echo "unknown: $1"; exit 1 ;;
esac; done

SIZES="${SIZES:-Standard_L8s_v3 Standard_L16s_v3 Standard_L8as_v3 Standard_D8ds_v5}"

echo "=== QUOTA (vCPU usage/limits, $REGION) ==="
az vm list-usage --location "$REGION" --output table 2>/dev/null | grep -iE "Family|Lsv3|Lasv3|Ddsv5|Total Regional" | head -8

echo ""
echo "=== SKU RESTRICTIONS (empty restrictions = launchable; Azure shows this without a probe!) ==="
for s in $SIZES; do
    az vm list-skus --location "$REGION" --size "$s" \
      --query "[0].{name:name, zones:locationInfo[0].zones, restrictions:restrictions[].reasonCode}" -o json 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin) or {}; print(f\"  {d.get('name','?'):<22} zones={d.get('zones')} restrictions={d.get('restrictions') or 'NONE ✅'}\")"
done

if [[ -n "$PROBE" ]]; then
    [[ -z "$RG" ]] && { echo "❌ --rg required for probe"; exit 1; }
    echo ""
    echo "=== LAUNCH PROBE: $PROBE in $REGION ==="
    OUT=$(az vm create -g "$RG" -n capacity-probe --image Ubuntu2204 --size "$PROBE" \
        ${SUBNET:+--subnet "$SUBNET"} --generate-ssh-keys --query 'id' -o tsv 2>&1)
    if [[ "$OUT" == /subscriptions/* ]]; then
        echo "✅ CAPACITY AVAILABLE — deleting probe"
        az vm delete -g "$RG" -n capacity-probe --yes >/dev/null 2>&1
    else
        echo "❌ $(echo "$OUT" | grep -oiE 'SkuNotAvailable|AllocationFailed|QuotaExceeded|[A-Za-z]+Error' | head -1): $(echo "$OUT" | head -1)"
    fi
fi
