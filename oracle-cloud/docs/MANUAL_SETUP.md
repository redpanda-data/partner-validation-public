# Manual Setup — the complete walkthrough (no AI tooling required)

This is the full, self-contained path from an empty OCI tenancy to a
finished benchmark report. Everything is plain bash, Terraform, and Helm.
Each step says what it does, gives the exact commands, and tells you what
you should see before moving on. (Driving with an AI agent instead? Use
[`BENCHMARKING_QUICKSTART.md`](BENCHMARKING_QUICKSTART.md).)

All commands run from the `oracle-cloud/` package root unless noted.

## What you're building

- **Brokers**: 6× DenseIO NVMe nodes in an OKE (Kubernetes) node pool,
  running Redpanda via the official Helm chart, with tiered storage to OCI
  Object Storage. Kafka API exposed on NodePort **31092**, admin API on
  **31644**.
- **Clients**: 12 VMs that run the OpenMessaging Benchmark (OMB) workers.
  OMB has a coordinator/worker design: `bin/benchmark` (the coordinator)
  runs on client-0 and drives `benchmark-worker` processes on all clients;
  workers split 50/50 into producers and consumers.
- **Monitoring**: 1 VM running Prometheus + Grafana, published over public
  HTTPS so anyone can watch dashboards during a run.

## Step 0 — Prerequisites (once)

Install locally: `terraform` (≥ 1.5), the `oci` CLI, `kubectl`, `helm`,
`jq`, `ssh`.

1. **OCI API key** at `~/.oci/config` ([DEFAULT] profile). The referenced
   key file must be `chmod 600`. Test it: `oci iam region list` should
   return JSON, not an auth error.
2. **SSH keypair** for all instances:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/redpanda_oci -N ""
   ```
3. **Compartment**: copy
   `providers/oci/terraform/compartment.auto.tfvars.template` to
   `compartment.auto.tfvars` (same directory) and set your compartment
   OCID. Using the tenancy root OCID works.
4. **Object storage credentials** (for tiered storage): copy
   `providers/oci/.env.tiered-storage.template` to `.env.tiered-storage`
   and follow the commands inside it to create the bucket and an S3-compat
   customer secret key.
5. Skim [`providers/oci/QUIRKS.md`](../providers/oci/QUIRKS.md). Ten
   minutes here saves hours later.

## Step 1 — Check capacity BEFORE deploying

On OCI, having quota does **not** mean physical hosts exist, and shapes are
availability-domain-specific:

```bash
./skills/check-cloud-capacity/check-capacity.sh --provider oci
```

You should see your service limits, a shape-offering matrix per AD, and
optionally a real launch probe. If DenseIO limits are 0, you need an Oracle
limit increase before anything else will work.

## Step 2 — Base infrastructure (clients + monitoring + network)

```bash
cd providers/oci/terraform
terraform init
terraform apply -var-file=blended-baseline.tfvars -auto-approve
terraform output          # note: client IPs (public+private), monitoring public IP
cd ../../..
```

This creates the VCN (10.0.0.0/16, ports 22/80/443/3000/6443 public, all
traffic open intra-VCN), 12 client VMs, and the monitoring VM.

**Firewall fix (required):** OCI Ubuntu images ship a default-deny host
iptables that blocks everything except SSH — Kubernetes networking, OMB
worker ports, and Prometheus scrapes will all silently fail. On **every
client and the monitoring node**:

```bash
ssh -i ~/.ssh/redpanda_oci ubuntu@<public-ip> \
  'sudo iptables -P INPUT ACCEPT && sudo iptables -F INPUT && sudo netfilter-persistent save'
