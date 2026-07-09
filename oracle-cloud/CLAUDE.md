# CLAUDE.md

Guidance for Claude Code when working in this repository (Redpanda OMB
benchmarking across cloud providers — Partner/OCI campaign merged to `main`).

**First run in this repo?** Follow `docs/BENCHMARKING_QUICKSTART.md` — the
guided path for setup, the phase-by-phase run sequence, and new-hardware/
new-cloud procedures. Work one phase per instruction and stop at any
non-green verify gate.

## Initial setup (do this at the start of a new environment)

1. **Claude Code permissions** — this repo ships a pre-approved allowlist of
   read-only commands in `.claude/settings.json` (committed). It covers
   `rpk connect blobl/lint/list`, `docker compose config/ps`, and
   `terraform output/plan/validate`, which this project uses constantly.
   - If the file is present, nothing to do — it applies automatically.
   - If a user reports excessive permission prompts, run
     `/fewer-permission-prompts` to rescan their transcripts and **merge**
     (never overwrite) new read-only patterns into `permissions.allow`.
   - Never allowlist `ssh`, `scp`, `curl`, interpreters, `terraform apply`,
     or anything that mutates state or grants arbitrary code execution.
2. **Cloud credentials** — OCI auth is an API key at `~/.oci/config`
   ([DEFAULT] profile, key file needs 600 perms). SSH keypair for instances:
   `~/.ssh/redpanda_oci{,.pub}`.
3. **Read `providers/oci/QUIRKS.md` before debugging anything on OCI.**
   The two most common time sinks (host iptables blocking all non-SSH
   traffic; first-boot apt hangs) are documented there with fixes.

## Observability (required for every benchmark run)

**Always deploy observability after cluster formation and BEFORE starting a
benchmark**, so Grafana captures the full run:

```bash
./skills/setup-observability/setup-observability.sh \
  --monitoring-host <monitoring-public-ip> \
  --broker-ips <broker-private-ip1,ip2,...> \
  --ssh-key ~/.ssh/redpanda_oci
```

- **Idempotent**: if Grafana already answers, it prints the existing endpoint
  and exits — always safe to run, so run it every time.
