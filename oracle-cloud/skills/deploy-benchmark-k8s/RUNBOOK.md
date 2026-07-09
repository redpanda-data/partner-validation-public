# Deploy Redpanda Benchmark on Managed Kubernetes — Runbook

**Validated path: OCI/OKE** (commands below). For AWS/Linode/Azure/GCP
specifics see `PROVIDERS.md` — same phases, different phase-1/2 commands.

Execute phases **in order**. After each phase, run `./verify.sh <phase>` —
do not continue until it prints ✅. Every failure mode seen in practice is in
the table at the bottom; check there before improvising.

All commands run from the repo root. Prereqs: `~/.oci/config`,
`~/.ssh/redpanda_oci`, terraform, kubectl, helm.

## Phase 1 — Infrastructure

```bash
cd providers/oci/terraform
terraform apply -var-file=blended-baseline.tfvars -auto-approve      # clients + monitoring + VCN
cd ../terraform-oke
terraform apply -var-file=<your>.tfvars -auto-approve                # OKE cluster + node pool
oci ce cluster create-kubeconfig --cluster-id $(terraform output -raw cluster_id) \
  --file ~/.kube/config-oke-benchmark --region us-ashburn-1 --token-version 2.0.0 \
  --kube-endpoint PUBLIC_ENDPOINT
export KUBECONFIG=~/.kube/config-oke-benchmark
```
Verify: `./skills/deploy-benchmark-oke/verify.sh infra` → all nodes `Ready`.

## Phase 2 — Node prep (firewall + storage + tuning)

```bash
# host firewall on clients+monitoring (Ubuntu default-deny — QUIRKS.md):
#   iptables -P INPUT ACCEPT && iptables -F INPUT && netfilter-persistent save
# OKE nodes (DenseIO/NVMe) — storage + autotuner:
./skills/tune-redpanda-workers/tune-workers.sh --node-ips <node-ip,...> --ssh-key ~/.ssh/redpanda_oci
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
kubectl apply -f skills/tune-redpanda-workers/local-nvme-storageclass.yaml
```

## Phase 3 — Redpanda

```bash
kubectl create namespace redpanda
source providers/oci/.env.tiered-storage   # S3 creds (gitignored)
helm install redpanda redpanda/redpanda -n redpanda \
  -f providers/oci/oke/redpanda-values-nvme.yaml \
  --set-string "storage.tiered.config.cloud_storage_access_key=$S3_ACCESS_KEY" \
  --set-string "storage.tiered.config.cloud_storage_secret_key=$S3_SECRET_KEY" \
  --wait --timeout 20m
```
If pods stick in `Init:ImagePullBackOff` → **image sideload** (QUIRKS.md):
pull both images on the monitoring node with docker, `docker save | gzip`,
scp to each OKE node, `sudo dnf install -y podman && sudo podman load` —
serialize the loop, OKE sshd drops parallel connections.

After install: `kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk cluster config status`.
If `NEEDS-RESTART true`: `kubectl rollout restart statefulset/redpanda -n redpanda` and wait.
Then validate object storage: `rpk cluster self-test start --only-cloud-test --no-confirm`.

Verify: `./verify.sh redpanda` → 6/6 Running, Healthy true, cloud self-test Put/Get pass.

## Phase 4 — Client access wiring

External NodePort listeners advertise pod hostnames (`redpanda-N`) that VMs
can't resolve. Map them on EVERY client:

```bash
kubectl get pods -n redpanda -o wide   # pod → node IP mapping
# on each client: append "<nodeIP> redpanda-N" lines to /etc/hosts
```
Bootstrap servers for the driver = every `<nodeIP>:31092`.

## Phase 5 — OMB clients

```bash
# on client-0: install jdk/maven/git, clone + mvn clean install -DskipTests -Dlicense.skip=true
# tarball is at package/target/openmessaging-benchmark-*-bin.tar.gz (NOT benchmark-framework/)
# then: bash distribute-omb.sh <client-ips> /root/.ssh/redpanda_oci <tarball> "-Xms8G -Xmx24G"
```
Verify: `./verify.sh workers` → N/N workers return HTTP 200.

## Phase 6 — Observability (mandatory before any run)

```bash
./skills/setup-observability/setup-observability.sh \
  --monitoring-host <monitoring-public-ip> --broker-ips <node-ip,...> --admin-port 31644
```
Share the printed HTTPS Grafana URL with the user (http://ip:3000 does NOT work in browsers).

## Phase 7 — Run

```bash
./skills/run-omb-benchmark/run-benchmark.sh --orchestrator <client-0-pub-ip> \
  --clients <client-priv-ips> --bootstrap <nodeIP:31092,...> \
  --workload <w>.yaml --driver <d>.yaml --run-name <name>
```

## Failure table

| Symptom | Cause → Fix |
|---|---|
| `Out of host capacity` | No physical hosts for shape/AD. Use `skills/check-cloud-capacity --provider <cloud>`; watcher-retry or different shape/AD. Quota ≠ capacity. |
| `Shape ... not valid for image` | Wrong image for shape (DenseIO needs Oracle Linux; check `image-shape-compatibility-entry list`). |
| `404 NotAuthorizedOrNotFound` on launch | Shape not offered in that AD at all — check per-AD with `oci compute shape list --availability-domain`. |
| `LimitExceeded dense-*` | Quota. Oracle limit increase required; see check-oci-capacity output. |
| Pods `Init:ImagePullBackOff toomanyrequests` | Docker Hub rate limit → image sideload procedure (Phase 3). |
| `NEEDS-RESTART true` after config job | cloud_storage_enabled set post-boot → rolling restart (Phase 3). |
| Clients time out `node assignment` / can't produce | NodePort hostname advertising → /etc/hosts mapping missing (Phase 4). |
| Worker HTTP 500 `/create-topics` or timeouts | Wedged workers from a killed run → run-benchmark.sh auto-restarts; or check broker advertised addresses (`rpk cluster info` — blank HOST = form bug). |
| Everything installed but no traffic flows | Host iptables (Ubuntu default-deny) — Phase 2 firewall step skipped. |
| apt hangs/404s on clients | First-boot apt lock/stale lists — kill stuck `apt`, `apt-get update`, retry. |
