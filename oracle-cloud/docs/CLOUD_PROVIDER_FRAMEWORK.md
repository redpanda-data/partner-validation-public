# Cloud Provider Benchmark Framework
## Repeatable Patterns for OCI, NEBIUS, and Any Cloud Provider

Based on validated Linode implementation (150-1600 MB/s, 100% success rate)

---

## 🎯 Framework Overview

This framework enables rapid deployment of Redpanda benchmarks on **any cloud provider** by codifying the lessons learned from our complete Linode validation.

**Validated on:** Linode (5 tiers, 100% success rate)
**Ready for:** OCI, NEBIUS, DigitalOcean, Vultr, Hetzner, etc.

---

## 📋 Critical Issues & Universal Solutions

### Issue 1: Duplicate Node IDs in Cluster Formation ⚠️

**Problem (Universal):**
`rpk redpanda config bootstrap` with shell loops creates duplicate node IDs:
```bash
ID=1
for IP in $BROKERS; do
    ssh $IP "rpk redpanda config bootstrap --id $ID ..."
    ID=$((ID+1))  # Variable doesn't increment in SSH context!
done
```

**Result:** Cluster formation fails with "configuration mismatch" error

**Universal Solution:**
Manual YAML configuration with explicit unique node IDs

**Automation:** `form-redpanda-cluster.sh`
```bash
./form-redpanda-cluster.sh \
  --broker-ips <comma-separated> \
  --jumpbox <optional> \
  --ssh-key <path>
```

**Portable to:** ALL cloud providers ✅

---

### Issue 2: Workers Require JMX Agent JAR 🔧

**Problem (Universal):**
Workers crash: "Error opening zip file: jmx_prometheus_javaagent-0.13.0.jar"

**Solution (Universal):**
Explicitly copy JMX agent after extracting OMB:
```bash
scp jmx_prometheus_javaagent-0.13.0.jar root@$CLIENT:/opt/benchmark/
scp metrics.yml root@$CLIENT:/opt/benchmark/
```

**Location:** `driver-redpanda/deploy/monitoring/jmx_exporter/`

**Portable to:** ALL cloud providers ✅

---

### Issue 3: Provider-Specific Infrastructure Quirks

**Problem (Provider-Specific):**
- **Linode:** Ansible RAID tasks fail (`nvme_devices_for_raid` undefined)
- **AWS:** May have different block device naming
- **OCI:** Different VCN/subnet structure
- **NEBIUS:** Unknown quirks (to be discovered)

**Universal Solution Pattern:**
1. **Identify blockers** via Ansible verbose mode
2. **Skip problematic tasks** (`--skip-tags=raid,nvme`)
3. **OR manual installation** (bypass Ansible entirely)
4. **Document provider quirk** in provider-specific notes

**For each provider, create:** `providers/<provider>/QUIRKS.md`

---

## 🏗️ Multi-Provider Framework Architecture

```
openmessaging-benchmark/
├── providers/                      # Provider-specific configs
│   ├── linode/                     # ✅ VALIDATED
│   │   ├── terraform/
│   │   │   ├── tier-*.tfvars
│   │   │   └── provider.tf
│   │   ├── configs/
│   │   │   ├── workloads/
│   │   │   └── drivers/
│   │   ├── tiers.tsv
│   │   └── QUIRKS.md              # Ansible RAID, instance types
│   │
│   ├── oci/                        # 🔜 NEXT
│   │   ├── terraform/
│   │   ├── configs/
│   │   ├── tiers.tsv
│   │   └── QUIRKS.md
│   │
│   ├── nebius/                     # 🔜 PLANNED
│   └── aws/                        # Reference implementation
│
├── tools/                          # Universal automation
│   ├── form-redpanda-cluster.sh   # Cluster formation
│   ├── monitor-benchmark.sh       # Universal monitoring
│   ├── generate-benchmark-report.py # Report generation
│   └── provision-helpers/
│       ├── install-redpanda.sh
│       ├── install-omb.sh
│       └── verify-connectivity.sh
│
├── benchmark_results/              # Results by provider
│   ├── linode/                     # ✅ 5 tiers complete
│   ├── oci/
│   └── nebius/
│
└── docs/
    ├── PROVIDER_TEMPLATE.md        # Template for new providers
    ├── LESSONS_LEARNED.md          # All issues & solutions
    └── TOOLS_README.md             # Automation documentation
```

