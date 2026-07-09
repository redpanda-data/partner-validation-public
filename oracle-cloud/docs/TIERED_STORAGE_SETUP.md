# Tiered Storage Setup Guide

Guide for running Redpanda benchmarks with tiered storage (cloud storage) enabled using Linode Object Storage.

---

## Prerequisites

### 1. Linode Object Storage

**Create a bucket:**
```bash
# Via Linode CLI
linode-cli object-storage buckets create --cluster us-east-1 --label redpanda-tiered-tier1

# Or via Cloud Manager:
# https://cloud.linode.com/object-storage/buckets
```

**Generate access keys:**
```bash
# Via Linode CLI
linode-cli object-storage keys-create --label redpanda-benchmarks

# Or via Cloud Manager:
# https://cloud.linode.com/object-storage/access-keys
```

**Save credentials:**
```bash
# Create credentials file
cat > .env.tiered-storage << 'EOF'
# Linode Object Storage Credentials
LINODE_OBJ_BUCKET=redpanda-tiered-tier1
LINODE_OBJ_REGION=us-east-1
LINODE_OBJ_ENDPOINT=us-east-1.linodeobjects.com
LINODE_OBJ_ACCESS_KEY=<your-access-key>
LINODE_OBJ_SECRET_KEY=<your-secret-key>
LINODE_OBJ_PORT=443
EOF

# Keep this file secure
chmod 600 .env.tiered-storage
```

**Common Linode Object Storage regions:**
- `us-east-1` - Newark, NJ (endpoint: `us-east-1.linodeobjects.com`)
- `us-southeast-1` - Atlanta, GA (endpoint: `us-southeast-1.linodeobjects.com`)
- `eu-central-1` - Frankfurt, Germany (endpoint: `eu-central-1.linodeobjects.com`)
- `ap-south-1` - Singapore (endpoint: `ap-south-1.linodeobjects.com`)

### 2. Redpanda Enterprise License

Tiered storage requires an enterprise license. Options:

**Option A: Trial license**
- Request from: https://redpanda.com/try-redpanda
- Valid for 30 days
- Install with: `rpk cluster license set <license-string>`

**Option B: Developer mode (if available)**
- Some Redpanda versions allow tiered storage in developer mode
- Check with: `rpk cluster license info`

**Option C: Proceed without license**
- The script will warn but continue
- Tiered storage may not function without license
- Use for testing configuration only

---

## Tier 1 Deployment with Tiered Storage

### Step 1: Deploy Infrastructure

```bash
cd openmessaging-benchmark/driver-redpanda/deploy

# Deploy Tier 1 (3 brokers, 4 clients)
terraform apply -var-file='../../../terraform-tier-1-linode.tfvars'

# Extract IPs
BROKERS=$(terraform output -json | jq -r '.redpanda_private_ips.value | join(",")')
CLIENTS=$(terraform output -json | jq -r '.client_ips.value | join(",")')
PRIMARY_CLIENT=$(terraform output -raw client_ssh_host)
SEED_BROKER=$(echo $BROKERS | cut -d',' -f1)
JUMPBOX="97.107.137.207"  # Your jumpbox IP

echo "Seed broker: $SEED_BROKER"
```

### Step 2: Install Redpanda

```bash
cd ../../../

# Install Redpanda on all brokers
./tools/install-redpanda.sh \
  --broker-ips $BROKERS \
  --jumpbox $JUMPBOX \
  --ssh-key ~/.ssh/redpanda_linode
```

### Step 3: Form Cluster

```bash
# Form Redpanda cluster
./form-redpanda-cluster.sh \
  --broker-ips $BROKERS \
  --jumpbox $JUMPBOX \
  --ssh-key ~/.ssh/redpanda_linode

# Verify cluster health
ssh root@$JUMPBOX "ssh -i ~/.ssh/redpanda_linode root@$SEED_BROKER 'rpk cluster health'"
```

### Step 4: Configure Tiered Storage

```bash
# Source credentials
source .env.tiered-storage

# Configure tiered storage on seed broker
./tools/configure-tiered-storage.sh \
  --broker-ip $SEED_BROKER \
  --jumpbox $JUMPBOX \
  --ssh-key ~/.ssh/redpanda_linode \
  --bucket $LINODE_OBJ_BUCKET \
  --region $LINODE_OBJ_REGION \
  --endpoint $LINODE_OBJ_ENDPOINT \
  --access-key $LINODE_OBJ_ACCESS_KEY \
  --secret-key $LINODE_OBJ_SECRET_KEY

# Configuration will restart Redpanda and verify settings
```

