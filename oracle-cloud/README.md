# Redpanda on Oracle Cloud (OCI/OKE) — Benchmark Package

Complete, reproducible setup for benchmarking Redpanda on Oracle Cloud with
the [OpenMessaging Benchmark](https://github.com/redpanda-data/openmessaging-benchmark)
(OMB): Terraform for the infrastructure, Helm values for the cluster,
ready-made workloads from 60 MB/s to 4 GB/s, operational runbooks, and
published summaries of the July 2026 validation runs.

**➡️ Setting up? Start with [`docs/MANUAL_SETUP.md`](docs/MANUAL_SETUP.md)** —
the step-by-step path for human operators (plain bash/Terraform/Helm, no AI
tooling required).

**Headline result: [the 4 GB/s workload](4GBPS_WORKLOAD.md)** — a blended
production workload sustained at the full 4 GB/s target (both topics at
100.0%) on 6× VM.DenseIO.E4.Flex16 brokers, with single-digit-millisecond
broker produce p99. That page has the results, the exact setup that
produced them, and a half-size (3-broker) hardware configuration for
2 GB/s.

## Package map

| Path | Contents |
|------|----------|
| `providers/oci/terraform/` | Base stack: VCN/network, client VMs, monitoring node (tier + blended tfvars) |
| `providers/oci/terraform-oke/` | OKE cluster + DenseIO NVMe node pools (`e4-nvme.tfvars` = Flex8, `e4-nvme-16.tfvars` = Flex16 — the validated production shape) |
| `providers/oci/oke/` | Redpanda Helm values (`redpanda-values-nvme-16.yaml` is the config behind the 4 GB/s result) |
| `providers/oci/configs/` | **All workloads + drivers** (catalog below) |
| `providers/oci/README.md` | End-to-end runbook |
| `providers/oci/REDEPLOY_CHECKLIST.md` | Validated from-scratch deployment path |
| `providers/oci/QUIRKS.md` | Operational traps that cost hours — read before debugging |
| `skills/` | Scripted lifecycle: capacity check → deploy (verify gates) → tune → observability → run → metrics → teardown |
| `4GBPS_WORKLOAD.md` | **The flagship result + reproduction recipe** — 4 GB/s setup and half-size 2 GB/s sizing |
| `docs/MANUAL_SETUP.md` | **Step-by-step setup for human operators** — no AI tooling required |
| `docs/BENCHMARKING_QUICKSTART.md` | Guided path when driving with AI agents (Sonnet-class models) |
| `results/` | Published run summaries (4 GB/s and 2 GB/s) |
| `tools/` | Provider-agnostic helpers: cluster formation, install, report generator |
| `CLAUDE.md` | Agent guidance for operating this package with Claude Code |

## Setting up the workloads

Every benchmark run is a **(workload, driver)** pair under
`providers/oci/configs/`: the workload defines the traffic shape (topics,
partitions, rates), the driver defines client behavior (acks, batching,
replication factor). Changing durability is a driver swap with the workload
untouched.

**Workloads** (`configs/workloads/`):

| Workload | Shape |
|----------|-------|
| `workload-tier-1.yaml` | Single topic, 60 MB/s — smoke-test tier |
| `workload-blended-baseline.yaml` | Single topic, 140 partitions, 3 GiB/s ingress, 250 producers |
| `workload-blended-r2.yaml` | Baseline + no compression + 1:2 fanout (tiered-storage byte-path test) |
| `workload-blended-catchup.yaml` | Consumer-backlog drain variant |
| `workload-blended-prod-topic{A,B}-{2,3,4}gbps.yaml` | **Blended production model** — Topic A: 150 partitions, rf=3, 2× consumer fanout (20% of traffic); Topic B: 500 partitions, rf=1, 1× fanout (80%). The 2/3/4 GB/s files scale the same shape (1 KB messages) |

**Drivers** (`configs/drivers/`):

| Driver | Durability |
|--------|-----------|
| `redpanda-blended-prod-topic{A,B}.yaml` | `acks=all`, idempotence on — full durability |
| `redpanda-blended-prod-topic{A,B}-acks0.yaml` | `acks=0` — latency-floor measurement |
| `redpanda-r3-nvme.yaml` / `redpanda-r3-nvme-rf1.yaml` | rf=3 vs rf=1 comparisons |
| `redpanda-ack-all-*.yaml` | Single-topic acks=all variants |

The blended model needs **two coordinators** (OMB allows one replication
factor per coordinator) — `skills/run-blended-benchmark/` handles the dual
launch, disjoint worker fleets, and synchronized start. Single-topic runs
use `skills/run-omb-benchmark/`.

## Quick start

1. Prerequisites: OCI API key at `~/.oci/config`, SSH keypair at
   `~/.ssh/redpanda_oci{,.pub}`, Terraform ≥ 1.5.
2. Copy and fill the two templates:
   `providers/oci/terraform/compartment.auto.tfvars.template` and
   `providers/oci/.env.tiered-storage.template`.
3. Follow [`docs/MANUAL_SETUP.md`](docs/MANUAL_SETUP.md) — the sequenced,
   copy-pasteable path for human operators. Driving with an AI agent
   instead? Use [`docs/BENCHMARKING_QUICKSTART.md`](docs/BENCHMARKING_QUICKSTART.md).

Before deploying anything: `skills/check-cloud-capacity/` — on OCI, quota is
not capacity; the skill probes a real launch.

## Published results

Two run summaries are published here (raw data for both — OMB JSONs, logs,
Prometheus exports — is available on request):

- [`4GBPS_WORKLOAD.md`](4GBPS_WORKLOAD.md) — **the flagship 4 GB/s result**,
  the exact setup that produced it, and the half-size 2 GB/s hardware
  configuration. Detailed run summary:
  [`results/4GBPS_RUN_SUMMARY.md`](results/4GBPS_RUN_SUMMARY.md)
  (6× DenseIO.E4.Flex16, both topics 100.0%, broker p99 3.5 ms mid-window).
- [`results/2GBPS_RUN_SUMMARY.md`](results/2GBPS_RUN_SUMMARY.md) — the
  blended workload at 2 GB/s on 6× 8-OCPU DenseIO NVMe (acks=all,
  100% of target, broker p99 38–41 ms) — the empirical basis for the
  2 GB/s sizing.

## License

MIT — see the repository [LICENSE](../LICENSE).