```

## Step 3 — OKE cluster + broker node pool

```bash
cd providers/oci/terraform-oke
# First: set vcn_id / subnet_id / node_subnet_id in main.tf (or -var flags)
# to the OCIDs the base stack just created:
#   cd ../terraform && terraform output oke_nodes_subnet_id  (etc.)
terraform init
terraform apply -var-file=e4-nvme-16.tfvars -auto-approve   # Flex16 = validated production shape
oci ce cluster create-kubeconfig --cluster-id $(terraform output -raw cluster_id) \
  --file ~/.kube/config-oke-benchmark --region us-ashburn-1 \
  --token-version 2.0.0 --kube-endpoint PUBLIC_ENDPOINT
export KUBECONFIG=~/.kube/config-oke-benchmark
kubectl get nodes    # expect 6 nodes, STATUS Ready (takes a few minutes)
cd ../../..
```

Use `e4-nvme.tfvars` for the smaller Flex8 shape. Node OCIDs/images go
stale between deployments — if a launch 404s, see
[`providers/oci/REDEPLOY_CHECKLIST.md`](../providers/oci/REDEPLOY_CHECKLIST.md).

## Step 4 — Prepare the broker nodes (SSDs + rpk tuning)

DenseIO local NVMe SSDs arrive **raw and unformatted** — nothing is mounted
until you do it. How many drives you have depends on the shape:

| Shape (OCPUs) | Local NVMe SSDs | Usable after RAID-0 |
|---|---|---|
| VM.DenseIO.E4.Flex 8  | 1× 6.8 TB | ~6.8 TB |
| VM.DenseIO.E4.Flex 16 | 2× 6.8 TB | ~13.6 TB |
| VM.DenseIO.E4.Flex 32 | 4× 6.8 TB | ~27 TB |
| VM.DenseIO.E5.Flex    | 1 per 8 OCPUs | scales likewise |

The script below does everything in this step for you, per node:

```bash
# node IPs: kubectl get nodes -o wide  (INTERNAL-IP column; SSH user is opc)
./skills/tune-redpanda-workers/tune-workers.sh \
  --node-ips <node-ip,node-ip,...> --ssh-key ~/.ssh/redpanda_oci \
  [--disable-smt]
```

If you prefer to do it by hand (or need to debug), here is exactly what it
does — run all of this **as root on each broker node**:

### 4a. Identify the SSDs

```bash
lsblk -d -o NAME,SIZE,TYPE,MOUNTPOINTS
# NVMe devices appear as nvme0n1, nvme1n1, ... (6.2-6.8 TB each).
# Only use devices with an EMPTY MOUNTPOINTS column — the boot volume is
# a block device (sda), leave it alone.
```

### 4b. Two or more SSDs → software RAID-0 (stripe)

Redpanda wants one filesystem for its data dir, so multiple drives are
striped into a single md device. RAID-0 (not 1/5/10) because replication
is Redpanda's job (rf=3 across brokers) — local redundancy would waste
half the throughput and capacity:

```bash
dnf install -y mdadm                      # Oracle Linux 9 (OKE nodes)
mdadm --create /dev/md0 --level=0 --raid-devices=2 --force --run \
      /dev/nvme0n1 /dev/nvme1n1           # list ALL data SSDs; 2 shown
