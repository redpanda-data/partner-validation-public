#!/bin/bash
# verify.sh — Phase gate checker for the deploy runbook. Prints ✅ or the
# exact thing that is broken. Usage: ./verify.sh <infra|redpanda|workers|all>
set -uo pipefail
PHASE="${1:-all}"
KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config-oke-benchmark}"; export KUBECONFIG
FAIL=0

check_infra() {
    echo "── infra"
    NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    NOTREADY=$(kubectl get nodes --no-headers 2>/dev/null | grep -cv ' Ready ' || true)
    if [ "${NODES:-0}" -gt 0 ] && [ "${NOTREADY:-1}" = "0" ]; then
        echo "  ✅ $NODES nodes, all Ready"
    else
        echo "  ❌ nodes=$NODES notReady=$NOTREADY (kubectl get nodes)"; FAIL=1
    fi
}

check_redpanda() {
    echo "── redpanda"
    WANT=$(kubectl get statefulset redpanda -n redpanda -o jsonpath='{.spec.replicas}' 2>/dev/null)
    RUN=$(kubectl get pods -n redpanda -l app.kubernetes.io/component=redpanda-statefulset --no-headers 2>/dev/null | grep -c '2/2 *Running' || true)
    [ "${RUN:-0}" = "${WANT:-x}" ] && echo "  ✅ $RUN/$WANT broker pods Running" || { echo "  ❌ $RUN/${WANT:-?} pods Running (kubectl get pods -n redpanda)"; FAIL=1; }
    H=$(kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk cluster health 2>/dev/null | grep -c "Healthy:.*true" || true)
    [ "$H" = "1" ] && echo "  ✅ cluster healthy" || { echo "  ❌ cluster not healthy (rpk cluster health)"; FAIL=1; }
    NR=$(kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk cluster config status 2>/dev/null | grep -c true || true)
    [ "$NR" = "0" ] && echo "  ✅ no pending restarts" || { echo "  ❌ $NR brokers NEED RESTART (rollout restart statefulset/redpanda)"; FAIL=1; }
    BLANK=$(kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk cluster info 2>/dev/null | awk '$1 ~ /^[0-9]+\*?$/ && $2 !~ /[0-9a-z]/' | wc -l | tr -d ' ')
    [ "${BLANK:-0}" = "0" ] && echo "  ✅ all brokers advertise addresses" || { echo "  ❌ $BLANK broker(s) advertise a BLANK host (form-cluster bug — see QUIRKS)"; FAIL=1; }
}

check_workers() {
    echo "── workers (needs ORCH + CLIENTS env vars, e.g. ORCH=1.2.3.4 CLIENTS=10.0.0.1,10.0.0.2)"
    if [ -z "${ORCH:-}" ] || [ -z "${CLIENTS:-}" ]; then echo "  ⚠ skipped (set ORCH and CLIENTS)"; return; fi
    OK=$(ssh -o StrictHostKeyChecking=no -i "${SSH_KEY:-$HOME/.ssh/redpanda_oci}" root@$ORCH \
        'n=0; for c in '"$(echo $CLIENTS | tr ',' ' ')"'; do curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://$c:8080/counters-stats | grep -q 200 && n=$((n+1)); done; echo $n' 2>/dev/null)
    TOTAL=$(echo "$CLIENTS" | tr ',' '\n' | wc -l | tr -d ' ')
    [ "${OK:-0}" = "$TOTAL" ] && echo "  ✅ $OK/$TOTAL workers answering" || { echo "  ❌ $OK/$TOTAL workers answering — run-benchmark.sh will auto-restart wedged ones"; FAIL=1; }
}

case "$PHASE" in
    infra) check_infra ;;
    redpanda) check_redpanda ;;
    workers) check_workers ;;
    all) check_infra; check_redpanda; check_workers ;;
    *) echo "usage: verify.sh <infra|redpanda|workers|all>"; exit 1 ;;
esac
exit $FAIL
