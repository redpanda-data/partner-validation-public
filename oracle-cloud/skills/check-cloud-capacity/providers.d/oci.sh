#!/bin/bash
# oci.sh — OCI capacity module (TESTED). Invoked via ../check-capacity.sh --provider oci
#
# Answers, without any judgment calls:
#   - Which shapes have QUOTA in which ADs (service limits)
#   - Which shapes are OFFERED in which ADs (hardware exists at all)
#   - (--probe SHAPE) whether a real instance can launch RIGHT NOW
#     (quota+offered ≠ launchable: "Out of host capacity" is only visible
#      by trying; failed launches are free)
#
# Usage:
#   ./check-capacity.sh                       # matrix only
#   ./check-capacity.sh --probe VM.DenseIO.E6.Ax.Flex [--ad 1] [--subnet-id ocid...]
set -uo pipefail
export SUPPRESS_LABEL_WARNING=True

TENANCY=$(grep -E '^tenancy=' ~/.oci/config | head -1 | cut -d= -f2)
PROBE_SHAPE=""
PROBE_AD="1"
SUBNET_ID="${SUBNET_ID:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --probe) PROBE_SHAPE="$2"; shift 2 ;;
        --ad) PROBE_AD="$2"; shift 2 ;;
        --subnet-id) SUBNET_ID="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

ADS=$(oci iam availability-domain list --compartment-id "$TENANCY" --query 'data[].name' --raw-output 2>/dev/null | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin)))")

echo "=== QUOTA (available cores per AD; 0 = needs Oracle limit increase) ==="
printf "%-30s" "limit"
for ad in $ADS; do printf "%-12s" "${ad##*-AD-}"; done; echo
for limit in standard-e4-core-count standard-e5-core-count dense-io-e4-core-count dense-io-e5-core-count dense-io-e6-ax-core-count dense-a4-ax-core-count; do
    printf "%-30s" "$limit"
    for ad in $ADS; do
        v=$(oci limits resource-availability get --compartment-id "$TENANCY" --service-name compute --limit-name "$limit" --availability-domain "$ad" --query 'data.available' --raw-output 2>/dev/null)
        printf "%-12s" "AD-${ad##*-AD-}:${v:-?}"
    done; echo
done

echo ""
echo "=== SHAPE OFFERED (1 = hardware family exists in that AD) ==="
for shape in VM.Standard.E4.Flex VM.DenseIO.E4.Flex VM.DenseIO.E5.Flex VM.DenseIO.E6.Ax.Flex BM.DenseIO.A4.Ax.72; do
    printf "%-26s" "$shape"
    for ad in $ADS; do
        n=$(oci compute shape list --compartment-id "$TENANCY" --availability-domain "$ad" --all --query "data[?shape=='$shape'] | length(@)" --raw-output 2>/dev/null)
        printf "AD-%s:%-6s" "${ad##*-AD-}" "${n:-?}"
    done; echo
done

if [[ -n "$PROBE_SHAPE" ]]; then
    echo ""
    echo "=== LAUNCH PROBE: $PROBE_SHAPE in AD-$PROBE_AD ==="
    [[ -z "$SUBNET_ID" ]] && { echo "❌ --subnet-id required for probe (a subnet must exist)"; exit 1; }
    AD_FULL=$(echo "$ADS" | tr ' ' '\n' | grep "AD-$PROBE_AD")
    IMG=$(oci compute image list --compartment-id "$TENANCY" --shape "$PROBE_SHAPE" --sort-by TIMECREATED --sort-order DESC --query 'data[0].id' --raw-output 2>/dev/null)
    [[ -z "$IMG" || "$IMG" == "None" ]] && { echo "❌ no compatible image for $PROBE_SHAPE"; exit 1; }
    SHAPE_CFG=""
    [[ "$PROBE_SHAPE" == *Flex ]] && SHAPE_CFG='--shape-config {"ocpus":8,"memoryInGBs":96}'
    OUT=$(oci compute instance launch --compartment-id "$TENANCY" --availability-domain "$AD_FULL" \
        --shape "$PROBE_SHAPE" $SHAPE_CFG --image-id "$IMG" --subnet-id "$SUBNET_ID" \
        --display-name capacity-probe --query 'data.id' --raw-output 2>&1)
    if [[ "$OUT" == ocid1.instance* ]]; then
        echo "✅ CAPACITY AVAILABLE — probe launched, terminating it now"
        oci compute instance terminate --instance-id "$OUT" --force >/dev/null 2>&1
    else
        echo "❌ launch failed:"; echo "$OUT" | grep -o '"message": "[^"]*"' | head -1
    fi
fi
