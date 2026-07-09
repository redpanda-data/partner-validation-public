# OCI Provider — OpenMessaging Benchmark for Redpanda

Runs the standard Redpanda OMB tier benchmarks on Oracle Cloud Infrastructure,
following the same process as the Linode validation (see
`CLOUD_PROVIDER_FRAMEWORK.md`).

## Layout

```
providers/oci/
├── terraform/           # VCN, security list, brokers, clients, monitoring node
│   └── tier-1.tfvars    # Tier 1: 3× E4.Flex (2 OCPU/8GB), 4 clients, 60 MB/s
├── configs/
│   ├── workloads/       # OMB workload YAMLs (identical to Linode runs)
│   └── drivers/         # Redpanda driver YAMLs (bootstrap.servers placeholder)
├── scripts/
│   └── distribute-omb.sh  # Push pre-built OMB tarball to clients, start workers
├── tiers.tsv            # OCI tier → shape mapping
├── QUIRKS.md            # OCI-specific gotchas (read before debugging!)
└── README.md
```

## Prerequisites

- `~/.oci/config` with an API key (600 perms on the key file)
- SSH keypair at `~/.ssh/redpanda_oci{,.pub}`
- Terraform ≥ 1.5
- `terraform/compartment.auto.tfvars` — copy from
  `terraform/compartment.auto.tfvars.template` and set your compartment OCID
- For tiered-storage runs: `.env.tiered-storage` — copy from
  `.env.tiered-storage.template` (bucket + S3-compat customer secret key)

## End-to-end run (Tier 1)

```bash
# 1. Provision (creates VCN + 3 brokers + 4 clients + 1 monitoring node)
cd providers/oci/terraform
terraform init && terraform apply -var-file=tier-1.tfvars

BROKERS_PRIV=$(terraform output -json broker_private_ips | jq -r 'join(",")')
CLIENTS_PRIV=$(terraform output -json client_private_ips | jq -r 'join(",")')
C0_PUB=$(terraform output -json client_public_ips | jq -r '.[0]')
MON_PUB=$(terraform output -raw monitoring_public_ip)

# 2. Fix host firewalls (OCI Ubuntu blocks all but SSH — see QUIRKS.md)
#    on every node: iptables -P INPUT ACCEPT && iptables -F INPUT && netfilter-persistent save

# 3. client-0 is the in-VCN orchestrator (the "jumpbox"): copy up the ssh key,
#    tools/form-redpanda-cluster.sh, tools/install-redpanda.sh, distribute-omb.sh, and the
#    tier configs, then from client-0:
bash install-redpanda.sh --broker-ips $BROKERS_PRIV --ssh-key /root/.ssh/redpanda_oci
bash form-redpanda-cluster.sh --broker-ips $BROKERS_PRIV --ssh-key /root/.ssh/redpanda_oci

# 4. Build OMB once on client-0 (mvn clean install -DskipTests -Dlicense.skip=true),
#    then distribute + start workers (also writes nothing to brokers):
bash distribute-omb.sh $CLIENTS_PRIV
#    create /opt/benchmark/workers.yaml listing http://<client>:8080 for each client

# 5. Observability (public Grafana; skipped if already running):
./skills/setup-observability/setup-observability.sh \
  --monitoring-host $MON_PUB --broker-ips $BROKERS_PRIV --ssh-key ~/.ssh/redpanda_oci

# 6. Run the benchmark from client-0:
cd /opt/benchmark && nohup bin/benchmark \
  --drivers driver-redpanda/redpanda-ack-all-tier-1.yaml \
  --workers-file workers.yaml \
  workloads/workload-tier-1.yaml > tier-1.log 2>&1 &

# 7. Collect results (JSON lands in /opt/benchmark/), generate report:
python3 tools/generate-benchmark-report.py 1 <result.json> --provider oci

# 8. Tear down:
terraform destroy -var-file=tier-1.tfvars
```

## Scaling to a custom shape

Flex shapes make this a **tfvars-only change** — copy `tier-1.tfvars` to
`custom.tfvars`, adjust `ocpus`, `memory_gbs`, `num_instances`,
`boot_volume_gbs`/`boot_volume_vpus` (and `shapes` to `VM.Standard.E5.Flex`
for newer AMD or DenseIO for local NVMe if quota allows), then repeat the
run with a matching workload YAML. Service limit at time of writing:
600 E4 cores per AD in us-ashburn-1.
