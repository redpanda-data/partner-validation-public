#!/bin/bash
# Prepare DenseIO brokers: host firewall + local NVMe data disk.
# Runs ON the orchestrator client inside the VCN.
#
# - Flushes the OCI Ubuntu default iptables (blocks all but SSH — QUIRKS.md)
# - Formats the local NVMe device as XFS and mounts it at
#   /var/lib/redpanda/data (idempotent: skips if already mounted)
# - chowns to redpanda:redpanda if the user exists (run again after
#   install-redpanda.sh if needed)
#
# Usage: ./prep-broker-nvme.sh <broker-ip1,ip2,...> [ssh-key]
set -euo pipefail

BROKER_IPS="${1:?usage: prep-broker-nvme.sh <ip1,ip2,...> [ssh-key]}"
SSH_KEY="${2:-/root/.ssh/redpanda_oci}"
SSH_OPTS="-o StrictHostKeyChecking=no -i $SSH_KEY"

IFS=',' read -ra BROKERS <<< "$BROKER_IPS"

for b in "${BROKERS[@]}"; do
(
    ssh $SSH_OPTS root@$b '
        set -e
        # Ubuntu images: default-deny iptables; Oracle Linux: firewalld
        systemctl is-active firewalld >/dev/null 2>&1 && systemctl disable --now firewalld >/dev/null 2>&1 || true
        iptables -P INPUT ACCEPT && iptables -F INPUT && (netfilter-persistent save >/dev/null 2>&1 || true)

        if mountpoint -q /var/lib/redpanda/data; then
            echo "NVME_ALREADY_MOUNTED $(hostname)"
        else
            # local NVMe = nvme devices with no partitions/mounts (boot is a block volume)
            DEVS=""
            for d in /dev/nvme*n1; do
                [ -b "$d" ] || continue
                lsblk -no MOUNTPOINTS "$d" | grep -q . && continue
                DEVS="$DEVS $d"
            done
            DEVS=$(echo $DEVS)
            [ -n "$DEVS" ] || { echo "NVME_NOT_FOUND $(hostname)"; exit 1; }
            N=$(echo "$DEVS" | wc -w)
            if [ "$N" -gt 1 ]; then
                # multiple NVMe (bare metal): RAID0 for a single data volume
                command -v mdadm >/dev/null || (dnf install -y -q mdadm 2>/dev/null || apt-get install -y -qq mdadm)
                mdadm --create /dev/md0 --level=0 --raid-devices=$N --force --run $DEVS
                TARGET=/dev/md0
                mdadm --detail --scan >> /etc/mdadm.conf 2>/dev/null || true
            else
                TARGET="$DEVS"
            fi
            mkfs.xfs -f -q "$TARGET"
            mkdir -p /var/lib/redpanda/data
            mount -o noatime "$TARGET" /var/lib/redpanda/data
            grep -q "/var/lib/redpanda/data" /etc/fstab || \
                echo "$TARGET /var/lib/redpanda/data xfs noatime,nofail 0 2" >> /etc/fstab
            echo "NVME_MOUNTED $(hostname) $TARGET (${N}x) $(df -h /var/lib/redpanda/data | tail -1 | awk "{print \$2}")"
        fi
        id redpanda >/dev/null 2>&1 && chown -R redpanda:redpanda /var/lib/redpanda || true
    '
) &
done
wait
echo "=== NVMe prep complete ==="
