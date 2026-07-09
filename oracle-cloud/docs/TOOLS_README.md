# Benchmark Automation Tools

Complete automation toolkit for OpenMessaging Benchmark with Redpanda on any cloud provider.

**5 automation tools** for fully scripted benchmark deployment and execution.

---

## 🛠️ Available Tools

### 1. Cluster Formation Script
**File:** `form-redpanda-cluster.sh`

Forms a Redpanda cluster with correct unique node IDs (avoids duplicate ID issues).

**Usage:**
```bash
./form-redpanda-cluster.sh \
  --broker-ips 172.1.1.1,172.1.1.2,172.1.1.3,172.1.1.4,172.1.1.5,172.1.1.6 \
  --jumpbox 97.107.137.207 \
  --ssh-key ~/.ssh/redpanda_linode
```

**What it does:**
1. Stops all brokers and cleans data directories
2. Configures seed broker (node_id: 0) with empty seed_servers
3. Adds remaining brokers sequentially with unique node_ids
4. Waits for cluster stabilization
5. Verifies cluster health

**When to use:**
- After Terraform deploys infrastructure
- When Ansible RAID tasks fail
- To manually form cluster with known-good config
- After any cluster formation failure

---

### 2. Universal Monitoring Script
**File:** `monitor-benchmark.sh`

Monitors any tier benchmark to completion and auto-generates reports.

**Usage:**
```bash
./monitor-benchmark.sh \
  --tier 5 \
  --jumpbox 97.107.137.207 \
  --client 172.234.199.116 \
  --provider linode
```

**What it does:**
1. Checks benchmark status every 60 seconds
2. Shows progress updates every 5 minutes
3. Detects completion automatically
4. Downloads results JSON
5. Generates all 3 reports (QUICKVIEW, REPORT, ANALYSIS)
6. Displays summary

**When to use:**
- After starting any benchmark
- To automatically collect results
- To avoid manual result download/report generation

---

### 3. Universal Report Generator
**File:** `generate-benchmark-report.py`

Generates professional reports from any benchmark JSON file.

**Usage:**
```bash
python3 generate-benchmark-report.py <tier> <json_file> --provider <linode|aws>

# Examples
python3 generate-benchmark-report.py 4 results.json --provider linode
python3 generate-benchmark-report.py 6 tier6-results.json --provider aws
```

**Generates 3 reports:**
1. **TIER_X_REPORT.txt** - Simple text summary
   - Throughput vs target
   - Key latency percentiles
   - Infrastructure summary
   - Pass/fail verdict

2. **QUICKVIEW.txt** - Formatted visual report
   - Box-drawing characters
   - Detailed metrics tables
   - Performance ratings (⭐ for excellent)
   - Scaling comparisons

3. **TIER_X_ANALYSIS.md** - Detailed markdown analysis
   - Complete metrics tables
   - Infrastructure specs
   - Cost analysis
   - Recommendations
   - Conclusion

**Requirements:**
- Python 3.6+
- Tier configuration file: `tiers-{provider}.tsv`
- Benchmark results JSON file

**Documentation:** See `REPORT_GENERATOR_README.md`

---

### 4. Redpanda Installation Script
**File:** `tools/install-redpanda.sh`

Automates Redpanda installation on broker nodes (Ubuntu and RHEL/CentOS support).

**Usage:**
```bash
./tools/install-redpanda.sh \
  --broker-ips 172.1.1.1,172.1.1.2,172.1.1.3 \
  --jumpbox 97.107.137.207 \
  --ssh-key ~/.ssh/redpanda_linode \
  --version latest
```

