# Architecture Diagram

## Deployed Infrastructure

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Linode Cloud (us-east)                       │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │    Linode Kubernetes Engine (LKE) Cluster                    │   │
│  │    Name: redpanda-validation                                 │   │
│  │    Version: 1.28                                             │   │
│  │                                                               │   │
│  │  ┌────────────────┐  ┌────────────────┐  ┌────────────────┐│   │
│  │  │  Worker Node 1 │  │  Worker Node 2 │  │  Worker Node 3 ││   │
│  │  │  g6-dedicated-8│  │  g6-dedicated-8│  │  g6-dedicated-8││   │
│  │  │  8 vCPU        │  │  8 vCPU        │  │  8 vCPU        ││   │
│  │  │  16 GB RAM     │  │  16 GB RAM     │  │  16 GB RAM     ││   │
│  │  │  AMD EPYC      │  │  AMD EPYC      │  │  AMD EPYC      ││   │
│  │  └────────┬───────┘  └────────┬───────┘  └────────┬───────┘│   │
│  │           │                   │                   │         │   │
│  │  ┌────────┴──────────┬────────┴──────────┬────────┴──────┐ │   │
│  │  │                   │                   │                │ │   │
│  │  │  Redpanda Pod 0   │  Redpanda Pod 1   │  Redpanda Pod 2│ │   │
│  │  │  ┌─────────────┐  │  ┌─────────────┐  │  ┌─────────────┐│   │
│  │  │  │ Broker      │  │  │ Broker      │  │  │ Broker      ││   │
│  │  │  │ Port 9092   │  │  │ Port 9092   │  │  │ Port 9092   ││   │
│  │  │  │ Admin 9644  │  │  │ Admin 9644  │  │  │ Admin 9644  ││   │
│  │  │  │ Pandaproxy  │  │  │ Pandaproxy  │  │  │ Pandaproxy  ││   │
│  │  │  │ 8082        │  │  │ 8082        │  │  │ 8082        ││   │
│  │  │  └──────┬──────┘  │  └──────┬──────┘  │  └──────┬──────┘│   │
│  │  │         │         │         │         │         │        │   │
│  │  │  ┌──────▼──────┐  │  ┌──────▼──────┐  │  ┌──────▼──────┐│   │
│  │  │  │ PVC         │  │  │ PVC         │  │  │ PVC         ││   │
│  │  │  │ 50 GB       │  │  │ 50 GB       │  │  │ 50 GB       ││   │
│  │  │  └──────┬──────┘  │  └──────┬──────┘  │  └──────┬──────┘│   │
│  │  │         │         │         │         │         │        │   │
│  │  │  ┌──────▼──────┐  │  ┌──────▼──────┐  │  ┌──────▼──────┐│   │
│  │  │  │Linode Volume│  │  │Linode Volume│  │  │Linode Volume││   │
│  │  │  │(NVMe-backed)│  │  │(NVMe-backed)│  │  │(NVMe-backed)││   │
│  │  │  │25K+ IOPS    │  │  │25K+ IOPS    │  │  │25K+ IOPS    ││   │
│  │  │  └─────────────┘  │  └─────────────┘  │  └─────────────┘│   │
│  │  │                   │                   │                │ │   │
│  │  └───────────────────┴───────────────────┴────────────────┘ │   │
│  │                                                               │   │
│  │  ┌─────────────────────────────────────────────────────────┐│   │
│  │  │  Redpanda Console Pod (Web UI)                           ││   │
│  │  │  Port 8080                                               ││   │
│  │  └─────────────────────────────────────────────────────────┘│   │
│  │                                                               │   │
│  │  ┌─────────────────────────────────────────────────────────┐│   │
│  │  │  Services                                                ││   │
│  │  │  ┌──────────────────────────────────────────────────┐   ││   │
│  │  │  │ LoadBalancer Service (NodeBalancer)              │   ││   │
│  │  │  │ External IP: <assigned by Linode>                │   ││   │
│  │  │  │ Port 9092 → Redpanda Brokers                     │   ││   │
│  │  │  └──────────────────────────────────────────────────┘   ││   │
│  │  └─────────────────────────────────────────────────────────┘│   │
│  │                                                               │   │
│  │  ┌─────────────────────────────────────────────────────────┐│   │
│  │  │  Namespace: redpanda                                     ││   │
│  │  │  Secret: linode-object-storage-creds                     ││   │
│  │  │  (S3 access keys for tiered storage)                     ││   │
│  │  └─────────────────────────────────────────────────────────┘│   │
│  └───────────────────────────────────────────────────────────────┘   │
│                                                                       │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │  Linode Object Storage (S3-compatible)                       │   │
│  │  Region: us-east-1                                           │   │
│  │                                                               │   │
│  │  ┌─────────────────────────────────────────────────────────┐│   │
│  │  │  Bucket: redpanda-tiered-<timestamp>                     ││   │
│  │  │  Endpoint: us-east-1.linodeobjects.com                   ││   │
│  │  │  Access: Private                                         ││   │
│  │  │                                                           ││   │
│  │  │  Contents:                                               ││   │
│  │  │  ├── <topic>/<partition>/segment-files/                 ││   │
│  │  │  └── <topic>/<partition>/manifest-files/                ││   │
│  │  │                                                           ││   │
│  │  │  Purpose: Cost-efficient long-term data retention        ││   │
│  │  │  Cost: $5/TB/month (vs $100+/TB for NVMe)               ││   │
│  │  └─────────────────────────────────────────────────────────┘│   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                       │
└─────────────────────────────────────────────────────────────────────┘

        ▲
        │
        │ Kafka API (port 9092)
        │ Admin API (port 9644)
        │ REST API (port 8082)
        │
   ┌────┴─────┐
   │  Clients │
   │  - rpk   │
   │  - Apps  │
   │  - Tests │
   └──────────┘
