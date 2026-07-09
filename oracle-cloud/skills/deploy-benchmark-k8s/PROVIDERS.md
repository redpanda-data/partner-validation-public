# Provider Matrix — Redpanda Benchmark on Managed Kubernetes

The phase model in `RUNBOOK.md` (infra → node prep → redpanda → client wiring
→ OMB → observability → run) is provider-independent. This file maps each
phase's provider-specific parts. **OCI/OKE is the validated path**; AWS and
Linode entries are informed by prior runs in this repo; Azure/GCP are
researched scaffolds — verify commands before first use.

| | OCI (✅ validated) | AWS | Linode | Azure | GCP |
|---|---|---|---|---|---|
| Managed k8s | OKE | EKS | LKE | AKS | GKE |
| NVMe broker nodes | `VM.DenseIO.E4/E5/E6` (quota often 0 — check first!) | `i4i`/`i3en`/`im4gn`/`m7gd` (instance store) | all dedicated plans (host-local storage by default) | `Standard_L*s_v3` (Lsv3/Lasv3) | `n2`/`c3` + `--local-nvme-ssd-block` |
| Node OS / SSH user | DenseIO ⇒ Oracle Linux only, `opc` | AL2023/Bottlerocket, `ec2-user` | managed (no SSH by default!) | Ubuntu, `azureuser` | COS (no host pkgs!) or `ubuntu_containerd`, gcloud ssh |
| Node tuning path | SSH + `tune-workers.sh` | SSH or SSM + `tune-workers.sh` | **DaemonSet only** (no node SSH) — see docs' privileged DaemonSet approach | SSH via bastion or `az vm run-command` | use `ubuntu_containerd` node image (COS blocks rpk install); SSH via gcloud |
| Registry rate-limit risk | HIGH (seen: Docker Hub throttle) — sideload via podman | Low — mirror to ECR pull-through cache | Medium — sideload or authenticated pulls | Medium — mirror to ACR | Medium — mirror to Artifact Registry |
| External listener quirk | NodePort advertises pod hostnames → /etc/hosts on clients | Same NodePort pattern; or NLB per broker | Same NodePort pattern | Same | Same |
| Host firewall trap | Ubuntu images: iptables deny-all (VMs); firewalld (OL) | Security groups only (no host trap) | Cloud firewall product optional | NSGs only | VPC firewall rules only |
| Capacity gotcha | quota ≠ capacity; shape↔AD mapping (E6=AD-1 only, A4=AD-3 only) | InsufficientInstanceCapacity per AZ; try multiple AZs | plan availability per region | `az vm list-skus` restrictions (visible WITHOUT probe) | ZONE_RESOURCE_POOL_EXHAUSTED per zone |
| Capacity check | `check-cloud-capacity --provider oci` | `--provider aws` | `--provider linode` | `--provider azure` | `--provider gcp` |

## Per-provider phase-1 notes

- **AWS/EKS**: `eksctl create cluster` or terraform `aws_eks_cluster` + managed
  nodegroup with the NVMe instance type; instance-store NVMe appears as
  `/dev/nvme*` unformatted — `tune-workers.sh` handles it. Use an ECR
  pull-through cache for docker.redpanda.com to avoid rate limits.
- **Linode/LKE**: `linode-cli lke cluster-create`; node storage is already
  local NVMe-backed — skip the mkfs/RAID part, still deploy the storage class
  pointing at a hostPath. Tuning requires the DaemonSet variant (no node SSH).
- **Azure/AKS**: `az aks create` + nodepool `--node-vm-size Standard_L8s_v3`;
  Lsv3 NVMe devices are separate from the temp disk — verify device names
  before mkfs. Check `az vm list-skus` restrictions BEFORE creating the pool.
- **GCP/GKE**: `gcloud container clusters create` + node pool with
  `--local-nvme-ssd-block count=N` and `--image-type ubuntu_containerd`
  (COS forbids installing rpk on the host). Local SSDs are 375GB units.

## What stays identical everywhere

Helm values structure (swap storageClass), the redpanda chart, OMB client
fleet layout, `run-omb-benchmark`, `setup-observability` (any host with
Docker + public IP), tiered-storage config (point at the provider's S3-compat
endpoint — validate with `rpk cluster self-test --only-cloud-test` first),
and the workloads/drivers.
