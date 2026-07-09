# Partner OCI/OKE Benchmark — Workload Spec & OMB Mapping

Source: Partner benchmark workload spec (received 2026-07-06). This document
records the spec, how it maps onto OMB workload files in this repo, and the
open items that must be resolved before the run.

## Target

| Item | Spec |
|------|------|
| Cloud / platform | OCI, Redpanda on **OKE** (Kubernetes) |
| Broker shape | `DenseIO.E4.Flex8` × **6 brokers** |
| Ingress | **3 GB/s** aggregate |
| Egress | **4 GB/s** aggregate |
| Producers | 250 |
| Topic | 1 topic, **140 partitions**, **rf=3** |
| Consumers | 140, in **1 consumer group** |
| Durability | Production-safe acks (`acks=all`, min.insync.replicas=2) — never `acks=none` |

## OMB workload files (this repo)

| Scenario | File | Notes |
|----------|------|-------|
| 1. Baseline sustained | `configs/workloads/workload-blended-baseline.yaml` | 3 GiB/s ingress, exact production shape |
| 1b. Egress validation | `configs/workloads/workload-blended-catchup.yaml` | Builds 300 GB backlog, consumers must drain at >4 GiB/s |
| 2. Tiered storage | same workloads, cluster reconfigured | Enable tiered storage on the cluster (see `TIERED_STORAGE_SETUP.md`), point at OCI Object Storage (S3-compat API), re-run |
| 3. Saturation | copy baseline, step `producerRate` up (e.g. +25% per step) | Until first bottleneck; watch Ops dashboard + node metrics |
| Driver | `configs/drivers/redpanda-ack-all-blended.yaml` | rf=3, acks=all, idempotence on |

### Spec→OMB translation decisions

1. **Message size (ASSUMPTION — needs Partner confirmation):** spec omits it.
   Files assume **1KB** ⇒ `producerRate: 3145728` (3 GiB/s). If the real
   average event size is different, set `producerRate = 3 GiB/s ÷ messageSize`.
2. **Egress 4 GB/s with 1 consumer group:** in steady state a single group
   can only consume what is produced (3 GB/s). The catch-up workload proves
   the 4 GB/s consumer capacity by draining a backlog faster than ingress.
   If Partner actually runs additional consumers (e.g. replay/analytics),
   consider a second subscription instead — that changes broker egress
   materially and should be confirmed.
3. **`consumerBacklogSizeGB: 300`** sizes the backlog so the drain phase runs
   several minutes at >4 GiB/s; adjust with disk capacity in mind.

## Blockers / open items before this can run

1. **DenseIO E4 quota is 0 in this tenancy** (all 3 ADs, checked 2026-07-06 —
   see `QUIRKS.md`). `DenseIO.E4.Flex8` requires a service-limit increase for
   `dense-io-e4-core-count` (need ≥ 48 cores for 6× 8-OCPU brokers) or the
   run falls back to `VM.Standard.E4.Flex` + high-VPU block volumes, which
   changes the disk story completely.
2. **OKE, not VMs:** the current `providers/oci/terraform` provisions plain
   compute instances. The spec requires a Kubernetes-based Redpanda cluster
   (OKE + Redpanda operator/Helm). That is new deployment work: OKE cluster,
   node pool on DenseIO shapes, local-NVMe storage class, Redpanda Helm
   values (rf=3, resources), and LB/nodePort strategy for client access.
3. **Client fleet sizing:** 3 GiB/s produce + 3–4 GiB/s consume ≈ 7 GiB/s
   (~56 Gbps) through the OMB workers. E4.Flex NICs are ~1 Gbps/OCPU. Plan
   ~8× 16-OCPU clients (≈128 Gbps aggregate) or DenseIO clients; 250
   producers + 140 consumers spread across ≥8 workers.
4. **Tiered storage target:** OCI Object Storage via its S3-compatible API —
   needs a bucket, customer secret keys, and validation (the
   `partner-validation/object-storage-test` suite covers this).
5. **Network ceiling sanity check:** rf=3 at 3 GiB/s ingress means each
   broker moves ~1.5 GiB/s (12 Gbps) of replication + client traffic on
   average, plus consume. `DenseIO.E4.Flex8` (8 OCPU) has ~8 Gbps NIC — the
   spec's own "network-bound?" question is real; expect this to be the first
   saturation candidate and capture it per Scenario 3.

## Metrics coverage

Broker CPU/memory/disk/network, produce/consume throughput, E2E latency,
consumer lag, leadership distribution, under-replicated partitions →
**Redpanda Ops Dashboard + node_exporter** (observability skill).
Tiered storage upload rate/backlog + Object Storage latency/errors →
`redpanda_cloud_storage_*` metrics (already scraped via /public_metrics).
OKE node network + OCI throttling → OCI monitoring / node_exporter on the
node pool (to be wired up with the OKE deployment).

## Expected output

A recommendation doc answering the 7 questions in the spec (sustainability,
first bottleneck, partition distribution, object storage keep-up, headroom,
next test size). Template: follow `OCI_TIER1_RESULTS.md` structure.