```

## Data Flow

### 1. Producer → Broker → Storage

```
Producer
  │
  ├─> Redpanda Broker (Leader)
  │     │
  │     ├─> Local NVMe Storage (Linode Volume)
  │     │     └─> Hot data (recent segments)
  │     │
  │     └─> Replicas (Followers)
  │           └─> Replicate to other brokers
  │
  └─> Tiered Storage Upload (background)
        └─> Linode Object Storage (S3-compatible)
              └─> Cold data (older segments)
```

### 2. Consumer → Broker → Storage

```
Consumer
  │
  └─> Redpanda Broker
        │
        ├─> Read from Local NVMe (if available)
        │     └─> Fast: 25K+ IOPS, <1ms latency
        │
        └─> Read from Tiered Storage (if needed)
              └─> Slower but cost-efficient
                  └─> Linode Object Storage (S3 GET)
```

## Network Architecture

```
                    Internet
                       │
                       │
                       ▼
              ┌─────────────────┐
              │  NodeBalancer   │
              │  (LoadBalancer) │
              │  Port 9092      │
              └────────┬────────┘
                       │
         ┌─────────────┼─────────────┐
         │             │             │
         ▼             ▼             ▼
    ┌────────┐    ┌────────┐    ┌────────┐
    │Broker 0│◄──►│Broker 1│◄──►│Broker 2│
    └────────┘    └────────┘    └────────┘
         │             │             │
         │   Internal  │   Cluster   │
         │ Communication│ (Private)   │
         │   <1ms RTT  │             │
         │             │             │
         └─────────────┴─────────────┘
                       │
                       ▼
              Linode Object Storage
              (Tiered Storage)
