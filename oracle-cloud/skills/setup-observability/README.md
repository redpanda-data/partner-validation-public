# Setup Observability Skill

**Purpose:** Deploy the official [redpanda-data/observability](https://github.com/redpanda-data/observability) stack (Prometheus + Grafana with the Redpanda Ops dashboards) against a running Redpanda cluster and publish a **publicly exposed Grafana endpoint**.

**Type:** Infrastructure provisioning skill
**Idempotent:** Yes — if Grafana already answers on the monitoring host, the skill reports the existing endpoint and makes no changes.

---

## What This Skill Does

1. **Checks whether observability is already running** on the monitoring host (`GET /api/health` on port 3000). If it is, prints the endpoint and exits — it never redeploys over a live stack.
2. Otherwise, on the monitoring host it:
   - Opens the host firewall (OCI Ubuntu images block everything but SSH at the iptables level)
   - Installs Docker (get.docker.com) and git
   - Clones `redpanda-data/observability` and provisions its Grafana dashboards (Redpanda Ops Dashboard, Kafka Topic Metrics, Consumer Offsets, …)
   - Generates a Prometheus config scraping every broker's `:9644/public_metrics`
   - Starts Prometheus + Grafana via docker compose (15-day metric retention, restart unless-stopped)
3. Puts a **Caddy reverse proxy with automatic Let's Encrypt TLS** in front of Grafana, using a zero-setup `sslip.io` hostname (`<ip-with-dashes>.sslip.io`). Browsers auto-upgrade typed URLs to `https://`, so a plain-HTTP endpoint is effectively unreachable from a laptop — TLS is what makes the endpoint genuinely shareable.
4. **Publishes the endpoint**: `https://<ip-with-dashes>.sslip.io` with anonymous read-only access enabled (admin login for edits).

## Usage

```bash
./setup-observability.sh \
  --monitoring-host <monitoring-node-public-ip> \
  --broker-ips <broker-priv-ip1,broker-priv-ip2,...> \
  --ssh-key ~/.ssh/redpanda_oci \
  --grafana-password <password>   # optional, default: redpanda-benchmark
```

## Finding the dashboards

The endpoint is `https://<monitoring-ip-with-dashes>.sslip.io` (e.g. a
monitoring node at `129.80.79.8` → `https://129-80-79-8.sslip.io`). Dashboard
UIDs are fixed by the provisioned JSON, so these paths are stable across
deployments:

| Dashboard | Path | Use for |
|-----------|------|---------|
| **Redpanda Ops Dashboard** | `/d/FejE4c6nz/redpanda-ops-dashboard` | Watching a benchmark: cluster throughput, produce/fetch latency, CPU, partition health |
| Kafka Topic Metrics | `/d/Nxwln29Mz/kafka-topic-metrics` | Per-topic throughput/size drilldown |
| **OCI Object Storage / Tiered Storage** | `/d/oci-object-storage/oci-object-storage-tiered-storage` | Tiered uploads/downloads, object-store throttling (backoffs), request latency p99, local disk free (ships with this skill, `OCI-Object-Storage-Dashboard.json`) |
| Redpanda Default Dashboard | `/d/d9gY-aJ4k/redpanda-default-dashboard` | Legacy `rpk generate` view |

All dashboards are also listed under the **Redpanda** folder in Grafana's
dashboard browser (☰ → Dashboards).

**Reading throughput numbers:** broker-side panels show **compressed
(on-the-wire) bytes**. OMB benchmarks use lz4 with highly repetitive payloads,
so Grafana typically reads ~4× lower than OMB's logical MB/s (e.g. a 60 MB/s
tier-1 run shows ~15 MB/s produce traffic). Both are correct — client-side
logical bytes vs broker-side compressed bytes. Quote OMB's number for tier
targets; use Grafana for broker health and saturation.

## Prerequisites

- Monitoring host reachable over SSH as root (a small dedicated node; on OCI use the `monitoring_instance_count` variable in `providers/oci/terraform/`)
- Cloud firewall / security list allowing TCP 80, 443 (and optionally 3000) from 0.0.0.0/0 to the monitoring host — 80/443 are required for Let's Encrypt issuance and browser access
- Brokers reachable from the monitoring host on TCP 9644 (`/public_metrics` — Redpanda 22.2+)

## When To Use

- Right after cluster formation and **before** starting a benchmark, so dashboards cover the entire run.
- Re-running is always safe: an existing deployment is detected and skipped.

## Notes

- Anonymous access is read-only (Viewer role). Fine for ephemeral benchmark clusters; do not use this pattern for long-lived production monitoring.
- Prometheus is not exposed publicly — only Grafana (3000) is.
