# Tune Redpanda Workers Skill

**Purpose:** Prepare and tune Kubernetes worker nodes for production Redpanda per the official docs:
- [Storage requirements](https://docs.redpanda.com/current/deploy/redpanda/kubernetes/k-requirements/#storage) — XFS on local NVMe, local PersistentVolumes, RAID-0 across multiple devices, network storage prohibited
- [Worker node tuning](https://docs.redpanda.com/current/deploy/redpanda/kubernetes/k-tune-workers/#io) — `rpk redpanda tune all` autotuner + `rpk iotune`

**Type:** Node provisioning/tuning skill
**Idempotent:** Yes (skips mounted storage; tuners are safe to rerun)

## What it does (per node, over SSH)

1. **Storage (`k-requirements#storage`)**: finds free local NVMe devices, builds RAID-0 if >1 (mdadm — e.g. DenseIO.E4 16-OCPU nodes ship **2× 6.8 TB drives → ~13.6 TB striped**), formats **XFS**, mounts at `/var/lib/redpanda-nvme` with `noatime`, persists in fstab **by UUID** (md device names drift across reboots).
2. **Autotuner (`k-tune-workers`)**: installs the redpanda package on the host (binary only, service disabled), sets `rpk redpanda mode production`, runs **`rpk redpanda tune all`** — applies aio_events (fs.aio-max-nr), ballast_file, clocksource, cpu governor, disk_irq, disk_nomerges, disk_scheduler, net, swappiness.
3. **Optional `--iotune`**: runs `rpk iotune` (~10 min/node) producing `/etc/redpanda/io-config.yaml` — mount into brokers via ConfigMap for precise IO scheduling.

Plus `local-nvme-storageclass.yaml`: local-path-provisioner config + `nvme-local` StorageClass so Redpanda PVCs land on the XFS NVMe mount (local PVs, `WaitForFirstConsumer`).

## Usage

```bash
# 1. Tune all worker nodes (after node pool is up, before helm install)
./tune-workers.sh --node-ips 10.0.1.x,10.0.1.y,... --ssh-key ~/.ssh/redpanda_oci --ssh-user opc

# 2. Local NVMe storage class
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
kubectl apply -f local-nvme-storageclass.yaml

# 3. Point the Redpanda helm values at it:
#    storage.persistentVolume.storageClass: nvme-local
#    tuning.tune_aio_events: true
```

## Critical caveats (from the docs)

- **Kernel tuning does not survive reboots** — rerun `tune-workers.sh` after any node restart or pool scaling.
- Tuning requires host access (SSH here; the docs' alternative is a privileged DaemonSet).
- `local-path` PVs are node-bound: a broker pod rescheduled to another node loses its data (fine for benchmarks; rf=3 covers production semantics).

## When to use

After creating/scaling an OKE node pool on DenseIO (local NVMe) shapes and
**before** `helm install redpanda` — the PVCs must find the `nvme-local`
storage class and tuned nodes at first scheduling.
