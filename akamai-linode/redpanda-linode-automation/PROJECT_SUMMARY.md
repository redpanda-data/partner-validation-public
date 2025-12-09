# Redpanda on Linode - Automated Deployment Project

## Overview

This project provides **fully automated deployment and validation** of Redpanda on Linode Kubernetes Engine (LKE) with comprehensive testing for Akamai ISV Catalyst and QCP program submissions.

## What It Does

✅ **Provisions infrastructure** via Terraform
✅ **Deploys Redpanda** via Helm with tiered storage
✅ **Runs comprehensive validations** (health, functionality, performance)
✅ **Executes Redpanda self-tests** (disk, network, cloud storage)
✅ **Generates detailed reports** with metrics and logs

**Total automation time: ~40 minutes**

## Project Structure

```
redpanda-linode-automation/
│
├── README.md                    # Comprehensive project documentation
├── QUICKSTART.md                # Step-by-step execution guide
├── PROJECT_SUMMARY.md           # This file
│
├── config.example.sh            # Template for configuration
├── config.sh                    # Your configuration (with Linode API token)
│
├── deploy-and-validate.sh       # ⭐ MAIN SCRIPT - Run this!
├── cleanup.sh                   # Destroy all resources
│
├── terraform/
│   ├── main.tf                  # LKE cluster + Object Storage resources
│   ├── variables.tf             # Configurable parameters
│   ├── outputs.tf               # Cluster connection info
│   └── (generated files)        # .terraform/, tfstate, etc.
│
├── scripts/
│   ├── install-redpanda.sh      # Helm deployment with tiered storage
│   ├── validate-cluster.sh      # Health checks (nodes, pods, PVCs)
│   ├── test-tiered-storage.sh   # S3 operations validation
│   ├── run-self-tests.sh        # rpk cluster self-test execution
│   └── benchmark.sh             # Basic performance tests
│
└── reports/                     # Generated after deployment
    ├── validation-report-*.txt  # Human-readable summary
    ├── validation-full-*.log    # Complete execution log
    └── metrics-*.json           # Structured metrics data
```

## Quick Start (TL;DR)

```bash
# 1. Install prerequisites
brew install terraform kubectl helm jq  # macOS
# (or equivalent for Linux)

# 2. Run deployment (your API token is already configured)
./deploy-and-validate.sh

# 3. Wait ~40 minutes, then view reports
cat reports/validation-report-*.txt

# 4. Cleanup when done
./cleanup.sh
```

## What Gets Validated

### Infrastructure
- ✓ LKE cluster (3-node Dedicated 16GB)
- ✓ Kubernetes API accessible
- ✓ All nodes Ready
- ✓ Networking functional

### Redpanda Deployment
- ✓ 3 broker pods Running
- ✓ PersistentVolumes Bound (Linode Volumes, NVMe-backed)
- ✓ LoadBalancer service with external IP
- ✓ Cluster health good

### Tiered Storage (Linode Object Storage)
- ✓ Object Storage bucket configured
- ✓ S3 credentials secret created
- ✓ Data uploads to Object Storage
- ✓ Data downloads from tiered storage
- ✓ S3 operations validated (PUT, GET, LIST, DELETE)

### Redpanda Self-Tests (`rpk cluster self-test`)
Comprehensive tests of all Redpanda subsystems:

**Disk Tests:**
- Sequential write/read performance
- Random write/read performance
- **Expected**: >16K IOPS (target: 25K+)

**Network Tests:**
- Inter-broker latency
- Inter-broker throughput
- **Expected**: <2ms latency, >1 Gbps

**Cloud Storage Tests:**
- PUT operations (upload segments)
- GET operations (download segments)
- LIST operations (enumerate objects)
- HEAD operations (get metadata)
- DELETE operations (single + batch)
- **Expected**: 0 timeouts, all operations succeed

### Performance Benchmarks
- Producer throughput (msg/sec)
- Consumer throughput (msg/sec)
- End-to-end latency (p50, p95, p99)

## Key Features

### 1. Zero Manual Steps
Everything is automated:
- Infrastructure provisioning
- Software deployment
- Validation execution
- Report generation

### 2. Comprehensive Testing
Tests every aspect of Redpanda on Linode:
- Infrastructure health
- Redpanda functionality
- Tiered storage integration
- Performance characteristics

### 3. Detailed Reporting
Generates three types of reports:
- **Summary** (human-readable pass/fail)
- **Full log** (complete execution trace)
- **Metrics JSON** (structured data for analysis)

### 4. Idempotent & Reproducible
- Run multiple times safely
- Consistent results
- Version-controlled configuration

## Configuration

Current settings in `config.sh`:

| Setting | Value | Notes |
|---------|-------|-------|
| **API Token** | Configured | Your Linode PAT |
| **Cluster Name** | redpanda-validation | Unique identifier |
| **Region** | us-east (Newark) | Closest to you |
| **Node Type** | g6-dedicated-8 | Dedicated 16GB (8 vCPUs, 16GB RAM) |
| **Node Count** | 3 | Minimum for HA |
| **Redpanda Brokers** | 3 | Matches node count |
| **Volume Size** | 50GB per broker | Local NVMe storage |
| **Object Storage** | Enabled | Tiered storage for cost efficiency |

