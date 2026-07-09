# 4 GB/s Workload — Results and Setup

The flagship result of this package: a blended production workload
sustained at the **full 4 GB/s target** on Oracle Cloud. This page has the
results, the exact hardware and software configuration to reproduce it, and
a half-size hardware configuration for a 2 GB/s deployment.

## The workload

Two topics, produced and consumed simultaneously (1 KB messages):

| Topic | Partitions | Replication | Consumer fanout | Share | Rate at 4 GB/s |
|-------|-----------|-------------|-----------------|-------|----------------|
| A | 150 | rf=3 | 2× | 20% | 800,000 msg/s |
| B | 500 | rf=1 | 1× | 80% | 3,200,000 msg/s |

Aggregate: 4.0 GB/s ingress, 4.8 GB/s egress, with tiered storage
continuously uploading to OCI Object Storage throughout.

## Results (30-minute measured window, July 9 2026)

| Metric | Value |
|---|---|
| Topic A achieved | **800,291 msg/s — 100.0% of target**, consumers at exactly 2× |
| Topic B achieved | **3,201,151 msg/s — 100.0% of target**, consumers 1:1 |
| Broker-side ingest (wire) | 3,944 MB/s sustained |
| Fetch (wire) | ~5.4 GB/s |
| **Broker produce p99** | **3.5 ms** mid-window → 11.5 ms late-window |
| Broker produce p50 | 0.3–0.4 ms |
| Broker CPU | 30% |
| Under-replicated partitions | 0 for the entire window |
| Tiered storage | 72 uploads/s, **zero backoffs** (OCI Object Storage never throttled) |
| Per-broker NIC utilization | ~13.9 of 16 Gbps — the true margin at 4 GB/s |

Durability posture of this run: `acks=0` with `write_caching_default=true`
(relaxed-fsync). With full fsync durability (`acks=all`) the same fleet
sustained 3 GB/s at p99 28–29 ms. Full run summary:
[`results/4GBPS_RUN_SUMMARY.md`](results/4GBPS_RUN_SUMMARY.md). Raw OMB
JSONs, logs, and Prometheus metrics are available on request.

## Hardware configuration — 4 GB/s

| Role | Count | Shape | Per-node |
|------|-------|-------|----------|
| Redpanda brokers | **6** | `VM.DenseIO.E4.Flex` (16 OCPU fixed config) | 16 OCPU / 256 GB RAM / 2× 6.8 TB NVMe (RAID-0) / 16 Gbps NIC |
| Benchmark clients | 12 | `VM.DenseIO.E4.Flex` (8 OCPU) | 8 OCPU / 128 GB / 8 Gbps NIC |
| Monitoring | 1 | small flex VM | Prometheus + Grafana |

Why this shape: OCI NICs scale at 1 Gbps per OCPU and are bundled with the
OCPU count — the 16 Gbps NIC is what carries 4 GB/s (the 8-OCPU/8 Gbps
variant walls at roughly 1 GB/s per node of acked traffic). Local NVMe is
required: block volumes cap uncompressed ingress at ~528 MB/s per cluster
of this size (measured).

## Hardware configuration — 2 GB/s (half-size cluster)

| Role | Count | Shape | Per-node |
|------|-------|-------|----------|
| Redpanda brokers | **3** | `VM.DenseIO.E4.Flex` (16 OCPU fixed config) | 16 OCPU / 256 GB RAM / 2× 6.8 TB NVMe (RAID-0) / 16 Gbps NIC |
| Benchmark clients | 6 | `VM.DenseIO.E4.Flex` (8 OCPU) | 8 OCPU / 128 GB / 8 Gbps NIC |
| Monitoring | 1 | small flex VM | Prometheus + Grafana |

At 2 GB/s across 3 nodes, the per-node load is identical to the validated
4 GB/s run across 6 nodes (~14 of 16 Gbps NIC at peak), so the headroom
profile carries over directly. Two notes:

- **3 nodes is the rf=3 minimum** — every node holds a replica of every
  Topic A partition, so one node down means under-replication until it
  returns. If you want failure headroom, use 4 nodes.
- An equivalent-aggregate alternative validated empirically at 2 GB/s:
  6× 8-OCPU DenseIO (same total OCPUs and NIC bandwidth, more/smaller
  nodes) — see [`results/2GBPS_RUN_SUMMARY.md`](results/2GBPS_RUN_SUMMARY.md).

Use the 2 GB/s workload files (`workload-blended-prod-topic{A,B}-2gbps.yaml`)
with the same drivers and cluster settings as below.

## Specific setup instructions

Full step-by-step (every command, from empty tenancy to report):
[`docs/MANUAL_SETUP.md`](docs/MANUAL_SETUP.md). The exact inputs that
produced the result above:

1. **Node pool**: `providers/oci/terraform-oke/e4-nvme-16.tfvars`
   (`node_count = 6`; set `node_count = 3` for the 2 GB/s cluster).
2. **Node prep** (required before installing Redpanda):
   `skills/tune-redpanda-workers/tune-workers.sh` — formats the 2× NVMe as
   XFS RAID-0 and runs the rpk autotuner — then apply
   `skills/tune-redpanda-workers/local-nvme-storageclass.yaml`.
3. **Helm values**: `providers/oci/oke/redpanda-values-nvme-16.yaml`
   (30 cores / 200 Gi per broker, NVMe local PVs, NodePort 31092/31644,
   tiered storage to OCI Object Storage).
4. **Cluster settings for this run** (applied via rpk after install):
   ```bash
   rpk cluster config set write_caching_default true
   # no throughput shaping — verify both are unset/null:
   #   kafka_throughput_limit_node_out_bps, cloud_storage_max_throughput_per_shard
   ```
   Shaping matters: an 850 MiB/s-per-node egress cap left in place turned
   this same fleet's 4 GB/s attempt into a 3.38 GB/s ceiling with 200 ms
   p99. On 16 Gbps nodes, run unshaped.
5. **Workloads**: `providers/oci/configs/workloads/workload-blended-prod-topic{A,B}-4gbps.yaml`
6. **Drivers**: `providers/oci/configs/drivers/redpanda-blended-prod-topic{A,B}-acks0.yaml`
   (for full-durability testing use the non-`acks0` drivers: `acks=all`,
   idempotence on)
7. **Launch**: `skills/run-blended-benchmark/run-blended.sh` — the blended
   workload needs two OMB coordinators (one per replication factor) on
   disjoint worker fleets; the script handles the split (4 clients for
   topic A, 8 for topic B) and the synchronized start.

Software versions from the run: Redpanda v26.1.12, OKE Kubernetes v1.34.2,
Redpanda Helm chart (current at July 2026), OMB from
[redpanda-data/openmessaging-benchmark](https://github.com/redpanda-data/openmessaging-benchmark).