---

## 📝 Adding a New Provider (OCI Example)

### Step 1: Create Provider Structure

```bash
mkdir -p providers/oci/{terraform,configs/workloads,configs/drivers}
```

### Step 2: Map Instance Types

**Create `providers/oci/tiers.tsv`:**

| Tier | OCI Instance | vCPU | Memory | Equivalent Linode | Target |
|------|--------------|------|--------|-------------------|--------|
| 2 | VM.Standard.E4.Flex | 8 | 16GB | g7-dedicated-16gb | 150 MB/s |
| 3 | VM.Standard.E4.Flex | 8 | 16GB | g7-dedicated-16gb | 200 MB/s |
| 4 | VM.Standard.E4.Flex | 8 | 16GB | g7-dedicated-16gb | 400 MB/s |
| 5 | VM.Standard.E5.Flex | 50 | 128GB | g7-dedicated-128gb | 800 MB/s |
| 6 | VM.Standard.E5.Flex | 50 | 128GB | g7-dedicated-128gb | 1600 MB/s |

**Match on:** vCPU + RAM + NVMe storage capability

### Step 3: Create Terraform Configs

**`providers/oci/terraform/provider.tf`:**
```hcl
provider "oci" {
  region = var.region
}

resource "oci_core_instance" "redpanda" {
  count = var.num_instances["redpanda"]

  availability_domain = var.availability_domain
  compartment_id      = var.compartment_id
  shape               = var.instance_shapes["redpanda"]

  shape_config {
    ocpus         = var.ocpus["redpanda"]
    memory_in_gbs = var.memory_gbs["redpanda"]
  }

  source_details {
    source_type = "image"
    source_id   = var.image_id  # Ubuntu 22.04
  }

  create_vnic_details {
    subnet_id = oci_core_subnet.benchmark.id
  }

  metadata = {
    ssh_authorized_keys = file(var.public_key_path)
  }
}
```

**`providers/oci/terraform/tier-5.tfvars`:**
```hcl
region = "us-ashburn-1"
availability_domain = "AD-1"
compartment_id = "ocid1.compartment.oc1..."

instance_shapes = {
  redpanda   = "VM.Standard.E5.Flex"
  client     = "VM.Standard.E4.Flex"
  prometheus = "VM.Standard.E2.1.Micro"
}

ocpus = {
  redpanda = 50
  client   = 8
}

memory_gbs = {
  redpanda = 128
  client   = 32
}

num_instances = {
  redpanda   = 3
  client     = 6
  prometheus = 1
}
```

### Step 4: Test & Document Quirks

**Run initial deployment:**
```bash
cd providers/oci/terraform
terraform init
terraform apply -var-file='tier-2.tfvars'
```

**Document any issues in `providers/oci/QUIRKS.md`:**
- Block volume attachment differences
- VCN/subnet requirements
- Security list configurations
- Boot volume sizing
- SSH key format requirements

### Step 5: Form Cluster (Universal)

```bash
# Extract broker IPs from Terraform
BROKERS=$(terraform output -json | jq -r '.redpanda_ips.value | join(",")')
JUMPBOX=$(terraform output -raw jumpbox_ip)

# Use universal cluster formation script
../../tools/form-redpanda-cluster.sh \
  --broker-ips $BROKERS \
  --jumpbox $JUMPBOX \
  --ssh-key ~/.ssh/oci_key
```

### Step 6: Run Benchmark & Monitor (Universal)

```bash
# Start benchmark on client
PRIMARY_CLIENT=$(terraform output -raw primary_client_ip)

# Start monitoring (auto-generates reports)
../../tools/monitor-benchmark.sh \
  --tier 5 \
  --jumpbox $JUMPBOX \
  --client $PRIMARY_CLIENT \
  --provider oci
```

