#!/bin/bash
# check-capacity.sh — Cloud-agnostic capacity/quota checker for benchmark shapes.
# Dispatches to providers.d/<provider>.sh, each implementing the same contract:
#   matrix            print quota + shape-offering availability per zone/AD
#   probe SHAPE ZONE  attempt a real (immediately-terminated) launch —
#                     quota ≠ capacity on every cloud; only a launch proves it
#
# Usage:
#   ./check-capacity.sh --provider oci                    # matrix
#   ./check-capacity.sh --provider oci --probe VM.DenseIO.E6.Ax.Flex --zone 1 --subnet-id ocid...
#   ./check-capacity.sh --provider aws --probe i4i.2xlarge --zone us-east-1a --subnet-id subnet-...
#   ./check-capacity.sh --provider gcp|azure|linode ...
#
# Validation status: oci TESTED · aws/linode INFORMED-BY-PRIOR-RUNS · azure/gcp SCAFFOLD
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PROVIDER="" ; ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --provider) PROVIDER="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
[[ -z "$PROVIDER" ]] && { echo "Error: --provider <oci|aws|linode|azure|gcp> required"; exit 1; }
MODULE="$DIR/providers.d/$PROVIDER.sh"
[[ -f "$MODULE" ]] || { echo "Error: no module for '$PROVIDER' (have: $(ls "$DIR/providers.d" | sed 's/\.sh//' | tr '\n' ' '))"; exit 1; }
exec bash "$MODULE" ${ARGS[@]+"${ARGS[@]}"}
