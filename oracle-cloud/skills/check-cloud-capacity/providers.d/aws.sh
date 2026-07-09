#!/bin/bash
# aws.sh — capacity module (informed by prior AWS runs; re-verify flags on use)
# matrix: vCPU quotas + NVMe instance-type offerings per AZ
# probe:  real launch (Insufficient(Instance)Capacity is only visible by trying)
#
#   ./check-capacity.sh --provider aws [--region us-east-1]
#   ./check-capacity.sh --provider aws --probe i4i.2xlarge --zone us-east-1a --subnet-id subnet-xxx
set -uo pipefail
REGION="${AWS_REGION:-us-east-1}" PROBE="" ZONE="" SUBNET=""
while [[ $# -gt 0 ]]; do case $1 in
    --region) REGION="$2"; shift 2 ;; --probe) PROBE="$2"; shift 2 ;;
    --zone) ZONE="$2"; shift 2 ;; --subnet-id) SUBNET="$2"; shift 2 ;;
    *) echo "unknown: $1"; exit 1 ;;
esac; done

# NVMe-instance-store families relevant to Redpanda benchmarking
SHAPES="${SHAPES:-m7gd.large m7gd.xlarge m7gd.8xlarge i4i.2xlarge i3en.2xlarge im4gn.2xlarge}"

echo "=== QUOTA (On-Demand vCPU limits, region $REGION) ==="
aws service-quotas list-service-quotas --service-code ec2 --region "$REGION" \
  --query "Quotas[?contains(QuotaName, 'On-Demand')].{name:QuotaName, value:Value}" --output table 2>/dev/null | head -20

echo ""
echo "=== SHAPE OFFERED PER AZ ==="
for s in $SHAPES; do
    printf "%-16s " "$s"
    aws ec2 describe-instance-type-offerings --location-type availability-zone --region "$REGION" \
      --filters "Name=instance-type,Values=$s" --query 'InstanceTypeOfferings[].Location' --output text 2>/dev/null || echo "?"
done

echo ""
echo "=== LOCAL NVME PER SHAPE ==="
aws ec2 describe-instance-types --instance-types $SHAPES --region "$REGION" \
  --query 'InstanceTypes[].{type:InstanceType, nvmeGB:InstanceStorageInfo.TotalSizeInGB, disks:InstanceStorageInfo.Disks[0].Count}' --output table 2>/dev/null

if [[ -n "$PROBE" ]]; then
    [[ -z "$SUBNET" ]] && { echo "❌ --subnet-id required for probe"; exit 1; }
    AMI=$(aws ssm get-parameter --region "$REGION" --name /aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text 2>/dev/null)
    echo ""
    echo "=== LAUNCH PROBE: $PROBE in ${ZONE:-$REGION} ==="
    OUT=$(aws ec2 run-instances --region "$REGION" --instance-type "$PROBE" --image-id "$AMI" \
        --subnet-id "$SUBNET" ${ZONE:+--placement AvailabilityZone=$ZONE} --count 1 \
        --query 'Instances[0].InstanceId' --output text 2>&1)
    if [[ "$OUT" == i-* ]]; then
        echo "✅ CAPACITY AVAILABLE — terminating probe $OUT"
        aws ec2 terminate-instances --region "$REGION" --instance-ids "$OUT" >/dev/null
    else
        echo "❌ $OUT" | head -2   # InsufficientInstanceCapacity = no hosts; VcpuLimitExceeded = quota
    fi
fi
