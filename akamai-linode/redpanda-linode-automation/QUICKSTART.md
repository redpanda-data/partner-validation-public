# Quick Start Guide

## Prerequisites Check

Before running, ensure you have these tools installed:

```bash
# Check required tools
terraform --version  # Need >= 1.0
kubectl version --client  # Need >= 1.27
helm version  # Need >= 3.10
jq --version  # For JSON parsing

# Install missing tools (macOS)
brew install terraform kubectl helm jq

# Install missing tools (Linux)
# terraform: https://www.terraform.io/downloads
# kubectl: https://kubernetes.io/docs/tasks/tools/
# helm: https://helm.sh/docs/intro/install/
# jq: https://stedolan.github.io/jq/download/
```

## Step-by-Step Execution

### 1. Configure Your API Token

Your Linode API token is already configured in `config.sh`. If you need to change it:

```bash
nano config.sh
# Edit LINODE_TOKEN variable
```

### 2. Review Configuration

Check the deployment configuration:

```bash
cat config.sh
```

Current settings:
- **Cluster**: redpanda-validation
- **Region**: us-east (Newark)
- **Nodes**: 3x Dedicated 16GB (8 vCPUs, 16GB RAM each)
- **Redpanda**: 3 brokers
- **Storage**: 50GB volumes per broker
- **Object Storage**: Linode Object Storage for tiered storage

### 3. Run Deployment

Execute the main script:

```bash
./deploy-and-validate.sh
```

This will:
1. **Initialize Terraform** (1 min)
2. **Deploy LKE cluster** (15-20 min)
   - 3 worker nodes
   - Object Storage bucket
3. **Install Redpanda** (5-10 min)
   - Helm chart deployment
   - Configure tiered storage
4. **Run validations** (10-15 min)
   - Cluster health checks
   - Tiered storage tests
   - Redpanda self-tests (disk, network, cloud)
   - Basic benchmarks
5. **Generate reports** (1 min)

**Total time: ~40 minutes**

### 4. Monitor Progress

The script outputs live progress. Watch for:
- ✓ Green checkmarks = Success
- ✗ Red X marks = Failures
- ⚠ Yellow warnings = Non-critical issues

### 5. View Results

After completion:

```bash
# View summary report
cat reports/validation-report-*.txt

# View full logs
cat reports/validation-full-*.log

# View metrics JSON
cat reports/metrics-*.json | jq '.'
```

## What Gets Tested

### 1. Infrastructure Tests
- ✓ LKE cluster is accessible
- ✓ All nodes are Ready
- ✓ Networking is functional

### 2. Redpanda Cluster Tests
- ✓ All broker pods Running
- ✓ PersistentVolumes Bound
- ✓ LoadBalancer has external IP
- ✓ Cluster health is good

### 3. Tiered Storage Tests
- ✓ Object Storage configured
- ✓ Data uploads to Linode Object Storage
- ✓ Data downloads from tiered storage
- ✓ S3 operations validated

### 4. Redpanda Self-Tests
Runs `rpk cluster self-test` which validates:

**Disk Tests:**
- Sequential write performance
- Sequential read performance
- Random write performance
- Random read performance

**Network Tests:**
- Inter-broker latency
- Inter-broker throughput

**Cloud Storage Tests:**
- PUT operations (upload)
- GET operations (download)
- LIST operations (enumerate objects)
- HEAD operations (metadata)
- DELETE operations (single object)
- DELETE operations (multiple objects)

Expected results:
- **Disk IOPS**: >16,000 (target: 25,000+)
- **Network latency**: <2ms (target: <1ms)
- **Cloud ops**: 0 timeouts, all operations succeed

### 5. Performance Benchmarks
- Producer throughput (msg/sec)
- Consumer throughput (msg/sec)
- End-to-end latency (p50, p95, p99)

## Access Deployed Resources

### Access Redpanda Cluster

```bash
# Set kubeconfig
export KUBECONFIG=~/.kube/redpanda-linode-kubeconfig

# Check cluster
kubectl get pods -n redpanda

# Access Redpanda CLI
kubectl exec -it redpanda-0 -n redpanda -- rpk cluster info
```

### Access Redpanda Console (Web UI)

```bash
# Port-forward to localhost
kubectl port-forward svc/redpanda-console -n redpanda 8080:8080

# Open browser
open http://localhost:8080
```

### Check Linode Object Storage

```bash
# Get bucket info
cd terraform
terraform output object_storage_bucket
terraform output object_storage_endpoint

# View in Linode Cloud Manager
open https://cloud.linode.com/object-storage
```

## Troubleshooting

### "Quota exceeded" error

New Linode accounts may have low resource quotas.

**Solution:**
1. Go to https://cloud.linode.com/support
2. Open a ticket: "Please increase my quota for LKE and compute resources"
3. Wait for approval (usually 1-24 hours)

### Pods stuck in "Pending"

Not enough resources or PVs not available.

```bash
# Check node resources
kubectl describe nodes

# Check PVCs
kubectl get pvc -n redpanda
```

**Solution:**
- Wait longer (PVs take 2-3 minutes to provision)
- Check Linode Cloud Manager for volume creation status

### Self-tests fail

Usually due to configuration issues.

```bash
# Check Redpanda logs
kubectl logs redpanda-0 -n redpanda

# Check cloud storage config
kubectl exec redpanda-0 -n redpanda -- rpk cluster config get | grep cloud_storage
```

**Common issues:**
- Object Storage credentials incorrect
- Bucket doesn't exist
- Network connectivity issues

### Performance lower than expected

Check node type and CPU model.

```bash
# Check node plan
kubectl get nodes -o jsonpath='{.items[0].metadata.labels.node\.kubernetes\.io/instance-type}'

# Check CPU model
kubectl exec redpanda-0 -n redpanda -- cat /proc/cpuinfo | grep "model name" | head -1
```

**Solution:**
- Use Dedicated or Premium CPU plans (not Shared)
- Dedicated 16GB is sufficient for testing but may have lower performance
- For production benchmarks, use Dedicated 64GB or Premium 64GB

## Cleanup

When you're done testing:

```bash
./cleanup.sh
```

This will destroy:
- LKE cluster and all resources
- Object Storage bucket and data
- All Redpanda data

**⚠️ WARNING: This cannot be undone!**

## Cost Estimate

Based on configuration in `config.sh`:

**Hourly:**
- LKE control plane: $0 (free)
- 3x Dedicated 16GB nodes: 3 × $0.27/hr = $0.81/hr
- 3x 50GB volumes: 3 × $0.007/hr = $0.021/hr
- Object Storage: $0.02/GB/month (minimal for testing)
- **Total: ~$0.83/hr**

**For 2-hour test run: ~$1.66**

**Important:**
- Remember to run `./cleanup.sh` when done!
- Leaving cluster running: ~$600/month
- Check billing: https://cloud.linode.com/account/billing

## Next Steps

After successful validation:

1. **Review reports** in `reports/` directory
2. **Save results** for Akamai submission
3. **Scale up** for production benchmarks (see main README)
4. **Document findings** for ISV Catalyst/QCP submission
5. **Run cleanup** to avoid charges

## Support

- **Redpanda**: https://redpanda.com/slack
- **Linode**: https://www.linode.com/support/
- **Issues**: Open issue in this repo
