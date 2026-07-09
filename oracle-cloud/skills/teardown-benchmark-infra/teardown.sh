#!/bin/bash
# teardown.sh — Ordered, verified teardown of all OCI benchmark infrastructure.
# Order matters: k8s volumes → OKE → main stack (OKE attaches to the VCN) →
# bucket objects. Ends with a billing verification that must show all zeros.
#
# Usage: ./skills/teardown-benchmark-infra/teardown.sh [--keep-network] [--tfvars blended-baseline.tfvars]
set -uo pipefail
export SUPPRESS_LABEL_WARNING=True

KEEP_NETWORK="no"
TFVARS="blended-baseline.tfvars"
while [[ $# -gt 0 ]]; do
    case $1 in
        --keep-network) KEEP_NETWORK="yes"; shift ;;
        --tfvars) TFVARS="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

TENANCY=$(grep -E '^tenancy=' ~/.oci/config | head -1 | cut -d= -f2)
ROOT=$(git rev-parse --show-toplevel 2>/dev/null)/openmessaging-benchmark
[ -d "$ROOT/providers" ] || ROOT=$(pwd)

echo "── 1/5 release k8s volumes (if cluster reachable)"
if kubectl get ns redpanda >/dev/null 2>&1; then
    helm uninstall redpanda -n redpanda --wait --timeout 5m 2>/dev/null || true
    kubectl delete pvc --all -n redpanda --timeout=180s 2>/dev/null || true
    for i in $(seq 1 36); do
        [ "$(kubectl get pv --no-headers 2>/dev/null | wc -l | tr -d ' ')" = "0" ] && break
        sleep 5
    done
    echo "  PVs remaining: $(kubectl get pv --no-headers 2>/dev/null | wc -l | tr -d ' ')"
else
    echo "  cluster unreachable — skipping (volumes die with terraform destroy)"
fi

echo "── 2/5 destroy OKE stack"
cd "$ROOT/providers/oci/terraform-oke" && terraform destroy -auto-approve 2>&1 | grep -E "Destroy complete|Error" | tail -2

echo "── 3/5 destroy main stack"
cd "$ROOT/providers/oci/terraform"
if [ "$KEEP_NETWORK" = "yes" ]; then
    terraform destroy -var-file="$TFVARS" -auto-approve \
      -target=oci_core_instance.redpanda -target=oci_core_instance.client -target=oci_core_instance.monitoring 2>&1 | grep -E "Destroy complete|Error" | tail -2
    echo "  (network kept per --keep-network)"
else
    terraform destroy -var-file="$TFVARS" -auto-approve 2>&1 | grep -E "Destroy complete|Error" | tail -2
fi

echo "── 4/5 empty tiered-storage bucket"
oci os object bulk-delete --bucket-name redpanda-tiered-benchmark --force >/dev/null 2>&1 || true
echo "  bucket emptied (bucket kept — empty is free)"

echo "── 5/5 VERIFY ZERO BILLING"
FAIL=0
INST=$(oci compute instance list --compartment-id "$TENANCY" --all --query 'data[?"lifecycle-state"!=`TERMINATED`] | length(@)' --raw-output 2>/dev/null)
VOL=$(oci bv volume list --compartment-id "$TENANCY" --all --query 'data[?"lifecycle-state"==`AVAILABLE`] | length(@)' --raw-output 2>/dev/null)
OKE=$(oci ce cluster list --compartment-id "$TENANCY" --query 'data[?"lifecycle-state"!=`DELETED`] | length(@)' --raw-output 2>/dev/null)
echo "  instances (non-terminated): ${INST:-?}   block volumes: ${VOL:-?}   OKE clusters: ${OKE:-?}"
[ "${INST:-1}" = "0" ] && [ "${VOL:-1}" = "0" ] && [ "${OKE:-1}" = "0" ] && echo "✅ ALL CLEAR — nothing billing" || { echo "❌ RESOURCES REMAIN — investigate the non-zero counts above"; FAIL=1; }
exit $FAIL