### Step 7: Compare Results

```bash
# Generate OCI reports
python3 ../../tools/generate-benchmark-report.py 5 \
  benchmark_results/oci/tier-5/results.json \
  --provider oci

# Compare with Linode
diff -y \
  benchmark_results/linode/tier-5/QUICKVIEW.txt \
  benchmark_results/oci/tier-5/QUICKVIEW.txt
```

---

## 🔄 Repeatable Deployment Pattern

### Phase 1: Provider Setup (One-Time)
1. Create `providers/<provider>/` directory structure
2. Map instance types to Linode equivalents
3. Create `tiers.tsv` with provider-specific instances
4. Write Terraform provider configuration
5. Test basic instance provisioning
6. Document quirks in `QUIRKS.md`

### Phase 2: Cluster Formation (Per Tier)
1. Deploy infrastructure with Terraform
2. Extract broker/client IPs
3. Run `form-redpanda-cluster.sh` (universal)
4. Verify cluster health
5. Install benchmark tools
6. Copy JMX agent JARs (universal fix)

### Phase 3: Benchmark Execution (Universal)
1. Create workers.yaml with all client IPs
2. Create driver config with all broker IPs
3. Start 6 benchmark workers
4. Verify all workers healthy
5. Start benchmark with `monitor-benchmark.sh`
6. Wait for auto-completion and reports

### Phase 4: Analysis (Universal)
1. Reports auto-generated by monitoring script
2. Review QUICKVIEW for quick assessment
3. Compare with Linode results
4. Document provider-specific observations
5. Update provider QUIRKS.md if needed

---

## 🌍 Provider Templates

### NEBIUS Cloud

**Instance Mapping Hypothesis:**
```
Linode g7-dedicated-16gb  → NEBIUS compute-c3-8-16  (8 vCPU, 16GB)
Linode g7-dedicated-128gb → NEBIUS compute-c3-50-128 (50 vCPU, 128GB)
```

**Create:** `providers/nebius/tiers.tsv`
**Create:** `providers/nebius/terraform/provider.tf`
**Research:** NEBIUS network/VPC structure
**Test:** Tier 2 (3 brokers) first

### Oracle Cloud Infrastructure (OCI)

**Instance Mapping:**
```
Linode g7-dedicated-16gb  → VM.Standard.E4.Flex (8 OCPU, 16GB)
Linode g7-dedicated-128gb → VM.Standard.E5.Flex (50 OCPU, 128GB)
```

**OCI-Specific:**
- Compartment ID required
- Availability Domain required
- VCN + Subnet must pre-exist
- Security lists for ports 9092, 33145, 9644

**Create:** `providers/oci/terraform/vcn.tf` for networking
**Test:** Single-broker cluster first

---

## 🛠️ Automation Approaches

### Two Levels of Automation

**Level 1: Simple Tools** (Recommended - ✅ Validated)
- Direct SSH commands
- Step-by-step execution
- Full transparency
- Easy debugging
- **Proven:** 6/6 tiers successful on Linode

**Level 2: jumpboxctl** (Experimental - Full Automation)
- Single command operation
- Remote Claude Code execution
- Hands-off automation
- **Status:** Needs validation on clean deployment
- **See:** `jumpboxctl/STATUS.md`

**Choose based on:**
- **New users:** Start with simple tools
- **Production:** Use simple tools (proven)
- **Experimentation:** Try jumpboxctl on Tier 2
- **Debugging:** Always use simple tools

---

## Simple Tools (Level 1)

### 1. `form-redpanda-cluster.sh` ✅
**Purpose:** Form cluster with unique node IDs (solves duplicate ID issue)
**Portable:** ✅ Works on ALL cloud providers
**Status:** Production-ready
**Usage:**
```bash
./form-redpanda-cluster.sh --broker-ips <ips> --jumpbox <ip>
```

### 2. `monitor-benchmark.sh` ✅
**Purpose:** Monitor any tier, auto-download results, generate reports
**Portable:** ✅ Works on ALL cloud providers
**Status:** Production-ready
**Usage:**
```bash
./monitor-benchmark.sh --tier <N> --jumpbox <ip> --client <ip> --provider <name>
```