## Cost Breakdown

**Hourly costs:**
- 3x Dedicated 16GB nodes: $0.81/hr
- 3x 50GB volumes: $0.02/hr
- Object Storage: ~$0.01/hr
- **Total: ~$0.84/hr**

**Test run (2 hours): ~$1.68**

⚠️ **Important**: Run `./cleanup.sh` when done to avoid ongoing charges!

## Validation Results Expected

Based on Linode's infrastructure and prior testing:

| Metric | Expected Result | Validation Method |
|--------|----------------|-------------------|
| **LKE Cluster** | 3 nodes Ready | `kubectl get nodes` |
| **Redpanda Pods** | 3 Running | `kubectl get pods` |
| **Disk IOPS** | 20K-30K IOPS | `rpk cluster self-test` |
| **Network Latency** | <1ms inter-broker | `rpk cluster self-test` |
| **Cloud Storage Ops** | 0 timeouts | `rpk cluster self-test` |
| **Producer Throughput** | >50K msg/sec | Basic benchmark |
| **Consumer Throughput** | >50K msg/sec | Basic benchmark |
| **End-to-End Latency** | <100ms p99 | Basic benchmark |

## Files Explained

### Core Scripts

1. **deploy-and-validate.sh** ⭐
   - Main orchestration script
   - Calls all other scripts in sequence
   - Handles logging and reporting
   - **This is what you run!**

2. **cleanup.sh**
   - Destroys all resources via Terraform
   - Removes kubeconfig
   - Prompts for confirmation

3. **config.sh**
   - Your configuration (with API token)
   - **Already configured for you**
   - Sourced by all other scripts

### Terraform Files

4. **terraform/main.tf**
   - Defines LKE cluster resource
   - Creates Object Storage bucket
   - Generates access keys
   - Saves kubeconfig to file

5. **terraform/variables.tf**
   - Declares all configurable parameters
   - Provides defaults

6. **terraform/outputs.tf**
   - Exports cluster connection info
   - Used by deployment scripts

### Validation Scripts

7. **scripts/install-redpanda.sh**
   - Adds Redpanda Helm repo
   - Creates namespace and secret
   - Deploys Helm chart with custom values
   - Configures tiered storage

8. **scripts/validate-cluster.sh**
   - Tests Kubernetes API
   - Checks node status
   - Verifies pod health
   - Validates PVCs and services

9. **scripts/test-tiered-storage.sh**
   - Creates tiered storage topic
   - Produces messages
   - Verifies upload to Object Storage
   - Tests consumption from tiered storage

10. **scripts/run-self-tests.sh**
    - Executes `rpk cluster self-test start`
    - Polls for completion
    - Parses and displays results
    - Checks for failures

11. **scripts/benchmark.sh**
    - Basic producer throughput test
    - Basic consumer throughput test
    - Simple latency measurement
    - System info collection

## Documentation

- **README.md** - Comprehensive project documentation
- **QUICKSTART.md** - Step-by-step execution guide (⭐ **START HERE**)
- **PROJECT_SUMMARY.md** - This file (overview and reference)

## Next Steps

### 1. Execute Deployment

```bash
./deploy-and-validate.sh
```

### 2. Review Results

```bash
# Summary report
cat reports/validation-report-*.txt

# Full log
less reports/validation-full-*.log

# Metrics JSON
cat reports/metrics-*.json | jq '.'
```

### 3. Access Cluster

```bash
# Set kubeconfig
export KUBECONFIG=~/.kube/redpanda-linode-kubeconfig

# Check Redpanda
kubectl exec -it redpanda-0 -n redpanda -- rpk cluster info

# Open Redpanda Console
kubectl port-forward svc/redpanda-console -n redpanda 8080:8080
# Visit http://localhost:8080
```

### 4. For Akamai Submission

Use the generated reports for:
- **ISV Catalyst (ISVC)**: Include metrics in qualification questionnaire
- **QCP**: Attach reports to qualification review submission

Key evidence:
- ✅ Linode Object Storage validated (S3-compatible)
- ✅ All self-tests passed (disk, network, cloud storage)
- ✅ Performance benchmarks recorded
- ✅ Architecture diagram (Helm chart + LKE + Volumes + Object Storage)

### 5. Cleanup

```bash
./cleanup.sh
```

## Troubleshooting

See **QUICKSTART.md** for detailed troubleshooting steps.

Common issues:
- **Quota exceeded**: New accounts need quota increase
- **Pods Pending**: Wait 2-3 minutes for volume provisioning
- **Self-tests fail**: Check Redpanda logs and Object Storage config
- **Low performance**: Verify Dedicated CPU plan (not Shared)

## Support & Resources

- **Project Issues**: Open issue in this repo
- **Redpanda Community**: https://redpanda.com/slack
- **Redpanda Docs**: https://docs.redpanda.com
- **Linode Support**: https://www.linode.com/support/
- **Linode LKE Guide**: https://www.linode.com/docs/guides/deploy-lke-cluster-using-terraform/

## License

MIT

---

**Ready to run? Start with QUICKSTART.md!**