mdadm --detail --scan >> /etc/mdadm.conf  # so the array reassembles on boot
cat /proc/mdstat                          # verify: "active raid0"
```

(Single-SSD shapes: skip this and use `/dev/nvme0n1` directly below.)

### 4c. XFS + mount

XFS is the filesystem Redpanda requires for data dirs
(https://docs.redpanda.com/current/deploy/redpanda/kubernetes/k-requirements/#storage):

```bash
mkfs.xfs -f /dev/md0
mkdir -p /var/lib/redpanda-nvme
mount -o noatime /dev/md0 /var/lib/redpanda-nvme
```

### 4d. Persist the mount in fstab — BY UUID, not device name

md device names are **not stable across reboots** (md0 can come back as
md127). Always use the filesystem UUID:

```bash
UUID=$(blkid -s UUID -o value /dev/md0)
echo "UUID=$UUID /var/lib/redpanda-nvme xfs noatime,nofail 0 2" >> /etc/fstab
mount -a && findmnt /var/lib/redpanda-nvme   # verify
```

### 4e. Kernel/OS tuning (rpk autotuner)

Install the Redpanda package on the HOST (binary only — the broker itself
runs in Kubernetes) and run the autotuner:

```bash
curl -1sLf 'https://linux.pkg.redpanda.com/setup-redpanda.rpm.sh' | bash
dnf install -y redpanda
systemctl disable --now redpanda   # we only want rpk + tuners, not a broker
rpk redpanda mode production
rpk redpanda tune all
```

`tune all` applies: aio_events, ballast_file, clocksource, cpu governor,
disk IRQ affinity, disk nomerges, disk scheduler (none/noop for NVMe),
net IRQ/rps, swappiness, and transparent hugepages.

### 4f. Optional but recommended for latency: disable SMT/hyperthreading

Redpanda is thread-per-core (one busy-polling shard per core); two
hyperthread siblings sharing a physical core fight over cache and execution
units and inflate p99. On NIC/disk-bound brokers the ~20-30% aggregate CPU
that SMT adds is unused, so this is a free tail-latency win:

```bash
echo off > /sys/devices/system/cpu/smt/control   # immediate, this boot
grubby --update-kernel=ALL --args=nosmt          # persistent across reboots
nproc                                            # now = physical core count
```

If you do this, size the Redpanda Helm `resources.cpu.cores` to the
PHYSICAL core count minus ~2 for the OS/kubelet (e.g. 30 of 32).

### 4g. Kubernetes storage class (turns the mount into PersistentVolumes)

Back on your workstation:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
kubectl apply -f skills/tune-redpanda-workers/local-nvme-storageclass.yaml
kubectl get pods -n local-path-storage   # must be Running — if
# ImageInspectError: the provisioner image must be fully qualified
# (docker.io/rancher/local-path-provisioner:v0.0.30) on Oracle Linux nodes
```

The storage class (`nvme-local`) points the provisioner at
`/var/lib/redpanda-nvme`, so each broker's PVC lands on its local RAID-0.

### 4h. Verify before continuing

```bash
# on each node: mount present, array healthy, tuning applied
findmnt /var/lib/redpanda-nvme            # xfs, noatime
cat /proc/mdstat | grep raid0             # multi-SSD shapes only
rpk redpanda tune list                    # shows enabled tuners
```

**Rerun this step (script or manual) after ANY node reboot** — the fstab
mount and `nosmt` persist, but the runtime tuners (IRQ affinity, governor)
do not.

## Step 5 — Install Redpanda (initial cluster setup)

```bash
helm repo add redpanda https://charts.redpanda.com && helm repo update
kubectl create namespace redpanda
source providers/oci/.env.tiered-storage    # loads S3_ACCESS_KEY / S3_SECRET_KEY
helm install redpanda redpanda/redpanda -n redpanda \
  -f providers/oci/oke/redpanda-values-nvme-16.yaml \
  --set-string "storage.tiered.config.cloud_storage_access_key=$S3_ACCESS_KEY" \
  --set-string "storage.tiered.config.cloud_storage_secret_key=$S3_SECRET_KEY" \
  --wait --timeout 20m
```

(Credentials go on the command line, never into the values file.) Match the
values file to your node pool: `redpanda-values-nvme-16.yaml` for Flex16,
`redpanda-values-nvme.yaml` for Flex8.

**If pods stick in `Init:ImagePullBackOff`** with `toomanyrequests`: Docker
Hub is rate-limiting the nodes. Sideload the images: `docker pull` them on
the monitoring node, `docker save | gzip`, `scp` to each OKE node, then
`sudo podman load` there — one node at a time (parallel SSH gets dropped).
Details in QUIRKS.md.

**Post-install checks (all three, in order):**

```bash
kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk cluster health          # Healthy: true
kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk cluster config status   # if NEEDS-RESTART true:
kubectl rollout restart statefulset/redpanda -n redpanda                       #   restart and re-check
```