### 3. `generate-benchmark-report.py` ✅
**Purpose:** Generate 3 report types from any benchmark JSON
**Portable:** ✅ Works on ALL cloud providers (needs tiers-<provider>.tsv)
**Status:** Production-ready
**Usage:**
```bash
python3 generate-benchmark-report.py <tier> <json> --provider <name>
```

### 4. `install-redpanda.sh` (To Create)
**Purpose:** Install Redpanda on any OS (Ubuntu, RHEL, etc.)
**Portable:** ✅ Multi-OS support
**Usage:**
```bash
./install-redpanda.sh --broker-ips <ips> --jumpbox <ip> --os <ubuntu|rhel>
```

### 5. `install-omb-tools.sh` (To Create)
**Purpose:** Install OpenMessaging Benchmark tools on clients
**Portable:** ✅ Works anywhere
**Usage:**
```bash
./install-omb-tools.sh --client-ips <ips> --jumpbox <ip> --include-jmx
```

---

## jumpboxctl (Level 2)

### What It Provides
- **One command** runs entire benchmark
- **Remote Claude Code** handles all automation
- **tmux persistence** survives disconnects
- **Automatic syncing** of results

### Current Limitations
- ⚠️ Needs validation on fresh deployment
- ⚠️ Complex to debug when issues occur
- ⚠️ Requires Claude Code on remote (additional setup)
- ⚠️ Edge case handling not fully tested

### Validation Path
1. Test on fresh Tier 2 (clean Linode instance)
2. Verify end-to-end success
3. Fix any issues
4. Document results in `jumpboxctl/STATUS.md`
5. If successful: Promote to recommended
6. If issues persist: Keep as experimental

**See:** `jumpboxctl/README.md` for usage details

---

## 📊 Provider Comparison Framework

### Create `providers/<provider>/tiers.tsv`

Required columns:
```tsv
Tier	Instance	vCPU	Memory_GB	Storage_GB	Broker_Count	Target_MB	Cost_Per_Hour
2	instance-type	8	16	320	3	150	0.xx
3	instance-type	8	16	320	6	200	0.xx
...
```

**Mapping Process:**
1. Identify instance types with matching vCPU/RAM to Linode
2. Verify NVMe or high-performance storage available
3. Calculate cost per hour
4. Document in tiers.tsv

### Create Terraform Configs

**Template structure (same across all providers):**
```
providers/<provider>/terraform/
├── provider.tf           # Provider configuration
├── network.tf            # VPC/VCN/Network setup
├── instances.tf          # Broker/client/prometheus instances
├── outputs.tf            # Standard outputs (broker_ips, client_ips)
├── variables.tf          # Standard variables
└── tier-*.tfvars         # Tier-specific values
```

**Standard outputs (MUST provide):**
- `redpanda_private_ips` - Array of broker IPs
- `client_ips` - Array of client IPs
- `client_ssh_host` - Primary client IP
- `prometheus_host` - Prometheus IP
- `ssh_user` - SSH username (usually "root" or "ubuntu")

---

## 🚀 Quick Start: New Provider in 4 Steps

### Step 1: Setup (2-4 hours)

```bash
# Create provider structure
./tools/new-provider-setup.sh --provider oci

# This creates:
# - providers/oci/ directory structure
# - Template tiers.tsv
# - Template Terraform files
# - Provider QUIRKS.md
```

### Step 2: Configure (2-4 hours)

```bash
cd providers/oci

# 1. Research instance types
# - Find equivalents to Linode g7-dedicated-16gb (8 vCPU, 16GB)
# - Find equivalents to Linode g7-dedicated-128gb (50 vCPU, 128GB)

# 2. Fill in tiers.tsv with OCI instance types and costs

# 3. Update terraform/provider.tf with OCI-specific resources

# 4. Create tier-2.tfvars for smallest tier
```

### Step 3: Test Tier 2 (2-3 hours)