**What this does:**
- Sets cloud_storage_enabled=true
- Configures bucket, region, and credentials
- Sets endpoint for Linode Object Storage
- Enables remote write and remote read
- Restarts Redpanda to apply changes

### Step 5: Verify Tiered Storage

```bash
# Check configuration
ssh root@$JUMPBOX "ssh -i ~/.ssh/redpanda_linode root@$SEED_BROKER \
  'rpk cluster config get | grep cloud_storage'"

# Should show:
# cloud_storage_enabled: true
# cloud_storage_bucket: redpanda-tiered-tier1
# cloud_storage_region: us-east-1
# etc.

# Check license status
ssh root@$JUMPBOX "ssh -i ~/.ssh/redpanda_linode root@$SEED_BROKER \
  'rpk cluster license info'"
```

### Step 6: Install OMB Tools

```bash
# Install benchmark tools on all clients
./tools/install-omb-tools.sh \
  --client-ips $CLIENTS \
  --jumpbox $JUMPBOX \
  --ssh-key ~/.ssh/redpanda_linode \
  --omb-source /root/bench/openmessaging-benchmark
```

### Step 7: Enable Tiered Storage for Benchmark Topics

The benchmark will create topics automatically, but they won't have tiered storage enabled by default. We need to either:

**Option A: Enable globally for all new topics**
```bash
ssh root@$JUMPBOX "ssh -i ~/.ssh/redpanda_linode root@$SEED_BROKER \
  'rpk cluster config set cloud_storage_enable_remote_write true && \
   rpk cluster config set cloud_storage_enable_remote_read true'"
```

**Option B: Modify workload to enable per-topic** (requires modifying benchmark workload config)

For simplicity, use **Option A** to enable tiered storage for all topics.

### Step 8: Run Tier 1 Benchmark

```bash
# Copy workload and driver configs to client
WORKLOAD_DIR="driver-redpanda/workloads"
DRIVER_DIR="driver-redpanda/driver-configs"

# Ensure configs exist locally
ls $WORKLOAD_DIR/workload-tier-1.yaml
ls $DRIVER_DIR/redpanda-ack-all-tier-1.yaml

# Copy to jumpbox first
scp -i ~/.ssh/redpanda_linode $WORKLOAD_DIR/workload-tier-1.yaml root@$JUMPBOX:/tmp/
scp -i ~/.ssh/redpanda_linode $DRIVER_DIR/redpanda-ack-all-tier-1.yaml root@$JUMPBOX:/tmp/

# Copy from jumpbox to primary client
ssh root@$JUMPBOX "
  scp -i ~/.ssh/redpanda_linode /tmp/workload-tier-1.yaml root@$PRIMARY_CLIENT:/opt/benchmark/workloads/
  scp -i ~/.ssh/redpanda_linode /tmp/redpanda-ack-all-tier-1.yaml root@$PRIMARY_CLIENT:/opt/benchmark/driver-redpanda/
"

# Start benchmark
ssh root@$JUMPBOX "ssh -i ~/.ssh/redpanda_linode root@$PRIMARY_CLIENT \
  'cd /opt/benchmark && \
   nohup bin/benchmark \
     --drivers driver-redpanda/redpanda-ack-all-tier-1.yaml \
     --workers-file workers.yaml \
     workloads/workload-tier-1.yaml > tier1-tiered.log 2>&1 &'"
```

### Step 9: Monitor Benchmark

```bash
# Monitor in real-time
./monitor-benchmark.sh \
  --tier 1 \
  --jumpbox $JUMPBOX \
  --client $PRIMARY_CLIENT \
  --provider linode

# Or tail logs manually
ssh root@$JUMPBOX "ssh -i ~/.ssh/redpanda_linode root@$PRIMARY_CLIENT \
  'tail -f /opt/benchmark/tier1-tiered.log'"
```

### Step 10: Verify Object Storage Usage

**During or after benchmark:**
```bash
# Check if data is being uploaded to object storage
linode-cli object-storage objects ls $LINODE_OBJ_BUCKET --cluster $LINODE_OBJ_REGION

# Or via web console
# https://cloud.linode.com/object-storage/buckets/$LINODE_OBJ_REGION/$LINODE_OBJ_BUCKET

# Check Redpanda metrics
ssh root@$JUMPBOX "ssh -i ~/.ssh/redpanda_linode root@$SEED_BROKER \
  'rpk cluster config get cloud_storage_enabled'"
```

You should see objects appearing in the bucket with names like:
- `<topic-id>/<partition>/...`
- Segment files in Redpanda's internal format

### Step 11: Download Results and Generate Reports

