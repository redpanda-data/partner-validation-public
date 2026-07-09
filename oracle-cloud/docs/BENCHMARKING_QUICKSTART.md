# Benchmarking Quickstart — for future runs and new hardware

How to run Redpanda partner benchmarks with this repo, written for operators
who are new to it — and for AI agents on smaller models (Sonnet-class). The
workflow was built and verified so that the model executes scripts rather
than improvising commands: every step is a skill that encodes the failure
modes already hit in practice. Your job (and the model's) is to point at the
right skill.

## One-time setup

1. Clone the repo and open Claude Code in `openmessaging-benchmark/`.
2. Credentials: OCI API key at `~/.oci/config` (key file 600 perms), SSH
   keypair at `~/.ssh/redpanda_oci{,.pub}`.
3. Copy the two templates and fill them in:
   - `providers/oci/terraform/compartment.auto.tfvars.template`
   - `providers/oci/.env.tiered-storage.template`
4. First prompt in any new session:

   > Read CLAUDE.md and providers/oci/QUIRKS.md before doing anything

   This loads the skill routing table and the known traps.

## Running a benchmark on known hardware (the common case)

Work through these prompts **in order, one at a time** — don't batch phases:

1. > Check OCI capacity for 6x DenseIO.E4.Flex16 using
   > skills/check-cloud-capacity before we deploy anything

   Quota is not capacity — this probes a real launch.

2. > Follow providers/oci/REDEPLOY_CHECKLIST.md to bring up the benchmark
   > environment. Run verify.sh after each phase and stop if it is not green.

3. > Set up observability with skills/setup-observability and share the
   > Grafana links

4. > Run the blended 2 GB/s benchmark with skills/run-blended-benchmark
   > using the workload-blended-prod-topicA/B-2gbps configs

   (Single-topic runs: `skills/run-omb-benchmark` instead. Blended = any
   workload with more than one replication factor.)

5. > Collect metrics for that run with skills/collect-run-metrics, then
   > write the report using results/4GBPS_RUN_SUMMARY.md as the template

6. > Tear everything down with skills/teardown-benchmark-infra and confirm
   > zero billing

## Deploying on new hardware

- **New shape, same cloud** — a tfvars-only change (flex shapes take
  OCPUs/memory as parameters):

  > Create a tfvars for \<shape\> based on
  > providers/oci/terraform-oke/e4-nvme-16.tfvars, then run the capacity
  > check on that shape before deploying

- **NVMe nodes always need tuning before Redpanda installs**:

  > Run skills/tune-redpanda-workers on the new node pool before helm install

- **Different cloud**:

  > Read skills/deploy-benchmark-k8s/PROVIDERS.md for \<cloud\> and
  > docs/CLOUD_PROVIDER_FRAMEWORK.md, then set up providers/\<cloud\>/
  > following that pattern

  AWS/Linode/Azure/GCP differences (EKS/LKE/AKS/GKE, NVMe shapes, tuning
  access, registry mirrors) are already mapped in PROVIDERS.md.

- **Sizing intuition before picking hardware** — the published results are
  the reference: [`4GBPS_WORKLOAD.md`](../4GBPS_WORKLOAD.md) shows what the
  validated shapes did under load (short version: NVMe doubled rf=3
  throughput; Flex8's 8 Gbps NIC was the wall; Flex16 carried 4 GB/s).

## Three rules that make this work on smaller models

1. **Name the skill or doc in the prompt** — never describe the task
   abstractly and hope the model finds the right path.
2. **One phase per prompt, and require the verify gate** — "run verify.sh
   and stop if not green". Don't let the model self-correct across phases.
3. **On any failure, check the traps first** — the next prompt is:

   > Check providers/oci/QUIRKS.md for this error before retrying

   The answer is usually already written down.

## Where things live

- Entry point + skill routing: [`CLAUDE.md`](../CLAUDE.md)
- End-to-end OCI runbook: [`providers/oci/README.md`](../providers/oci/README.md)
- From-scratch redeploy: [`providers/oci/REDEPLOY_CHECKLIST.md`](../providers/oci/REDEPLOY_CHECKLIST.md)
- Known traps: [`providers/oci/QUIRKS.md`](../providers/oci/QUIRKS.md)
- Published results: [`../4GBPS_WORKLOAD.md`](../4GBPS_WORKLOAD.md),
  [`../results/`](../results/)
- Adding a provider: [`CLOUD_PROVIDER_FRAMEWORK.md`](CLOUD_PROVIDER_FRAMEWORK.md)