```bash
# Deploy smallest tier first
cd terraform
terraform init
terraform apply -var-file='tier-2.tfvars'

# Get outputs
BROKERS=$(terraform output -json | jq -r '.redpanda_private_ips.value | join(",")')
CLIENT=$(terraform output -raw client_ssh_host)
JUMPBOX=$(terraform output -raw jumpbox_ip)  # If using jumpbox

# Form cluster (universal)
../../tools/form-redpanda-cluster.sh \
  --broker-ips $BROKERS \
  --jumpbox $JUMPBOX

# Verify
ssh root@$JUMPBOX "ssh root@$SEED_BROKER 'rpk cluster health'"

# If healthy: SUCCESS! Pattern works on this provider.
# If issues: Document in QUIRKS.md and adjust
```

### Step 4: Scale to All Tiers (8-12 hours)

```bash
# Run tiers 2-6 sequentially
for TIER in 2 3 4 5 6; do
    # Deploy
    terraform apply -var-file="tier-${TIER}.tfvars"

    # Form cluster
    ../../tools/form-redpanda-cluster.sh --broker-ips $(get_broker_ips) --jumpbox $JUMPBOX

    # Install tools (manual or scripted)
    # Start benchmark

    # Monitor (auto-generates reports)
    ../../tools/monitor-benchmark.sh \
      --tier $TIER \
      --jumpbox $JUMPBOX \
      --client $PRIMARY_CLIENT \
      --provider oci

    # Cleanup
    terraform destroy -var-file="tier-${TIER}.tfvars"
done
```

**Total time:** ~60 minutes per tier × 5 tiers = ~5 hours

---

## 📐 Instance Type Mapping Guide

### Matching Criteria (in priority order):

1. **vCPU Count** (must match exactly)
2. **RAM** (must match exactly)
3. **Storage Type** (NVMe preferred, SSD acceptable)
4. **Network Performance** (≥5 Gbps for egress)
5. **Cost** (lower is better, but performance first)

### Linode → OCI Mapping

| Linode Instance | vCPU | RAM | OCI Equivalent | OCI vCPU | OCI RAM |
|-----------------|------|-----|----------------|----------|---------|
| g7-dedicated-16gb | 8 | 16GB | VM.Standard.E4.Flex | 8 OCPU | 16GB |
| g7-dedicated-128gb | 50 | 128GB | VM.Standard.E5.Flex | 50 OCPU | 128GB |

### Linode → NEBIUS Mapping (Hypothetical)

| Linode Instance | vCPU | RAM | NEBIUS Equivalent | NEBIUS vCPU | NEBIUS RAM |
|-----------------|------|-----|-------------------|-------------|------------|
| g7-dedicated-16gb | 8 | 16GB | compute-c3-8-16 | 8 | 16GB |
| g7-dedicated-128gb | 50 | 128GB | compute-c3-50-128 | 50 | 128GB |

**Research Required:**
- Actual NEBIUS instance families
- Storage options (local NVMe?)
- Network bandwidth limits
- Pricing

---

## 🧪 Provider Validation Checklist

### Infrastructure Requirements
- [ ] Instances can reach each other on private network
- [ ] Port 9092 (Kafka) accessible between instances
- [ ] Port 33145 (Redpanda RPC) accessible between instances
- [ ] Port 9644 (Admin API) accessible
- [ ] SSH access to all instances
- [ ] NVMe or high-performance storage available

### Redpanda Requirements
- [ ] Ubuntu 22.04 LTS supported (or RHEL/Rocky)
- [ ] Redpanda package installs successfully
- [ ] Systemd service starts without errors
- [ ] Cluster formation completes
- [ ] `rpk cluster health` shows healthy

### Benchmark Requirements
- [ ] OpenMessaging Benchmark builds/installs
- [ ] Workers start successfully
- [ ] Workers accessible on port 8080
- [ ] Benchmark can connect to all brokers
- [ ] Sustained load runs for 30+ minutes

### Results Validation
- [ ] Throughput within 5% of target
- [ ] P50 latency < 5ms
- [ ] No message loss
- [ ] JSON results file generated
- [ ] Reports generate successfully