**What it does:**
1. Detects OS on each broker (Ubuntu/Debian or RHEL/CentOS family)
2. Adds Redpanda package repository
3. Installs Redpanda package
4. Enables systemd service (but doesn't start it yet)
5. Verifies installation with rpk version check

**Options:**
- `--broker-ips`: Comma-separated list of broker IPs (required)
- `--jumpbox`: SSH jumpbox host (optional, for proxied access)
- `--ssh-key`: SSH private key path (default: ~/.ssh/id_rsa)
- `--version`: Redpanda version to install (default: latest)
- `--ssh-user`: SSH user (default: root)

**When to use:**
- After Terraform provisions broker instances
- Before cluster formation
- When Ansible playbook fails or is unavailable
- For custom/manual deployments

**Example output:**
```
=== Redpanda Installation Script ===
Broker count: 3
Version: latest
Installing Redpanda on 172.1.1.1...
  Detected OS: ubuntu
  ✓ Redpanda installed on 172.1.1.1
  Verifying installation... ✓ (rpk 24.2.4)
```

---

### 5. OMB Tools Installation Script
**File:** `tools/install-omb-tools.sh`

Automates OpenMessaging Benchmark installation on client nodes with JMX agent auto-copy.

**Usage:**
```bash
./tools/install-omb-tools.sh \
  --client-ips 172.1.1.10,172.1.1.11,172.1.1.12 \
  --jumpbox 97.107.137.207 \
  --ssh-key ~/.ssh/redpanda_linode \
  --omb-source /root/bench/openmessaging-benchmark
```

**What it does:**
1. Installs Java 11+ on all clients
2. Installs Maven (if building from source)
3. Either:
   - Builds OMB from source (if --omb-source not provided), OR
   - Copies pre-built OMB from jumpbox (if --omb-source provided)
4. **Copies JMX agent JAR** to all workers (critical for metrics)
5. Generates `workers.yaml` configuration file
6. Starts benchmark workers on all clients
7. Verifies workers are healthy

**Options:**
- `--client-ips`: Comma-separated list of client IPs (required)
- `--jumpbox`: SSH jumpbox host (optional, for proxied access)
- `--ssh-key`: SSH private key path (default: ~/.ssh/id_rsa)
- `--omb-source`: Path to existing OMB build on jumpbox (optional, faster)
- `--omb-version`: Git branch/tag to build (default: main)
- `--install-dir`: Install directory on clients (default: /opt/benchmark)

**When to use:**
- After broker cluster is formed and healthy
- Before running benchmarks
- When Ansible playbook fails or is unavailable
- To update OMB version on existing clients

**JMX Agent Auto-Copy:**
This script automatically handles the JMX agent JAR issue that causes "NoClassDefFoundError" in workers. It:
- Finds or downloads `jmx_prometheus_javaagent-*.jar`
- Copies it to all worker directories
- Ensures metrics collection works

**Example output:**
```
=== OpenMessaging Benchmark Installation ===
Client count: 3
Install directory: /opt/benchmark
Installing OMB on 172.1.1.10...
  Installing Java 11...
  ✓ Java installed
  Copying pre-built OMB from jumpbox...
  ✓ OMB copied from jumpbox
  Copying JMX agent JAR...
  ✓ JMX agent JAR copied
✓ OMB installed on 172.1.1.10

Starting benchmark workers...
Starting worker on 172.1.1.10...
  ✓ Worker started
Verifying workers...
  172.1.1.10: ✓ healthy
```

---

## 📋 Complete Workflow Example

### End-to-End Benchmark Execution

```bash
# 1. Deploy infrastructure with Terraform
cd driver-redpanda/deploy
terraform apply -var-file='../../../terraform-tier-5-linode.tfvars'

# Get outputs
BROKERS=$(terraform output -json | jq -r '.redpanda_private_ips.value | join(",")')
PRIMARY_CLIENT=$(terraform output -raw client_ssh_host)
JUMPBOX="97.107.137.207"

# 2. Install Redpanda on brokers
./tools/install-redpanda.sh \
  --broker-ips $BROKERS \
  --jumpbox $JUMPBOX \
  --ssh-key ~/.ssh/redpanda_linode

# 3. Form Redpanda cluster
./form-redpanda-cluster.sh \
  --broker-ips $BROKERS \
  --jumpbox $JUMPBOX \
  --ssh-key ~/.ssh/redpanda_linode

# 4. Install OMB tools on clients
CLIENT_IPS=$(terraform output -json | jq -r '.client_ips.value | join(",")')

./tools/install-omb-tools.sh \
  --client-ips $CLIENT_IPS \
  --jumpbox $JUMPBOX \
  --ssh-key ~/.ssh/redpanda_linode \
  --omb-source /root/bench/openmessaging-benchmark

# 5. Start monitoring (in background)
./monitor-benchmark.sh \
  --tier 5 \
  --jumpbox $JUMPBOX \
  --client $PRIMARY_CLIENT \
  --provider linode &

# 6. Start benchmark on client
ssh root@$JUMPBOX "ssh root@$PRIMARY_CLIENT \
  'cd /opt/benchmark && \
   bin/benchmark \
     --drivers driver-redpanda/redpanda.yaml \
     --workers-file workers.yaml \
     workloads/workload-tier-5.yaml > tier5.log 2>&1 &'"

# Monitoring script handles the rest automatically!
# - Detects completion
# - Downloads results
# - Generates reports

# 7. Cleanup when done
terraform destroy -var-file='../../../terraform-tier-5-linode.tfvars'
```

---

## 🔧 Troubleshooting Tools

### Check Cluster Health
```bash
# Via jumpbox
ssh root@$JUMPBOX \
  "ssh -i ~/.ssh/redpanda_linode root@$SEED_BROKER 'rpk cluster health'"

# Shows:
# - Healthy: true/false
# - All nodes list
# - Nodes down
# - Leaderless partitions
# - Under-replicated partitions
```

### Verify Worker Health
```bash
# Check all workers
for IP in $CLIENT_IPS; do
    echo -n "$IP: "
    ssh root@$IP "curl -s http://localhost:8080/stats >/dev/null && echo ✅ || echo ❌"
done
```

### Monitor Benchmark Progress
```bash
# Live log monitoring
ssh root@$CLIENT 'tail -f /opt/benchmark/tier5.log'

# Latest throughput metrics
ssh root@$CLIENT "tail -50 /opt/benchmark/tier5.log | grep 'Pub rate' | tail -5"
```

---

## 📊 Report Examples

### Using the Report Generator

```bash
# Generate all reports for Tier 5
python3 generate-benchmark-report.py 5 \
  benchmark_results_linode/tier-5/workload-tier-5-*.json \
  --provider linode

# Output:
# ✅ benchmark_results_linode/tier-5/TIER_5_REPORT.txt
# ✅ benchmark_results_linode/tier-5/QUICKVIEW.txt
# ✅ benchmark_results_linode/tier-5/TIER_5_ANALYSIS.md

# View quick summary
cat benchmark_results_linode/tier-5/QUICKVIEW.txt
```

---

## 🚀 Quick Start for New Tier

```bash
# 1. Deploy infrastructure
terraform apply -var-file='terraform-tier-X-linode.tfvars'

# Extract IPs
BROKERS=$(terraform output -json | jq -r '.redpanda_private_ips.value | join(",")')
CLIENTS=$(terraform output -json | jq -r '.client_ips.value | join(",")')
PRIMARY_CLIENT=$(terraform output -raw client_ssh_host)
JUMPBOX="97.107.137.207"

# 2. Install Redpanda on brokers
./tools/install-redpanda.sh \
  --broker-ips $BROKERS \
  --jumpbox $JUMPBOX \
  --ssh-key ~/.ssh/redpanda_linode

# 3. Form cluster
./form-redpanda-cluster.sh \
  --broker-ips $BROKERS \
  --jumpbox $JUMPBOX \
  --ssh-key ~/.ssh/redpanda_linode

# 4. Verify cluster
ssh root@$JUMPBOX "ssh -i ~/.ssh/redpanda_linode root@\$(echo $BROKERS | cut -d',' -f1) 'rpk cluster health'"

# 5. Install OMB tools on clients
./tools/install-omb-tools.sh \
  --client-ips $CLIENTS \
  --jumpbox $JUMPBOX \
  --ssh-key ~/.ssh/redpanda_linode \
  --omb-source /root/bench/openmessaging-benchmark

# 6. Copy workload and driver configs (if needed)
# scp workloads/workload-tier-X.yaml root@$JUMPBOX:/tmp/
# ssh root@$JUMPBOX "scp /tmp/workload-tier-X.yaml root@$PRIMARY_CLIENT:/opt/benchmark/workloads/"

# 7. Monitor and generate reports
./monitor-benchmark.sh \
  --tier X \
  --jumpbox $JUMPBOX \
  --client $PRIMARY_CLIENT \
  --provider linode

# Reports auto-generate when complete!
```

---

## 📚 Documentation Reference

- **LESSONS_LEARNED.md** - Critical issues and solutions
- **REPORT_GENERATOR_README.md** - Report tool details
- **TIER_6_COMPLETION_GUIDE.md** - Complete manual setup example
- **COMPLETE_SESSION_SUMMARY.md** - Session overview
- **LINODE_PERFORMANCE_SUMMARY.md** - Performance analysis

---

## 🎯 Success Criteria

Tools working correctly when:
- ✅ `form-redpanda-cluster.sh` creates healthy cluster every time
- ✅ `monitor-benchmark.sh` detects completion and downloads results
- ✅ `generate-benchmark-report.py` produces all 3 reports
- ✅ No manual intervention needed after cluster formation
- ✅ Reports match validated format (QUICKVIEW, REPORT, ANALYSIS)

**All tools tested and validated across 5 benchmark tiers.**

---

## 💡 Best Practices

1. **Use automation scripts in order:**
   - `install-redpanda.sh` → Install Redpanda on brokers
   - `form-redpanda-cluster.sh` → Form cluster with correct node IDs
   - `install-omb-tools.sh` → Install benchmark tools on clients
   - `monitor-benchmark.sh` → Monitor and collect results
2. **Prefer pre-built OMB** via `--omb-source` for faster deployment (5 min vs 15 min)
3. **Run monitoring in background** to auto-collect results
4. **Generate reports immediately** after benchmark completes
5. **Keep tier configs in version control** (terraform tfvars, workloads, drivers)
6. **Test scripts on Tier 2 first** before running expensive tiers
7. **Document provider-specific quirks** in provider directories

---

**All tools ready for production benchmark automation across any cloud provider.**