```

## Storage Tiers

```
┌─────────────────────────────────────────────────────────────┐
│  Local NVMe Storage (Linode Volumes)                        │
│  ─────────────────────────────────────────────────────────  │
│                                                              │
│  Purpose:   Hot data (recent messages)                      │
│  Size:      50 GB per broker (configurable)                 │
│  IOPS:      25,000+ (exceeds Redpanda's 16K requirement)    │
│  Latency:   <1ms                                            │
│  Cost:      ~$0.10/GB/month                                 │
│  Retention: 3-7 days typical                                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                         │
                         │ Automatic upload of
                         │ older segments
                         ▼
┌─────────────────────────────────────────────────────────────┐
│  Linode Object Storage (Tiered Storage)                     │
│  ─────────────────────────────────────────────────────────  │
│                                                              │
│  Purpose:   Cold data (older messages)                      │
│  Size:      Unlimited (pay-as-you-go)                       │
│  IOPS:      N/A (S3-compatible API)                         │
│  Latency:   50-100ms (acceptable for historical data)       │
│  Cost:      $5/TB/month (20x cheaper!)                      │
│  Retention: Unlimited (months to years)                     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

## Deployment Flow

```
┌─────────────────┐
│  You run:       │
│  ./deploy-and-  │
│  validate.sh    │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────┐
│  1. Terraform Init              │
│     - Download providers         │
│     - Initialize state           │
└────────┬────────────────────────┘
         │
         ▼
┌─────────────────────────────────┐
│  2. Terraform Apply             │
│     - Create LKE cluster         │
│     - Create Object Storage      │
│     - Generate kubeconfig        │
│     (15-20 minutes)              │
└────────┬────────────────────────┘
         │
         ▼
┌─────────────────────────────────┐
│  3. Wait for Cluster Ready      │
│     - Check nodes Ready          │
│     - Verify API accessible      │
└────────┬────────────────────────┘
         │
         ▼
┌─────────────────────────────────┐
│  4. Helm Install Redpanda       │
│     - Add Helm repo              │
│     - Create namespace           │
│     - Deploy StatefulSet         │
│     - Configure tiered storage   │
│     (5-10 minutes)               │
└────────┬────────────────────────┘
         │
         ▼
┌─────────────────────────────────┐
│  5. Wait for Redpanda Ready     │
│     - Check pods Running         │
│     - Verify PVCs Bound          │
└────────┬────────────────────────┘
         │
         ▼
┌─────────────────────────────────┐
│  6. Run Validations             │
│     - Cluster health checks      │
│     - Tiered storage tests       │
│     - Redpanda self-tests        │
│     - Basic benchmarks           │
│     (10-15 minutes)              │
└────────┬────────────────────────┘
         │
         ▼
┌─────────────────────────────────┐
│  7. Generate Reports            │
│     - Summary report (TXT)       │
│     - Full log (LOG)             │
│     - Metrics (JSON)             │
└────────┬────────────────────────┘
         │
         ▼
┌─────────────────────────────────┐
│  Done! ✓                        │
│  - Reports in reports/           │
│  - Cluster accessible            │
│  - Ready for testing             │
└─────────────────────────────────┘
```

## Component Responsibilities

| Component | Purpose | Technology |
|-----------|---------|------------|
| **LKE Cluster** | Kubernetes orchestration | Linode managed control plane |
| **Worker Nodes** | Compute for Redpanda brokers | Dedicated 16GB (AMD EPYC) |
| **Redpanda StatefulSet** | Streaming platform | Kafka-compatible, ZooKeeper-free |
| **Linode Volumes** | High-performance local storage | NVMe-backed, 25K+ IOPS |
| **Linode Object Storage** | Cost-efficient tiered storage | S3-compatible API |
| **NodeBalancer** | External load balancing | Linode Layer 4 TCP LB |
| **Redpanda Console** | Web UI for cluster management | HTTP dashboard |
| **Kubernetes Secret** | Secure credential storage | S3 access keys |

## Security Architecture

```
┌─────────────────────────────────────────────────┐
│  External Access                                 │
│  ────────────────────────────────────────────   │
│                                                  │
│  ┌──────────────────────────────────────────┐  │
│  │  NodeBalancer (LoadBalancer)             │  │
│  │  - Public IP                             │  │
│  │  - Kafka API (9092)                      │  │
│  │  - Can be restricted via Firewall        │  │
│  └──────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
                      │
                      │ Routes to
                      ▼
┌─────────────────────────────────────────────────┐
│  Internal Cluster Network                       │
│  ────────────────────────────────────────────   │
│                                                  │
│  ┌──────────────────────────────────────────┐  │
│  │  Redpanda Brokers                        │  │
│  │  - Private inter-broker communication    │  │
│  │  - Replication traffic                   │  │
│  │  - <1ms latency                          │  │
│  └──────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
                      │
                      │ Outbound HTTPS
                      ▼
┌─────────────────────────────────────────────────┐
│  Linode Object Storage                          │
│  ────────────────────────────────────────────   │
│                                                  │
│  ┌──────────────────────────────────────────┐  │
│  │  S3 API (HTTPS)                          │  │
│  │  - TLS 1.2+                              │  │
│  │  - Access keys in K8s Secret             │  │
│  │  - Bucket: Private ACL                   │  │
│  └──────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

## Scaling Architecture

### Horizontal Scaling (Add More Brokers)

```
Initial: 3 Brokers          Scaled: 6 Brokers
┌────┐ ┌────┐ ┌────┐       ┌────┐ ┌────┐ ┌────┐
│ B0 │ │ B1 │ │ B2 │  ──►  │ B0 │ │ B1 │ │ B2 │
└────┘ └────┘ └────┘       └────┘ └────┘ └────┘
                            ┌────┐ ┌────┐ ┌────┐
                            │ B3 │ │ B4 │ │ B5 │
                            └────┘ └────┘ └────┘

- Edit Helm values: replicas: 6
- LKE autoscaler adds 3 nodes
- Redpanda rebalances partitions
- Linear scaling (2x brokers = 2x throughput)
```

### Vertical Scaling (Larger Nodes)

```
Initial: Dedicated 16GB     Scaled: Dedicated 64GB
┌──────────────────┐       ┌──────────────────┐
│ 8 vCPU           │       │ 32 vCPU          │
│ 16 GB RAM        │  ──►  │ 64 GB RAM        │
│ AMD EPYC 7002/03 │       │ AMD EPYC 7713    │
└──────────────────┘       └──────────────────┘

- Resize node pool in Linode
- Rolling update (one node at a time)
- Update Helm values: resources.cpu.cores: 30
- Higher per-broker throughput
```

---

**See QUICKSTART.md to deploy this architecture!**
