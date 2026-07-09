#!/bin/bash
# Distribute a pre-built OMB tarball to benchmark clients and start workers.
# Runs ON the orchestrator client (client-0) inside the VCN.
#
# This fork's maven build assembles the distribution at
# package/target/openmessaging-benchmark-*-bin.tar.gz (not
# benchmark-framework/target/ as install-omb-tools.sh expects).
#
# Usage: ./distribute-omb.sh <client-ip1,client-ip2,...> [ssh-key] [tarball] [heap-opts]
#   heap-opts e.g. "-Xms8G -Xmx24G" — overrides the worker default (-Xms4G -Xmx8G)
set -euo pipefail

CLIENT_IPS="${1:?usage: distribute-omb.sh <ip1,ip2,...> [ssh-key] [tarball] [heap-opts]}"
SSH_KEY="${2:-/root/.ssh/redpanda_oci}"
TARBALL="${3:-/tmp/openmessaging-benchmark/package/target/openmessaging-benchmark-0.0.1-SNAPSHOT-bin.tar.gz}"
HEAP_OPTS_OVERRIDE="${4:-}"
SSH_OPTS="-o StrictHostKeyChecking=no -i $SSH_KEY"

IFS=',' read -ra CLIENTS <<< "$CLIENT_IPS"

for c in "${CLIENTS[@]}"; do
(
    scp $SSH_OPTS "$TARBALL" root@$c:/tmp/omb-bin.tar.gz
    ssh $SSH_OPTS root@$c '
        set -e
        if command -v dnf >/dev/null 2>&1; then
            # Oracle Linux client (DenseIO shapes only boot OL)
            systemctl disable --now firewalld >/dev/null 2>&1 || true
            dnf install -y -q java-11-openjdk-headless tar gzip > /dev/null 2>&1
        else
            export DEBIAN_FRONTEND=noninteractive
            # wait out any cloud-init/unattended-upgrades apt lock
            for i in $(seq 1 60); do
                fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
                sleep 5
            done
            apt-get update -qq >/dev/null 2>&1 || true
            apt-get install -y -qq openjdk-11-jre-headless > /dev/null
        fi
        mkdir -p /opt/benchmark
        tar xzf /tmp/omb-bin.tar.gz -C /opt/benchmark --strip-components=1
        if [ -n "'"$HEAP_OPTS_OVERRIDE"'" ]; then
            sed -i "s/HEAP_OPTS=\"-Xms4G -Xmx8G\"/HEAP_OPTS=\"'"$HEAP_OPTS_OVERRIDE"'\"/" /opt/benchmark/bin/benchmark-worker
        fi
        # bracket trick: pattern must not match this script'"'"'s own command line
        pkill -f "BenchmarkWorke[r]" || true
        sleep 1
        cd /opt/benchmark
        # KAFKA_OPTS=" " disables the default jmx javaagent whose jar path
        # (/opt/benchmark/jmx_prometheus_javaagent-0.13.0.jar) does not exist
        KAFKA_OPTS=" " nohup bin/benchmark-worker --port 8080 --stats-port 9091 > /tmp/worker.log 2>&1 &
        sleep 5
        pgrep -f "BenchmarkWorke[r]" >/dev/null && echo "WORKER_UP $(hostname)" || { echo "WORKER_FAILED $(hostname)"; tail -5 /tmp/worker.log; }
    '
) &
done
wait
echo "=== worker distribution complete ==="