- Publishes a **public HTTPS endpoint** (`https://<ip-with-dashes>.sslip.io`,
  Let's Encrypt via Caddy) reachable from any laptop with no VPN. Plain
  `http://ip:3000` links do NOT work from browsers (they auto-upgrade to
  https) — always share the sslip.io URL.
- The monitoring node is created by `providers/oci/terraform/`
  (`monitoring_instance_count = 1`); ports 80/443/3000 are opened by the
  security list there.
- **Always tell the user where the dashboards are** when starting a
  benchmark run (the skill prints these too, including on the
  already-running skip path):
  - Redpanda Ops Dashboard (the one to watch during a run):
    `https://<endpoint>/d/FejE4c6nz/redpanda-ops-dashboard`
  - Kafka Topic Metrics (per-topic drilldown):
    `https://<endpoint>/d/Nxwln29Mz/kafka-topic-metrics`
- **Expectation-setting**: broker-side Grafana panels show compressed
  on-the-wire throughput — with lz4 and OMB's repetitive payloads this reads
  ~4× lower than OMB's logical MB/s (60 MB/s logical ≈ 15 MB/s wire). Warn
  the user up front so they don't think the benchmark is underperforming.
- Full docs: `skills/setup-observability/README.md`.

## Benchmark workflow (OCI)

The end-to-end runbook is `providers/oci/README.md`. Summary:
terraform apply (`providers/oci/terraform/`, tier tfvars) → fix host
iptables on all nodes → client-0 is the in-VCN orchestrator (copy up ssh key
+ `tools/form-redpanda-cluster.sh` + `tools/install-redpanda.sh` +
`providers/oci/scripts/distribute-omb.sh`) → install Redpanda on brokers →
form cluster → build OMB once on client-0, distribute to clients → deploy
observability (above) → run `bin/benchmark` from client-0 via nohup →
collect JSON → `python3 tools/generate-benchmark-report.py <tier> <json> --provider oci`
(needs `tiers-oci.tsv` at repo root) → `terraform destroy`.

Scaling to a custom shape is a tfvars-only change (flex shapes take
OCPUs/memory as parameters) — see "Scaling to a custom shape" in
`providers/oci/README.md`.

## Skills in this repo — USE THESE INSTEAD OF IMPROVISING

The full benchmark lifecycle is covered by skills with zero-judgment scripts
and verify-after-every-step gates. **Prefer running a skill over composing ad
hoc commands** — they encode every failure mode already hit in practice.

| Skill | When to use |
|-------|-------------|
| `skills/check-cloud-capacity/` | BEFORE any deploy, and whenever a launch fails. `--provider oci\|aws\|linode\|azure\|gcp` — quota + shape-offering matrix per zone/AD + real launch probe (quota ≠ capacity on every cloud). OCI module tested; others per-provider status in headers. |
| `skills/deploy-benchmark-k8s/` | Deploying the stack on managed k8s: follow `RUNBOOK.md` (validated OCI/OKE path) phase by phase; run `verify.sh <phase>` after each phase and STOP if not ✅. `PROVIDERS.md` maps AWS/Linode/Azure/GCP differences (EKS/LKE/AKS/GKE, NVMe shapes, tuning access, registry mirrors). Failure table covers every known error. |
| `skills/tune-redpanda-workers/` | After creating/scaling a DenseIO node pool, before helm install: XFS NVMe + local-PV storage class + rpk autotuner. Rerun after any node reboot. |
| `skills/setup-observability/` | After every cluster formation, before every benchmark. Idempotent — run unconditionally; share the printed HTTPS URLs with the user. |
| `skills/run-omb-benchmark/` | Single-topic benchmark runs: stages configs, heals wedged workers, launches safely, monitors (sentinel probes), collects into date-time dirs with README. |
| `skills/run-blended-benchmark/` | Mixed-durability runs (multiple topics with different rf): dual coordinators, disjoint worker fleets, synchronized launch. Use whenever a workload has more than one rf. |
| `skills/collect-run-metrics/` | RIGHT AFTER every run: time-anchored Prometheus battery (broker p99 = the headline latency, CPU, wire rates, tiered counters+backoffs, URP) → metrics.md in the run dir. Never quote client-side p99 as broker latency. |
| `skills/analyze-topics/` | Any `rpk topic analyze` need: scale-aware (in-cluster for >150 partitions), per-topic, bounded. Do not hand-roll analyze commands. |
| `skills/teardown-benchmark-infra/` | Ending a session: ordered destroy + zero-billing verification. Must print "ALL CLEAR". |
| `skills/omb-dependency-fixer/` | OMB runtime dependency errors (Netty NoSuchMethodError, JMX agent, classpath). |

## OCI MCP servers (project-scoped, in `.mcp.json`)

Two Oracle MCP servers are configured (auth rides on `~/.oci/config`):
- **oci-api**: `run_oci_command` / `get_oci_command_help` — run OCI CLI
  commands as tools (omit the `oci` prefix).
- **oci-cloud**: `find_oci_api` / `describe_oci_operation` / `invoke_oci_api`
  — discover and invoke OCI SDK operations directly, with pagination.

Prefer these over raw `oci` shell calls when exploring unfamiliar OCI
services; prefer the scripts/skills for the established benchmark workflows.

## Hard-won facts (verified 2026-07-06)

- Tenancy is subscribed to **us-ashburn-1 only**; no sub-compartments — use
  the tenancy root as `compartment_ocid`. Service limit: 600 E4 cores/AD.
- This OMB fork assembles its distribution at
  `package/target/openmessaging-benchmark-*-bin.tar.gz` — NOT
  `benchmark-framework/target/` (which `tools/install-omb-tools.sh` wrongly
  assumes; use `providers/oci/scripts/distribute-omb.sh` instead).
- `tools/form-redpanda-cluster.sh` had a seed-broker empty-advertised-address bug
  (fixed on this branch). Symptom if it regresses: Kafka clients time out
  with "Timed out waiting for a node assignment" while `rpk cluster health`
  looks fine; check `rpk cluster info` for a blank HOST on node 0.
- OMB workers must be started with `KAFKA_OPTS=" "` (the default references
  a jmx agent jar path that doesn't exist in the tarball).