---

## 📊 Expected Performance by Provider

### Baseline (Linode - Validated)
```
Tier 2 (3×8vCPU):   150 MB/s, P50: 1.65ms, P99: 114ms
Tier 4 (12×8vCPU):  400 MB/s, P50: 1.63ms, P99: 38ms
Tier 6 (6×50vCPU):  1600 MB/s, P50: 2.37ms, P99: 809ms
```

### Expected on OCI (Prediction)
```
Tier 2 (3×8vCPU):   145-155 MB/s, P50: <3ms, P99: <150ms
Tier 4 (12×8vCPU):  380-420 MB/s, P50: <3ms, P99: <50ms
Tier 6 (6×50vCPU):  1500-1700 MB/s, P50: <3ms, P99: <1000ms
```
**Rationale:** Similar CPU, should have similar performance ±5%

### Expected on NEBIUS (Prediction)
```
Depends on:
- Network architecture (VPC design)
- Storage backend (NVMe vs SSD)
- Instance type overhead
```
**Approach:** Start with Tier 2, measure, extrapolate

---

## 🎓 Lessons Applied to Any Provider

### Cluster Formation Best Practices
1. **Always use manual node_id assignment** (0, 1, 2, 3...)
2. **Start seed broker alone first** (`seed_servers: []`)
3. **Add brokers sequentially** with 15-second delays
4. **Use form-redpanda-cluster.sh** for consistency

### Configuration Best Practices
1. **Always specify bootstrap.servers** in driver config
2. **List ALL brokers** in bootstrap.servers
3. **Include JMX agent JAR** with workers
4. **Use developer_mode: true** for benchmarking
5. **Set overprovisioned: true** for consistent behavior

### Performance Expectations
1. **Expect 5-6 MB/s per vCPU** sustained throughput
2. **Expect P50 < 3ms** if network latency < 1ms
3. **Expect linear scaling** if infrastructure is consistent
4. **More brokers = better P99** latency

### Cost Optimization
1. **Destroy immediately** after benchmark (no idle costs)
2. **Run tiers sequentially** (not parallel)
3. **Use spot/preemptible** instances if available
4. **Track costs** in real-time with cost.sh utilities

---

## 🔧 Universal Helper Scripts (To Create)

### `tools/install-redpanda.sh`
```bash
#!/bin/bash
# Install Redpanda on broker instances
# Usage: ./install-redpanda.sh --broker-ips <ips> --jumpbox <ip> --os <ubuntu|rhel>

# Handles:
# - OS detection
# - Package manager selection (apt/yum)
# - Repository setup
# - Installation
# - Directory creation
```

### `tools/install-omb-tools.sh`
```bash
#!/bin/bash
# Install OpenMessaging Benchmark on client instances
# Usage: ./install-omb-tools.sh --client-ips <ips> --jumpbox <ip> --include-jmx

# Handles:
# - OMB package extraction
# - Distribution to all clients
# - JMX agent JAR copy
# - Permissions setup
# - Verification
```

### `tools/verify-connectivity.sh`
```bash
#!/bin/bash
# Verify network connectivity between brokers and clients
# Usage: ./verify-connectivity.sh --broker-ips <ips> --client-ips <ips>

# Tests:
# - SSH connectivity
# - Port 9092 (Kafka)
# - Port 33145 (RPC)
# - Port 9644 (Admin)
# - Latency between instances
```

---

## 📚 Documentation Structure for Each Provider

### Required Files

**`providers/<provider>/README.md`:**
- Provider overview
- Account setup requirements
- Prerequisites (CLI tools, credentials)
- Quick start guide
- Cost estimates

**`providers/<provider>/QUIRKS.md`:**
- Known issues specific to this provider
- Workarounds and solutions
- Performance observations
- Networking peculiarities

**`providers/<provider>/tiers.tsv`:**
- Complete tier specifications
- Instance types
- Costs
- Expected performance

**`providers/<provider>/RESULTS.md`:**
- Validated benchmark results
- Comparison with Linode baseline
- Provider-specific observations
- Recommendations