**Formation self-test (always run at cluster formation):**

```bash
kubectl exec -n redpanda redpanda-0 -c redpanda -- \
  rpk cluster self-test start --no-confirm
# wait a few minutes, then:
kubectl exec -n redpanda redpanda-0 -c redpanda -- rpk cluster self-test status
```

Disk/network numbers are your hardware baseline; the cloud tests
(Put/Get/List/Delete) prove tiered storage is wired correctly. Save the
output into your run directory later.

## Step 6 — Wire clients to the brokers

The chart's external NodePort listeners advertise pod hostnames
(`redpanda-0`, `redpanda-1`, …) that VMs cannot resolve. Map them on
**every client**:

```bash
kubectl get pods -n redpanda -o wide     # pod name → node INTERNAL-IP
# on each client, append one line per broker to /etc/hosts:
#   <nodeIP> redpanda-0
#   <nodeIP> redpanda-1   ... etc
```

Your Kafka **bootstrap list** = every node IP with port 31092:
`10.0.1.x:31092,10.0.1.y:31092,...`

Quick sanity check from any client:
`curl -s <nodeIP>:31644/v1/cluster/health_overview` returns JSON.

## Step 7 — Set up OMB (build once, distribute to all clients)

On **client-0** (the orchestrator — SSH via its public IP):

```bash
sudo apt-get update && sudo apt-get install -y openjdk-17-jdk maven git
git clone https://github.com/redpanda-data/openmessaging-benchmark /tmp/openmessaging-benchmark
cd /tmp/openmessaging-benchmark
mvn clean install -DskipTests -Dlicense.skip=true
```

The distribution tarball lands at
`package/target/openmessaging-benchmark-*-bin.tar.gz` (**not**
`benchmark-framework/target/` — a common trap).

Copy your SSH private key and the distribution script up to client-0, then
fan out to all clients and start the workers:

```bash
# from your laptop:
scp -i ~/.ssh/redpanda_oci ~/.ssh/redpanda_oci ubuntu@<client-0-public-ip>:/tmp/key
scp -i ~/.ssh/redpanda_oci providers/oci/scripts/distribute-omb.sh ubuntu@<client-0-public-ip>:/tmp/

# on client-0 (client private IPs from terraform output):
bash /tmp/distribute-omb.sh <client-priv-ip1,ip2,...> /tmp/key \
  /tmp/openmessaging-benchmark/package/target/openmessaging-benchmark-*-bin.tar.gz \
  "-Xms8G -Xmx24G"
```

The script unpacks OMB on each client and starts a `benchmark-worker`
(ports 8080/8081) with `KAFKA_OPTS=" "` — required because the tarball's
default references a JMX agent jar that doesn't exist.

Verify from client-0: every worker answers
`curl -s http://<client-ip>:8080/counters-stats` with HTTP 200.

## Step 8 — Grafana / observability (before every run, not after)

```bash
./skills/setup-observability/setup-observability.sh \
  --monitoring-host <monitoring-public-ip> \
  --broker-ips <node-ip,node-ip,...> \
  --ssh-key ~/.ssh/redpanda_oci \
  --admin-port 31644
```

What it deploys on the monitoring node: Prometheus (scraping every broker's
`/public_metrics` on 31644 plus node exporters), Grafana with the Redpanda
dashboards, and Caddy publishing Grafana at
**`https://<ip-with-dashes>.sslip.io`** with a real Let's Encrypt
certificate — reachable from any laptop, no VPN. Plain `http://ip:3000`
does **not** work from modern browsers; always use the printed HTTPS URL.

It's idempotent: if Grafana is already up it verifies the Prometheus
targets still point at the current brokers (and retargets if the cluster
was rebuilt), prints the endpoint, and exits. So run it before **every**
benchmark, unconditionally.

Dashboards it prints (bookmark these):
- **Redpanda Ops** — the one to watch during a run
- **Kafka Topic Metrics** — per-topic drilldown
- **OCI Object Storage** — tiered-storage upload health

