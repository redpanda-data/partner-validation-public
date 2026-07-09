# OCI Provider Quirks

Discovered while adapting the benchmark framework to Oracle Cloud Infrastructure.

## Authentication
- Terraform + OCI CLI auth via API key in `~/.oci/config` ([DEFAULT] profile).
- Key file must have 600 permissions or the SDK refuses to use it.

## SSH user is `ubuntu`, not `root`
- OCI Ubuntu images disable root SSH (authorized_keys contains a deny stanza).
- All universal scripts (`form-redpanda-cluster.sh`, `install-redpanda.sh`,
  `install-omb-tools.sh`) SSH as root. Fixed via cloud-init in `instances.tf`:
  copies the ubuntu user's authorized_keys to /root and sets
  `PermitRootLogin prohibit-password`.

## Shapes
- Flex shapes (`VM.Standard.E4.Flex`, `E5.Flex`) take OCPUs + memory as
  parameters. 1 OCPU = 1 physical core = 2 vCPUs (SMT).
- Custom shapes for scale-up are a tfvars change only — no .tf edits.
- DenseIO (local NVMe) E4/E5 quota is 0 in this tenancy, but
  **VM.DenseIO.E6.Ax.Flex has 576 cores/AD** (AMD Turin, 1 Gbps/OCPU,
  12 GB RAM/OCPU default, one big local NVMe device).
- **DenseIO E6 only boots Oracle Linux** (8.10/9.7/10.1) — no Ubuntu images
  are shape-compatible. Consequences: default user is `opc` not `ubuntu`
  (cloud-init handles both), firewall is firewalld not raw iptables
  (prep-broker-nvme.sh disables it), and /etc/os-release ID is `ol`
  (added to install-redpanda.sh's RHEL branch → yum path).
- Local NVMe arrives unformatted — `prep-broker-nvme.sh` formats XFS and
  mounts at /var/lib/redpanda/data before cluster formation.
- Service limit: 600 E4 cores per AD (us-ashburn-1, checked 2026-07-06).

## Host-level iptables blocks everything except SSH
- OCI Ubuntu images ship `/etc/iptables/rules.v4` with a REJECT-all INPUT
  policy (only 22 allowed) — **independent of VCN security lists**. Kafka
  (9092), RPC (33145), and OMB worker (8080) traffic is silently dropped.
- Fix on every node: `iptables -P INPUT ACCEPT && iptables -F INPUT &&
  netfilter-persistent save`. Intra-VCN exposure is still governed by the
  security list.

## apt is flaky on first boot
- `apt update`/unattended-upgrades frequently hang for 10+ minutes holding
  the dpkg/lists lock, and stale image package lists cause 404s on install.
  Kill stuck `apt` processes, re-run `apt-get update`, then install.

## Operational traps (bit us at least once each)

- **OKE node-pool shape changes do NOT replace existing nodes** — updating
  `node_shape_config` applies only to future nodes. To actually swap shapes:
  scale the pool to 0, wait for deletion, scale back up (bounce).
- **Delete the redpanda namespace BEFORE destroying a node pool** — the
  chart's PodDisruptionBudget blocks node drains; a pool destroy hung 50
  minutes until the namespace was removed.
- **pgrep self-match**: any `pgrep -f <pattern>` where the pattern appears in
  the invoking shell's own command line matches itself — waits forever or
  false-positives. Always use the bracket trick: `Benchmar[k]`.
- **SSH probe failure ≠ process exit**: a monitor that treats a failed SSH as
  "process gone" fires false completions. Use a single-probe sentinel that
  prints DONE/RUNNING/EXITED remotely; empty output = blip = retry.
- **Coordinators linger after writing results** — gate completion on the
  result JSON being newer than a launch marker file, not on process exit.
- **`rpk topic analyze` at scale**: >150 partitions through NodePort times
  out regardless of --timeout. Analyze per-topic, in-cluster
  (kubectl exec on a broker), `--batches 5`. rpk install needs `unzip`.
- **Prometheus spot-rates mislead**: a `rate()` at one instant can read 0
  (e.g. tiered uploads pre-ramp). Check the cumulative counter AND a rate
  profile at several time-anchored points across the window.
- **Time-anchor all post-run queries** (`&time=<ISO>`): now-anchored rate()
  windows miss the run once it's over.
- **acks=0 requires `enable.idempotence=false`** (idempotence implies acks=all).
- **E4 DenseIO fixed shape configs**: 8/128GB/1×NVMe, 16/256/2, 32/512/4 —
  arbitrary OCPU/memory combos are rejected at launch.

## OKE specifics
- **Image pulls rate-limited**: docker.redpanda.com is backed by Docker Hub;
  fresh OKE node pools hit `toomanyrequests` immediately. Workaround: pull
  once on any non-limited host with docker, `docker save`, scp to nodes,
  `dnf install podman && podman load` — cri-o shares
  /var/lib/containers/storage so kubelet finds the image on next retry.
- **Node pools can't use the service-LB subnet** — OKE rejects it; create a
  dedicated node subnet (10.0.1.0/24 here).
- **External NodePort listeners advertise pod hostnames** (`redpanda-0`),
  unresolvable outside the cluster. Fix: map `redpanda-N` → hosting node IP
  in /etc/hosts on every client (get mapping from `kubectl get pods -o wide`;
  NodePort uses externalTrafficPolicy=Local so node N serves only broker N).
- Helm chart rejects `image.tag: latest` (semver required) — omit for default.
- OKE node SSH: user `opc`, and sshd rate-limits concurrent connections —
  serialize multi-node scp/ssh loops.
- Changing instance `user_data` (cloud-init) in terraform **replaces** the
  instance — the monitoring node was unintentionally recreated this way
  (Grafana endpoint IP changed; observability had to be redeployed).

## Networking
- VCN + subnet + internet gateway + security list all required; no defaults.
- Security list allows SSH from anywhere and all traffic intra-VCN
  (Kafka 9092, RPC 33145, Admin 9644, OMB worker 8080/9091).
- Compartment: tenancy root (no sub-compartments in this tenancy).
- Only subscribed region: us-ashburn-1.
