# Partner Blended @ 4 GB/s — Unthrottled + write_caching (acks=0) — Report

**Date:** July 9, 2026, 03:50–04:29 UTC · **Raw data:** available on request
**Verdict:** ✅ **Full 4 GB/s sustained — Topic A 100.0%, Topic B 100.0%** on
6× Flex16 NVMe with shaping removed. Yesterday's ~3.38 GB/s "ceiling" was the
850 MiB/s egress cap, not the hardware.

## Configuration

Identical to the write_caching run (2026-07-09_0348) — write_caching_default
=true, NO shaping caps, acks=0 — scaled to the 4 GB/s point (A 800K rf=3 2× +
B 3.2M rf=1 1×). Fleet: 6× DenseIO.E4.Flex16 (2× NVMe RAID-0, 16 Gbps).
Clients: 12× DenseIO.E4.Flex8/OL9.

## Results (30-min window)

| Metric | Value |
|---|---|
| Topic A | **800,291 msg/s (100.04%)**, consumers exactly 2× |
| Topic B | **3,201,151 msg/s (100.04%)**, consumers 1:1 |
| Broker-side ingest | 3,944 MB/s sustained |
| Fetch wire | ~5.4 GB/s |
| **Broker produce p99** | **3.5 ms mid-window → 11.5 ms late-window** |
| Broker produce p50 | 0.3–0.4 ms |
| Broker CPU | 30% |
| Tiered | 72 uploads/s, 0 backoffs |
| Per-broker NIC | ~1.62 GB/s out ≈ 13.9 Gbps of 16 — the true margin at 4 GB/s |

## The capped-vs-uncapped A/B (same fleet, same workload, one day apart)

| | Capped (850 MiB/s/node) | **Uncapped (this run)** |
|---|---|---|
| Achieved ingest | ~3.38 GB/s (84%) | **3.94 GB/s (100%)** |
| Consumers | lagged unboundedly | line rate |
| Broker p99 | 206–226 ms (over-offer queuing) | 3.5–11.5 ms |

**Takeaway:** the egress shaping that protected the produce tail on 8 Gbps
Flex8 NICs becomes the binding constraint on 16 Gbps Flex16 — at this fleet
class, run unshaped (or cap near line rate). The rising late-window p99
(3.5→11.5 ms) tracks growing NVMe data volume + tiered churn and is the
early signal of the next ceiling (~4.5–5 GB/s extrapolated NIC-bound).

## Session close-out

This was the final run of the July 7–9 validation. Cluster torn down after
publication. The one designed-but-unrun experiment: **write_caching +
acks=all** at 3 GB/s (production durability <10 ms candidate; measured
bounds 1.8 ↔ 29 ms).