Reading tip: broker panels show **compressed on-the-wire** bytes. With lz4
and OMB's repetitive payloads this reads ~4× lower than OMB's logical MB/s
— that's expected, not a slow benchmark.

## Step 9 — Run a benchmark

Pick a (workload, driver) pair from `providers/oci/configs/` — the catalog
with explanations is in the top-level [`README.md`](../README.md).

**Single-topic** (one replication factor):

```bash
./skills/run-omb-benchmark/run-benchmark.sh \
  --orchestrator <client-0-public-ip> \
  --clients <client-priv-ip1,ip2,...> \
  --bootstrap <nodeIP:31092,nodeIP:31092,...> \
  --workload providers/oci/configs/workloads/workload-blended-baseline.yaml \
  --driver   providers/oci/configs/drivers/redpanda-ack-all-blended.yaml \
  --run-name my-baseline-run
```

**Blended** (mixed replication factors — OMB allows one rf per
coordinator, so this runs two coordinators on disjoint worker fleets with a
synchronized start; split your 12 clients e.g. 4 for topic A / 8 for
topic B):

```bash
./skills/run-blended-benchmark/run-blended.sh \
  --orchestrator <client-0-public-ip> \
  --clients-a <4 ips> --clients-b <8 ips> \
  --bootstrap <nodeIP:31092,...> \
  --workload-a providers/oci/configs/workloads/workload-blended-prod-topicA-2gbps.yaml \
  --driver-a   providers/oci/configs/drivers/redpanda-blended-prod-topicA.yaml \
  --workload-b providers/oci/configs/workloads/workload-blended-prod-topicB-2gbps.yaml \
  --driver-b   providers/oci/configs/drivers/redpanda-blended-prod-topicB.yaml \
  --run-name blended-2gbps
```

Both scripts: verify and heal the worker fleet, launch, print progress
every few minutes (pub/cons rates per topic), and on completion collect
everything into `results/oci/<date-time>/` with a README. A standard run is
5 min warmup + 30 min measured (defined in the workload YAML). The script
prints the **measured window** timestamps — you need them in the next step.

## Step 10 — Collect metrics and write the report

```bash
./skills/collect-run-metrics/collect-metrics.sh \
  --monitoring-host <monitoring-public-ip> \
  --start <ISO8601-from-run-output> --end <ISO8601> \
  --out results/oci/<date-time>/
```

This writes `metrics.md`: **broker-side produce p50/p99 (the headline
latency — never quote OMB's client-side p99 as broker latency)**, CPU, wire
rates, tiered-storage upload counters and backoffs, under-replicated
partitions. Report generator:

```bash
python3 tools/generate-benchmark-report.py <tier> <result.json> --provider oci
```

## Step 11 — Tear down (when finished)

```bash
# 1. Delete the Redpanda namespace FIRST — its PodDisruptionBudget will
#    otherwise block the node-pool drain for a very long time:
kubectl delete namespace redpanda
# 2. Ordered destroy + billing verification:
./skills/teardown-benchmark-infra/teardown.sh
```

The script must print **ALL CLEAR** — that's zero instances, zero OKE
clusters, zero orphaned block volumes. Don't stop at `terraform destroy`
succeeding; verify the zero.

## When something breaks

1. [`providers/oci/QUIRKS.md`](../providers/oci/QUIRKS.md) — the error is
   probably already documented with its fix
2. The failure table at the bottom of
   [`skills/deploy-benchmark-k8s/RUNBOOK.md`](../skills/deploy-benchmark-k8s/RUNBOOK.md)
   — symptom → cause → fix, one line each
3. `skills/omb-dependency-fixer/` — OMB runtime errors (Netty
   `NoSuchMethodError`, JMX agent path, classpath)
4. Each deploy phase has a gate: `./skills/deploy-benchmark-k8s/verify.sh
   <phase>` — if a phase isn't ✅, fix it before continuing; later failures
   are almost always earlier phases skipped