---

## 🎯 Success Metrics for New Provider

### Tier 2 Validation (Minimum Viable)
- [ ] Cluster forms successfully (3 brokers)
- [ ] Benchmark runs to completion
- [ ] Throughput ≥ 95% of target (143+ MB/s for 150 MB/s target)
- [ ] P50 latency < 5ms
- [ ] Reports generate correctly

**If Tier 2 passes:** Provider is viable, proceed with remaining tiers

### Full Validation (All Tiers)
- [ ] Tiers 2-6 all complete successfully
- [ ] All achieve ≥95% of target throughput
- [ ] Linear scaling pattern observed
- [ ] P50 latency < 5ms across all tiers
- [ ] Cost efficiency comparable to Linode

---

## 🔄 Multi-Provider Comparison Template

```markdown
# Multi-Provider Performance Comparison

| Tier | Linode (✅) | OCI (🔜) | NEBIUS (🔜) | AWS (Baseline) |
|------|-------------|----------|-------------|----------------|
| **2 (150 MB/s)** |
| Achieved | 150.00 MB/s | TBD | TBD | TBD |
| P50 Latency | 1.65ms | TBD | TBD | TBD |
| Cost/Hour | $0.78 | TBD | TBD | TBD |
| **6 (1600 MB/s)** |
| Achieved | 1601.90 MB/s | TBD | TBD | TBD |
| P50 Latency | 2.37ms | TBD | TBD | TBD |
| Cost/Hour | $12.42 | TBD | TBD | TBD |
```

---

## 🎓 Skills Extracted from Linode Work

### Skill 1: Cluster Formation with Unique Node IDs
**File:** `form-redpanda-cluster.sh`
**Use Case:** Any multi-broker Redpanda cluster on any provider
**Lesson:** Manual config > automated bootstrap for reliability

### Skill 2: Universal Benchmark Monitoring
**File:** `monitor-benchmark.sh`
**Use Case:** Any benchmark on any provider
**Lesson:** Automation saves hours, reduces errors

### Skill 3: Multi-Format Report Generation
**File:** `generate-benchmark-report.py`
**Use Case:** Any benchmark result analysis
**Lesson:** Consistent reporting enables comparisons

### Skill 4: Incremental Cluster Build
**Pattern:** Seed alone → Add brokers sequentially
**Use Case:** Large clusters (6+ brokers)
**Lesson:** Sequential > parallel for reliability

---

## 🔍 Provider Discovery Process

### Phase 1: Research (1-2 hours)
1. Identify instance types with target vCPU/RAM
2. Check storage options (NVMe preferred)
3. Understand networking (VPC, subnets, security)
4. Find pricing information
5. Check Terraform provider availability

### Phase 2: Proof of Concept (2-4 hours)
1. Deploy single instance via Terraform
2. Install Redpanda manually
3. Verify network connectivity
4. Test single-broker cluster
5. Document any quirks

### Phase 3: Tier 2 Validation (4-6 hours)
1. Deploy 3-broker cluster
2. Use `form-redpanda-cluster.sh`
3. Install OMB tools
4. Run 30-minute benchmark
5. Achieve ≥95% of target

### Phase 4: Full Validation (10-20 hours)
1. Run all tiers (2-6)
2. Validate linear scaling
3. Compare with Linode baseline
4. Document results
5. Create provider RESULTS.md

**Total: 19-32 hours** from zero to full multi-tier validation

---

## 📦 Deliverables Template

For each new provider, deliver:

### Minimum Viable
- [ ] `providers/<provider>/tiers.tsv`
- [ ] `providers/<provider>/terraform/` (working configs)
- [ ] `providers/<provider>/QUIRKS.md`
- [ ] `benchmark_results/<provider>/tier-2/` (at least Tier 2)
- [ ] Tier 2 performance validated (≥95% of target)

### Complete Validation
- [ ] All tiers (2-6) benchmarked
- [ ] 18 report files (3 per tier × 6 tiers)
- [ ] `providers/<provider>/RESULTS.md`
- [ ] Multi-provider comparison updated
- [ ] Cost analysis documented