```bash
# Results will be collected automatically if using monitor-benchmark.sh
# Or download manually:
mkdir -p benchmark_results_linode_tiered/tier-1

ssh root@$JUMPBOX \
  "scp -i ~/.ssh/redpanda_linode root@$PRIMARY_CLIENT:/opt/benchmark/workload-tier-1*.json /tmp/"

scp root@$JUMPBOX:/tmp/workload-tier-1*.json benchmark_results_linode_tiered/tier-1/

# Generate reports
python3 generate-benchmark-report.py 1 \
  benchmark_results_linode_tiered/tier-1/workload-tier-1*.json \
  --provider linode
```

### Step 12: Cleanup

```bash
# Destroy infrastructure
cd driver-redpanda/deploy
terraform destroy -var-file='../../../terraform-tier-1-linode.tfvars' -auto-approve

# Optional: Clean up object storage bucket
linode-cli object-storage objects rm $LINODE_OBJ_BUCKET --all --cluster $LINODE_OBJ_REGION
```

---

## Tiers 2-4 Deployment

Once Tier 1 succeeds with tiered storage, repeat for Tiers 2-4:

```bash
# Tier 2
terraform apply -var-file='../../../terraform-tier-2-linode.tfvars'
# ... follow steps 2-12 with tier 2 ...

# Tier 3
terraform apply -var-file='../../../terraform-tier-3-linode.tfvars'
# ... follow steps 2-12 with tier 3 ...

# Tier 4
terraform apply -var-file='../../../terraform-tier-4-linode.tfvars'
# ... follow steps 2-12 with tier 4 ...
```

**Note:** You can use the same object storage bucket for all tiers, or create separate buckets:
```bash
linode-cli object-storage buckets create --cluster us-east-1 --label redpanda-tiered-tier2
linode-cli object-storage buckets create --cluster us-east-1 --label redpanda-tiered-tier3
linode-cli object-storage buckets create --cluster us-east-1 --label redpanda-tiered-tier4
```

---

## Performance Comparison

### With Tiered Storage (Expected)
- **Throughput:** Similar to non-tiered (60 MB/s for Tier 1)
- **Latency:** Slightly higher due to object storage uploads
- **Disk usage:** Lower on brokers (data moves to object storage)
- **Cost:** Reduced broker disk costs, added object storage costs

### Without Tiered Storage (Baseline)
- Results from previous runs in `benchmark_results_linode/`

### Comparison Metrics
1. **Throughput achievement:** % of target
2. **P99 latency increase:** Compare with baseline
3. **Object storage data transfer:** Total MB uploaded
4. **Cost analysis:** Broker storage savings vs object storage costs

---

## Troubleshooting

### License Issues
```bash
# Check license
rpk cluster license info

# If expired or missing, request trial license
# https://redpanda.com/try-redpanda

# Set license
rpk cluster license set <license-string>
```

### Object Storage Connection Issues
```bash
# Test connectivity from broker
ssh root@$SEED_BROKER "
  curl -v https://$LINODE_OBJ_ENDPOINT
"

# Check credentials
rpk cluster config get | grep cloud_storage

# Verify bucket exists
linode-cli object-storage buckets list
```

### Data Not Uploading
```bash
# Check if remote write is enabled globally
rpk cluster config get cloud_storage_enable_remote_write

# Check topic-specific settings
rpk topic describe <topic-name> -c redpanda.remote.write

# Check upload interval (may need to wait 5 minutes)
rpk cluster config get cloud_storage_segment_max_upload_interval_sec

# Check for errors in logs
sudo journalctl -u redpanda -f | grep cloud_storage
```

### Configuration Not Applied
```bash
# Check if restart is needed
rpk cluster config status

# Restart Redpanda
sudo systemctl restart redpanda

# Wait for cluster to stabilize
rpk cluster health
```

---

## Cost Estimate

**Tier 1 with Tiered Storage:**
- Infrastructure: ~$2/hour (3 brokers + 4 clients)
- Object storage: ~$0.02/GB stored + data transfer
- Benchmark duration: ~30 minutes
- Total benchmark cost: ~$1.50-$2.00
- Object storage ongoing: Depends on retention policy

**Note:** Object storage costs accumulate over time based on data retention. Set appropriate retention policies to manage costs.

---

## References

- Redpanda Tiered Storage Docs: https://docs.redpanda.com/current/manage/tiered-storage/
- Linode Object Storage: https://www.linode.com/products/object-storage/
- Configuration script: `tools/configure-tiered-storage.sh`
- Credentials template: `.env.tiered-storage.template`

---

**Ready to test tiered storage performance across benchmark tiers!**
