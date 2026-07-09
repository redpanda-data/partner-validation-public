# Partner True Production Workload — Benchmark Design (not yet deployed)

**Designed July 8, 2026. Status: DESIGN ONLY — deploy on request.**

Models the real production mix (aggregate fanout ≈ 1:1.5) as two topics with
different durability and fanout, running **concurrently on one cluster**:

| | Topic A (durable) | Topic B (high-volume) |
|---|---|---|
| Partitions | 150 | 500 |
| Replication | **rf=3**, min.insync=2 | **rf=1** |
| Fanout | 2 consumer groups × 150 | 1 consumer group × 500 |
| Share of traffic | 20% | 80% |
| Producers | 50 | 200 |
| Message size | 1 KB | 1 KB |

**Load points** (msg/s at 1 KB):

| Point | Topic A | Topic B | Total |
|-------|---------|---------|-------|
| 2 GB/s | 400,000 | 1,600,000 | 2,000,000 |
| 3 GB/s | 600,000 | 2,400,000 | 3,000,000 |

## Why two OMB instances

OMB applies one `replicationFactor` per coordinator run. Mixed rf requires
**two concurrent coordinators** with disjoint worker sets, started together:

- Coordinator A: `workload-blended-prod-topicA-{2,3}gbps.yaml` +
  `redpanda-blended-prod-topicA.yaml` (rf=3)
- Coordinator B: `workload-blended-prod-topicB-{2,3}gbps.yaml` +
  `redpanda-blended-prod-topicB.yaml` (rf=1)

Producer settings unchanged from all prior runs (acks=all, linger 5 ms, 1 MB
batch, no compression, idempotent). All files in `providers/oci/configs/`.

## Worker allocation (12 clients recommended)

OMB splits each coordinator's workers 50/50 produce/consume. Sizing from the
measured ~0.77 GB/s per producer-worker (July 7 rf=1 run):

| Fleet | Workers | Produce need per worker | Consume need per worker |
|-------|---------|------------------------|-------------------------|
| A: 4 clients | 2P + 2C | 0.3 GB/s ✓ | 0.6 GB/s ✓ |
| B: 8 clients | 4P + 4C | 0.6 GB/s ✓ | 0.6 GB/s ✓ |

(8 clients total is possible — A:2/B:6 — but B's producer workers would run
at ~1.2 GB/s each, above the measured comfort zone. 12× 16-OCPU clients
≈ $1.5/hr more; recommended.)

Two `workers-a.yaml` / `workers-b.yaml` files; launch both coordinators in
the same minute so the measured windows overlap fully. Results = two JSONs
per load point; report totals as the sum, latencies per topic class.

## Cluster budget check — 6× DenseIO.E4.Flex8 (8 Gbps NIC, per-broker)

Ingress+egress per broker (even leader distribution; tiered ON):

| Load point | In: client + repl | Out: repl + fetch + tiered | NIC verdict |
|------------|-------------------|----------------------------|-------------|
| 2 GB/s | 0.33 + 0.13 = 0.46 GB/s (4.0 Gbps) | 0.13 + 0.40 + 0.33 = 0.86 GB/s (**7.4 Gbps**) | Marginal — expect tail queuing near saturation |
| 3 GB/s | 0.50 + 0.20 = 0.70 GB/s (6.0 Gbps) | 0.20 + 0.60 + 0.50 = 1.30 GB/s (**11.2 Gbps**) | **Exceeds NIC — will cap ~2.2 GB/s aggregate** |

Where: repl = topic A only (2 extra copies of 20% share); fetch = 2× A share
+ 1× B share; tiered = full ingress ÷ 6.

**Design implications:**
1. **2 GB/s point:** runnable on the current fleet; recommend the server-side
   levers from the latency analysis (available on request) (egress shaping
   ~850 MB/s/node + tiered upload cap) to keep the produce tail clean at the
   7.4 Gbps operating point.
2. **3 GB/s point:** on Flex8, either (a) accept it as a saturation
   measurement (~2.2 GB/s expected ceiling, documents headroom), or
   (b) run on **Flex16** (16/256/2 — quota already granted, 96 cores) where
   it fits with ~30% NIC headroom. For a pass/fail vs 3 GB/s, use Flex16.
3. Storage: 650 partitions, 950 partition-replicas ≈ 158/broker; local
   retention 20 GiB/partition ⇒ ~3.2 TB of 6.8 TB NVMe per broker ✓.
4. Both topics keep tiered storage on (production model);
   `retention.local.target.bytes` forces continuous uploads.

## Pass criteria (per spec intent)

- Both coordinators sustain target rates ±5% for the 30-min window
- Topic A consumer groups (×2) and topic B group hold lag ≈ 0
- 0 under-replicated partitions (topic A), no broker instability
- Tiered uploads keep pace, zero object-store backoffs
- Report broker produce p99 per topic class (Grafana handler latency is
  cluster-wide; per-topic view via OMB client percentiles)

## Launch procedure (when approved)

1. Deploy per `skills/deploy-benchmark-k8s/RUNBOOK.md` with
   `oke-support.tfvars` clients=12 and the chosen node tfvars
   (`e4-nvme.tfvars` for Flex8 / 16-OCPU variant for Flex16)
2. Build workers-a.yaml (4 clients) / workers-b.yaml (8 clients)
3. Set bootstrap in both prod drivers; start coordinator B first (bigger
   topic creation), coordinator A within the same minute
4. `rpk topic analyze` both topics post-run (in the run skill)
5. Collect two JSONs per point; aggregate report
