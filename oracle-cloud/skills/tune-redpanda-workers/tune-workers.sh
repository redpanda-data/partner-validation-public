#!/bin/bash
# tune-workers.sh — Tune Kubernetes worker nodes for Redpanda per the official docs:
#   https://docs.redpanda.com/current/deploy/redpanda/kubernetes/k-requirements/#storage
#   https://docs.redpanda.com/current/deploy/redpanda/kubernetes/k-tune-workers/#io
#
# For each worker node (SSH as the node user, e.g. opc on OKE Oracle Linux):
#   1. Storage: format local NVMe as XFS (RAID-0 if multiple devices) and
#      mount at /var/lib/redpanda-nvme with noatime — backing dir for local
#      PersistentVolumes (pair with local-nvme-storageclass.yaml).
#   2. Autotuner: install the redpanda package on the host, then
#      `rpk redpanda mode production` + `rpk redpanda tune all`
#      (aio_events, ballast_file, clocksource, cpu, disk_irq, disk_nomerges,
#       disk_scheduler, net, swappiness).
#   3. Optional --iotune: run `rpk iotune` (~10 min/node) to produce
#      /etc/redpanda/io-config.yaml for mounting into brokers via ConfigMap.
#
# NOTE (from docs): kernel tuning does NOT survive node reboots — rerun this
# script after any node restart or node-pool scaling event.
#
# Usage:
#   ./tune-workers.sh --node-ips <ip1,ip2,...> [--ssh-key ~/.ssh/redpanda_oci]
#                     [--ssh-user opc] [--iotune]
set -euo pipefail

NODE_IPS=""
SSH_KEY="$HOME/.ssh/redpanda_oci"
SSH_USER="opc"
RUN_IOTUNE="no"

while [[ $# -gt 0 ]]; do
    case $1 in
        --node-ips) NODE_IPS="$2"; shift 2 ;;
        --ssh-key)  SSH_KEY="$2"; shift 2 ;;
        --ssh-user) SSH_USER="$2"; shift 2 ;;
        --iotune)   RUN_IOTUNE="yes"; shift ;;
        -h|--help)  grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done
[[ -z "$NODE_IPS" ]] && { echo "Error: --node-ips required"; exit 1; }

SSH_OPTS="-o StrictHostKeyChecking=no -i $SSH_KEY"
IFS=',' read -ra NODES <<< "$NODE_IPS"

for n in "${NODES[@]}"; do
    echo "=== tuning $n ==="
    ssh $SSH_OPTS $SSH_USER@$n "sudo bash -s -- $RUN_IOTUNE" <<'TUNE'
set -e
RUN_IOTUNE="$1"

# ── 1. Storage: XFS on local NVMe (RAID-0 across multiple devices) ─────────
if mountpoint -q /var/lib/redpanda-nvme; then
    echo "  storage: already mounted"
else
    DEVS=""
    for d in /dev/nvme*n1; do
        [ -b "$d" ] || continue
        lsblk -no MOUNTPOINTS "$d" | grep -q . && continue
        DEVS="$DEVS $d"
    done
    DEVS=$(echo $DEVS)
    if [ -z "$DEVS" ]; then
        echo "  storage: no free local NVMe found (block-volume node?) — skipping"
    else
        N=$(echo "$DEVS" | wc -w)
        if [ "$N" -gt 1 ]; then
            command -v mdadm >/dev/null || dnf install -y -q mdadm
            mdadm --create /dev/md0 --level=0 --raid-devices=$N --force --run $DEVS
            TARGET=/dev/md0
            mdadm --detail --scan >> /etc/mdadm.conf || true
        else
            TARGET="$DEVS"
        fi
        mkfs.xfs -f -q "$TARGET"
        mkdir -p /var/lib/redpanda-nvme
        mount -o noatime "$TARGET" /var/lib/redpanda-nvme
        # fstab by UUID: md device names (md0 vs md127) are not stable across
        # reboots on multi-NVMe nodes (e.g. DenseIO 16-OCPU = 2 drives)
        UUID=$(blkid -s UUID -o value "$TARGET")
        grep -q redpanda-nvme /etc/fstab || echo "UUID=$UUID /var/lib/redpanda-nvme xfs noatime,nofail 0 2" >> /etc/fstab
        echo "  storage: XFS on $TARGET (${N} device(s), RAID-0 if >1) -> /var/lib/redpanda-nvme"
    fi
fi

# ── 2. Autotuner: install redpanda pkg on host, production mode, tune all ──
if ! command -v rpk >/dev/null 2>&1; then
    curl -1sLf 'https://linux.pkg.redpanda.com/setup-redpanda.rpm.sh' | bash >/dev/null 2>&1
    dnf install -y -q redpanda >/dev/null 2>&1
    systemctl disable --now redpanda 2>/dev/null || true   # binary only; broker runs in k8s
fi
rpk redpanda mode production >/dev/null
rpk redpanda tune all 2>&1 | tail -n +2 | sed 's/^/  tune: /'

# ── 3. Optional iotune ──────────────────────────────────────────────────────
if [ "$RUN_IOTUNE" = "yes" ]; then
    echo "  iotune: running (~10 min)..."
    rpk iotune --directory /var/lib/redpanda-nvme --duration 10m
    echo "  iotune: wrote /etc/redpanda/io-config.yaml"
    cat /etc/redpanda/io-config.yaml | sed 's/^/    /'
fi
echo "  ✅ $(hostname) tuned"
TUNE
done
echo "=== all nodes tuned — remember: rerun after any node reboot ==="