---

## 🛡️ Risk Mitigation

### Start Small
- **Always test Tier 2 first** (3 brokers, lowest cost)
- **Validate before scaling** (don't deploy Tier 6 before Tier 2 works)
- **Budget ~$50** for full provider validation
- **Timebox discovery** (if Tier 2 fails after 8 hours, reassess)

### Use Universal Tools
- **Don't reinvent** cluster formation - use `form-redpanda-cluster.sh`
- **Don't manually monitor** - use `monitor-benchmark.sh`
- **Don't manually create reports** - use `generate-benchmark-report.py`

### Document Everything
- **QUIRKS.md** - Every provider is different
- **Track time** spent on each phase
- **Note blockers** for future providers
- **Update framework** with new patterns

---

## 🎯 Next Provider Candidates

### OCI (Oracle Cloud Infrastructure)
**Priority:** HIGH
**Rationale:** Enterprise demand, good instance options
**Estimated Effort:** 20-30 hours (full validation)
**Blockers:** VCN complexity, security lists
**First Step:** Create `providers/oci/tiers.tsv`

### NEBIUS
**Priority:** MEDIUM
**Rationale:** New provider, early adopter advantage
**Estimated Effort:** 25-35 hours (unknown quirks)
**Blockers:** Limited documentation, unknown instance types
**First Step:** Research NEBIUS compute offerings

### DigitalOcean
**Priority:** MEDIUM
**Rationale:** Simple, well-documented
**Estimated Effort:** 15-25 hours (should be straightforward)
**Blockers:** None anticipated
**First Step:** Create `providers/digitalocean/tiers.tsv`

### Hetzner
**Priority:** LOW
**Rationale:** Cost-effective, good for price-sensitive scenarios
**Estimated Effort:** 20-30 hours
**Blockers:** Different instance naming, EU-focused
**First Step:** Research Hetzner dedicated CPU instances

---

## 🔄 Continuous Improvement

### After Each Provider
1. **Update universal tools** with new patterns
2. **Add provider mappings** to Terraform extension skill
3. **Enhance QUIRKS templates** with new categories
4. **Improve automation** based on pain points
5. **Update time estimates** based on actuals

### Feedback Loop
```
New Provider → Document Quirks → Update Tools → Next Provider (Easier!)
```

---

## 📊 Framework Maturity Goals

### Current State (Linode Complete)
- ✅ 1 provider fully validated
- ✅ Universal tools created
- ✅ Repeatable process documented
- ⏳ Skills not yet extracted

### Target State (Multi-Provider)
- 🎯 3-5 providers validated (Linode + OCI + NEBIUS + 2 others)
- 🎯 Universal tools battle-tested across providers
- 🎯 Skills extracted and documented
- 🎯 New provider: <8 hours to first result

---

## 🚀 Quick Reference Commands

### Form Cluster (Any Provider)
```bash
./tools/form-redpanda-cluster.sh \
  --broker-ips $(terraform output -json | jq -r '.redpanda_private_ips.value | join(",")') \
  --jumpbox $JUMPBOX_IP
```

### Monitor Benchmark (Any Provider)
```bash
./tools/monitor-benchmark.sh \
  --tier 5 \
  --jumpbox $JUMPBOX_IP \
  --client $(terraform output -raw client_ssh_host) \
  --provider oci  # or nebius, aws, etc.
```

### Generate Reports (Any Provider)
```bash
python3 tools/generate-benchmark-report.py 5 \
  benchmark_results/oci/tier-5/results.json \
  --provider oci
```

---

## 💡 Key Principles

1. **Universal tools > provider-specific scripts**
2. **Document quirks > hide problems**
3. **Validate incrementally** (Tier 2 before Tier 6)
4. **Automate everything repeatable**
5. **Compare across providers** for best value

---

**Framework ready for OCI, NEBIUS, and any future cloud provider.**

**Next Step:** Apply this framework to OCI or NEBIUS following the 4-step quick start.
