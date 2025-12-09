# Redpanda on Linode - Automated Deployment & Validation

Automated end-to-end deployment and validation of Redpanda on Linode Kubernetes Engine (LKE) with comprehensive testing.

## What This Does

This automation:
1. **Provisions infrastructure** via Terraform:
   - LKE cluster (3-node, Dedicated CPU)
   - Linode Object Storage bucket for tiered storage
   - VPC and Firewall rules
2. **Deploys Redpanda** via Helm with tiered storage enabled
3. **Runs comprehensive validation**:
   - Cluster health checks
   - Producer/consumer functionality tests
   - Tiered storage validation (S3 operations)
   - Redpanda self-tests (disk, network, cloud storage)
   - Performance benchmarks
4. **Generates reports** with metrics, logs, and screenshots

## Prerequisites

- **Linode Account** with API token
- **Tools installed**:
  - `terraform` (>= 1.0)
  - `kubectl` (>= 1.27)
  - `helm` (>= 3.10)
  - `jq` (for JSON parsing)
  - `rpk` (Redpanda CLI - will be installed if missing)
- **Linode API Token** with full access

## Quick Start

### 1. Configure Credentials

```bash
# Copy example config
cp config.example.sh config.sh

# Edit config.sh with your Linode API token
nano config.sh
```

### 2. Run Full Deployment and Validation

```bash
./deploy-and-validate.sh
```

This will:
- Deploy LKE cluster (15-20 min)
- Install Redpanda with Helm (5-10 min)
- Run all validation tests (10-15 min)
- Generate report in `reports/`

**Total time: ~40 minutes**

### 3. View Results

```bash
# View summary report
cat reports/validation-report-$(date +%Y%m%d).txt

# View detailed logs
cat reports/validation-full-$(date +%Y%m%d).log
```

## Project Structure

```
redpanda-linode-automation/
├── README.md                    # This file
├── config.example.sh            # Template for credentials
├── config.sh                    # Your credentials (gitignored)
├── deploy-and-validate.sh       # Main orchestration script
├── terraform/
│   ├── main.tf                  # LKE cluster + Object Storage
│   ├── variables.tf             # Configurable parameters
│   ├── outputs.tf               # Cluster info outputs
│   └── terraform.tfvars.example # Example variables
├── scripts/
│   ├── install-redpanda.sh      # Helm deployment
│   ├── validate-cluster.sh      # Health checks
│   ├── test-tiered-storage.sh   # S3 operations test
│   ├── run-self-tests.sh        # rpk cluster self-test
│   └── benchmark.sh             # Performance tests
└── reports/
    └── (generated reports)
```

## Configuration Options

Edit `terraform/terraform.tfvars` to customize:

```hcl
# Cluster configuration
cluster_name       = "redpanda-validation"
k8s_version        = "1.28"
region             = "us-east"

# Node pool sizing
node_type          = "g6-dedicated-32"  # Dedicated 64GB
node_count         = 3

# Redpanda configuration
redpanda_replicas  = 3
volume_size_gb     = 100
object_storage_gb  = 500
```

## Validation Tests

### 1. Cluster Health Checks
- LKE nodes are Ready
- Redpanda pods are Running
- PersistentVolumes are Bound
- Services have external IPs

### 2. Redpanda Functionality Tests
- Create topics
- Produce messages
- Consume messages
- List topics and partitions

### 3. Tiered Storage Validation
- Upload data to Linode Object Storage
- Verify objects in bucket
- Download data from tiered storage
- Measure upload/download throughput

### 4. Redpanda Self-Tests
Runs `rpk cluster self-test` to validate:
- **Disk I/O**: Sequential/random read/write performance
- **Network**: Inter-broker latency and throughput
- **Cloud Storage**: S3 operations (put, get, list, delete)

Expected results:
- Disk IOPS: >16,000 (target: 25,000+)
- Network latency: <2ms (target: <1ms)
- Cloud storage ops: 0 timeouts, all operations succeed

### 5. Basic Performance Benchmarks
- Producer throughput (msg/sec)
- Consumer throughput (msg/sec)
- End-to-end latency (p50, p95, p99)

## Output Reports

### Summary Report
`reports/validation-report-YYYYMMDD.txt`
- Pass/fail status for each test
- Key metrics summary
- Recommendations

### Full Logs
`reports/validation-full-YYYYMMDD.log`
- Complete command outputs
- Timestamps for each step
- Error messages (if any)

### Metrics JSON
`reports/metrics-YYYYMMDD.json`
- Structured data for analysis
- Benchmark results
- Self-test metrics

## Cleanup

```bash
# Destroy all resources
cd terraform
terraform destroy

# Remove kubeconfig
rm -f ~/.kube/redpanda-linode-kubeconfig
```

**Warning:** This will delete the LKE cluster, volumes, and Object Storage bucket. Data will be lost.

## Troubleshooting

### Terraform fails with quota error
- New Linode accounts may have low quotas
- Open support ticket to increase limits

### Pods stuck in Pending
- Check node resources: `kubectl describe nodes`
- May need larger node type or more nodes

### Self-test fails
- Check Redpanda logs: `kubectl logs -n redpanda redpanda-0`
- Verify Object Storage credentials in secret
- Ensure Object Storage bucket exists

### Performance below expectations
- Verify node type is Dedicated or Premium CPU (not Shared)
- Check CPU model: `kubectl exec -it redpanda-0 -n redpanda -- cat /proc/cpuinfo | grep "model name"`
- Ensure volumes are using `linode-block-storage-retain` StorageClass

## Support

- **Redpanda Docs**: https://docs.redpanda.com
- **Linode Docs**: https://www.linode.com/docs/
- **Issues**: Open an issue in this repo or contact support@redpanda.com

## License

MIT
