# Redeploy From Scratch — Checklist (Partner specifics)

Follow IN ORDER when no infrastructure exists (e.g. weeks after a teardown).
Generic phases: `skills/deploy-benchmark-k8s/RUNBOOK.md`. This file is the
Partner-specific glue a fresh operator needs.

## Phase 0 — refresh stale identifiers (OCIDs go stale!)

1. **Image OCIDs** (Oracle republishes images; old OCIDs 404):
   ```bash
   TENANCY=$(grep '^tenancy=' ~/.oci/config | cut -d= -f2)
   # Ubuntu 22.04 for clients/monitoring:
   oci compute image list --compartment-id $TENANCY --operating-system "Canonical Ubuntu" \
     --operating-system-version 22.04 --sort-by TIMECREATED --sort-order DESC --query 'data[0].id'
   # OKE node image (match kubernetes_version in terraform-oke/main.tf):
   oci ce node-pool-options get --node-pool-option-id all
   ```
   Update: `providers/oci/terraform/*.tfvars` (`image_ocid`) and
   `providers/oci/terraform-oke/main.tf` (`node_image_ocid` default).
2. **Capacity check before anything**: `./skills/check-cloud-capacity/check-capacity.sh --provider oci`
   — DenseIO quota AND a `--probe` launch (quota ≠ capacity; shapes are
   AD-specific; E4 DenseIO fixed configs: 8/128/1, 16/256/2, 32/512/4).
3. **SSH key**: `~/.ssh/redpanda_oci{,.pub}` must exist (generate if lost —
   old instances are gone anyway). Tiered S3 creds:
   `providers/oci/.env.tiered-storage`; if lost, recreate from
   `.env.tiered-storage.template` (new customer secret key via
   `oci iam customer-secret-key create`). Terraform compartment:
   `terraform/compartment.auto.tfvars` from its `.template`.

## Phase 1 — main stack, THEN update OKE terraform's network defaults

```bash
cd providers/oci/terraform && terraform init && terraform apply -var-file=oke-support.tfvars
```
**CRITICAL:** `terraform-oke/main.tf` has the VCN/subnet OCIDs as variable
DEFAULTS from the last deployment — they are now stale. Refresh them:
```bash
VCN=$(terraform state show oci_core_vcn.benchmark | grep ' id ' | awk '{print $3}' | tr -d '"')
SUB=$(terraform state show oci_core_subnet.benchmark | grep ' id ' | awk '{print $3}' | tr -d '"')
NSUB=$(terraform output -raw oke_nodes_subnet_id)
# update vcn_id / subnet_id / node_subnet_id defaults in ../terraform-oke/main.tf
```

## Phase 2+ — follow RUNBOOK.md, with these Partner picks

- **Fleet choice** (ask the test owner if unspecified): Flex8 = `e4-nvme.tfvars`
  (2 GB/s class), Flex16 = `e4-nvme-16.tfvars` (3 GB/s class, 2× NVMe RAID-0).
- After OKE: fresh kubeconfig (`--overwrite`), tune-workers, image sideload
  (monitoring node is destroyed — rebuild tarballs: docker pull the redpanda,
  redpanda-operator, rancher/local-path-provisioner and busybox images on the
  new monitoring node, docker save | gzip, then sideload per QUIRKS), storage class + fully-qualified provisioner
  image, helm with the matching `redpanda-values-nvme*.yaml`.
- **Reapply shaping configs** (NOT in helm values — cluster properties):
  ```bash
  kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk cluster config set kafka_throughput_limit_node_out_bps 891289600
  kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk cluster config set cloud_storage_max_throughput_per_shard 268435456
  ```
- **Observability**: monitoring node is NEW → new IP → new sslip.io endpoint.
  Old bookmarked Grafana URLs are dead. Run the skill; share the printed URL.
- Formation self-test (full), archive into the run dir.

## Workloads for the standard runs

- Blended 2 GB/s: `workload-blended-prod-topic{A,B}-2gbps.yaml`
- Blended 3 GB/s: `workload-blended-prod-topic{A,B}-3gbps.yaml`
- Drivers: `redpanda-blended-prod-topic{A,B}.yaml` (acks=all) or `-acks0` variants
- Launch via `skills/run-blended-benchmark/run-blended.sh`
