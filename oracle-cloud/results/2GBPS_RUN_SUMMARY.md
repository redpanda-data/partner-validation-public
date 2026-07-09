# Partner Blended Production Workload @ 2 GB/s — Full Report

**Date:** July 8, 2026 · 16:33–17:09 UTC (5 min warmup + 30 min measured)
**Verdict:** ✅ **PASS — both topics at 100.0% of target, all consumer groups
kept pace, tiered storage delivered 4.1 TiB to OCI Object Storage with zero
backoffs, 0 under-replicated partitions.**
**Raw data:** available on request (2 OMB JSONs, run logs,
formation self-test, topic-analysis JSONs)

## Workload (true production mix, ~1:1.5 aggregate fanout)

Two topics, concurrent, one cluster — dual OMB coordinators:

| | Topic A (durable) | Topic B (high-volume) |
|---|---|---|
| Partitions / RF | 150 / **rf=3** (min.insync=2) | 500 / **rf=1** |
| Fanout | 2 groups × 150 | 1 group × 500 |
| Target | 400,000 msg/s | 1,600,000 msg/s |
| Producers | 50 | 200 |

1 KB msgs · producers unchanged (acks=all, linger 5 ms, 1 MB cap, no
compression, idempotent) · tiered ON both topics.

## Server-side shaping applied (cluster config, no workload change)

- `kafka_throughput_limit_node_out_bps = 891289600` (850 MiB/s/node)
- `cloud_storage_max_throughput_per_shard = 268435456` (256 MiB/s)

## Fleet

6× VM.DenseIO.E4.Flex8 (8 OCPU / 128 GB / 6.8 TB NVMe XFS, 8 Gbps NIC) on
OKE v1.34.2, tuned per Redpanda docs (`rpk tune all`, aio 10M) ·
12× 16-OCPU load clients (A: 4, B: 8) · Redpanda v26.1.12.

## Formation self-test (pre-load baselines)

Full `rpk cluster self-test` (disk + network + cloud): **117 test sections,
zero timeouts** across all 6 brokers. Archived: `selftest-formation.txt`.

## Results

| Metric | Topic A (rf=3, 2×) | Topic B (rf=1, 1×) |
|---|---|---|
| Publish rate | **400,023 msg/s — 100.0%** | **1,600,463 msg/s — 100.0%** |
| Consume | 781 MB/s (exactly 2×) | 1,563 MB/s (exactly 1×) |
| Client pub p50 | 34.9 ms | **8.4 ms** |
| Client pub p99 | 43.5 s* | 148.4 ms |
| Client E2E p99 | 42.0 s* | 1.88 s |

\* **Client-side buffering during transient consumer catch-up phases — NOT
broker latency**: the broker produce-handler p99 held **38–41 ms for the
entire run** (Prometheus). Same broker-vs-client distinction as the RF1
report. rf=3 + 2× fanout concentrates those catch-up bursts on topic A.

**Cluster:** broker CPU 34% avg · **0 under-replicated partitions** · no
broker instability · combined cluster Kafka throughput ~5.2 GB/s
(2.0 in + ~3.2 fetch out during catch-up, settling to 2.4 steady-state).

## Tiered storage (scenario 2 criteria)

| Metric | Value |
|---|---|
| Uploaded during run | **4,079 GiB** to `redpanda-tiered-benchmark` |
| Upload rate | ramp to **~41 uploads/s sustained** (shard cap never saturated) |
| Backoffs / errors | **0 / 0** |

## rpk topic analyze

| | Topic A (full window) | Topic B (mid-window 5-min slice†) |
|---|---|---|
| Measured throughput | 392.4 MB/s | 1,655 MB/s |
| Batch rate | 2,579 batches/s | 36,005 batches/s |
| **Avg batch size** | **152 KB** | **46 KB** |

Consistent with linger.ms=5 at each topic's per-partition rate (A: ~150
msgs/batch across 150 partitions; B: ~45 msgs/batch across 500) — no
pathological batching; both topics' 650 partitions served evenly (leader
distribution balanced across 6 brokers; CPU spread flat).

† B's 500 partitions exceed a NodePort-client analyze timeout; the slice ran
from inside the cluster. Operational note recorded in the skill: analyze
large topics via in-cluster rpk. Warmup-phase analyze failed this run
(missing `unzip` broke the rpk install silently — skill fixed: dependency
handled, timeouts raised, failures now loud).

## Pass criteria scorecard

| Criterion | Result |
|---|---|
| Both coordinators sustain target ±5% | ✅ 100.0% / 100.0% |
| Consumer groups hold lag | ✅ A 2×, B 1× — no unbounded growth |
| 0 URP / broker stability | ✅ |
| Tiered keeps pace, zero backpressure | ✅ 4.1 TiB, 0 backoffs |
| Partition distribution healthy | ✅ analyze + balanced CPU |

## Conclusions

1. **The 2 GB/s blended production model runs cleanly on 6× Flex8 NVMe** with
   shaping — the fleet OCI's current quota supports today.
2. Shaping worked as designed: egress stayed inside NIC budget; tiered
   uploads never contended visibly (broker produce p99 ~40 ms throughout,
   vs 19 ms for the pure-rf1 run at higher ingress — the delta is rf=3
   replication + doubled fanout, as expected).
3. Topic A's client-side tail is the cost of rf=3 + 2× fanout near the NIC
   budget; on 16 Gbps nodes it should collapse toward B's profile.

## Next: 3 GB/s point on Flex16 (planned)

Fleet `e4-nvme-16.tfvars` (6× 16/256/2 — 16 Gbps NIC, 2× NVMe RAID-0):
A 600K + B 2.4M msg/s. Predicted per-broker egress ~11.2 Gbps of 16 —
~30% headroom. Same shaping levers scaled (`node_out_bps` ≈ 1.7 GiB/s).
