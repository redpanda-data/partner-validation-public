#!/bin/bash
# setup-observability.sh - Deploy the Redpanda observability stack
# (https://github.com/redpanda-data/observability) onto a monitoring host
# and publish a publicly exposed Grafana endpoint.
#
# Idempotent: if Grafana already answers on the monitoring host, the script
# reports the existing endpoint and exits without changing anything.
#
# Usage:
#   ./setup-observability.sh \
#     --monitoring-host <public-ip> \
#     --broker-ips <priv-ip1,priv-ip2,...> \
#     [--ssh-key ~/.ssh/redpanda_oci] \
#     [--grafana-password <password>]
#
# Requirements:
#   - Monitoring host reachable via SSH as root
#   - TCP 3000 open to 0.0.0.0/0 on the monitoring host (cloud firewall)
#   - Brokers expose /public_metrics on :9644 reachable from monitoring host

set -euo pipefail

MON_HOST=""
BROKER_IPS=""
SSH_KEY="$HOME/.ssh/redpanda_oci"
GRAFANA_PASSWORD="redpanda-benchmark"
OBS_REPO="https://github.com/redpanda-data/observability.git"
ADMIN_PORT="9644"   # 31644 for OKE NodePort deployments

while [[ $# -gt 0 ]]; do
    case $1 in
        --monitoring-host)   MON_HOST="$2"; shift 2 ;;
        --broker-ips)        BROKER_IPS="$2"; shift 2 ;;
        --ssh-key)           SSH_KEY="$2"; shift 2 ;;
        --grafana-password)  GRAFANA_PASSWORD="$2"; shift 2 ;;
        --admin-port)        ADMIN_PORT="$2"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$MON_HOST" || -z "$BROKER_IPS" ]] && { echo "Error: --monitoring-host and --broker-ips are required"; exit 1; }

SSH="ssh -o StrictHostKeyChecking=no -i $SSH_KEY root@$MON_HOST"

# sslip.io maps <ip-with-dashes>.sslip.io → <ip>, giving us a real hostname
# for a Let's Encrypt cert. Browsers auto-upgrade http:// to https://, so a
# plain-HTTP endpoint is effectively unreachable for colleagues — TLS is
# required for the endpoint to count as published.
GRAFANA_DOMAIN="$(echo "$MON_HOST" | tr . -).sslip.io"

print_endpoints() {
    echo "   Grafana (public, share this): https://$GRAFANA_DOMAIN"
    echo "   ├─ Redpanda Ops Dashboard (watch benchmarks here):"
    echo "   │    https://$GRAFANA_DOMAIN/d/FejE4c6nz/redpanda-ops-dashboard"
    echo "   ├─ Kafka Topic Metrics (per-topic drilldown):"
    echo "   │    https://$GRAFANA_DOMAIN/d/Nxwln29Mz/kafka-topic-metrics"
    echo "   └─ OCI Object Storage / Tiered Storage (uploads, throttling, latency):"
    echo "        https://$GRAFANA_DOMAIN/d/oci-object-storage/oci-object-storage-tiered-storage"
    echo ""
    echo "   ⚠  Broker-side dashboards show COMPRESSED (on-the-wire) throughput."
    echo "      With lz4 + repetitive benchmark payloads this reads ~4x lower than"
    echo "      OMB's logical MB/s — both are correct; they measure different points."
}

# ── Idempotency check: skip if observability is already running ────────────
# BUT always verify Prometheus targets match the requested brokers — after a
# cluster rebuild the stack is healthy yet scraping dead IPs (seen July 8).
if curl -sf --max-time 10 "https://$GRAFANA_DOMAIN/api/health" >/dev/null 2>&1; then
    WANT=$(echo "$BROKER_IPS" | tr ',' '\n' | sed "s/$/:${ADMIN_PORT}/" | sort)
    HAVE=$($SSH "docker exec prometheus wget -qO- http://localhost:9090/api/v1/targets 2>/dev/null" \
        | python3 -c "import json,sys; print('\n'.join(sorted(t['labels']['instance'] for t in json.load(sys.stdin)['data']['activeTargets'])))" 2>/dev/null)
    if [ "$WANT" = "$HAVE" ]; then
        echo "✅ Observability already running with correct targets — skipping setup."
        print_endpoints
        exit 0
    fi
    echo "⚠ Observability running but targets are stale — retargeting Prometheus..."
    TARGETS_YAML=$(echo "$BROKER_IPS" | tr ',' '\n' | sed "s/^/    - /;s/$/:${ADMIN_PORT}/")
    $SSH "cat > /opt/observability/prometheus.yml <<PROM
global:
  scrape_interval: 10s
  evaluation_interval: 10s

scrape_configs:
- job_name: redpanda
  static_configs:
  - targets:
$TARGETS_YAML
  metrics_path: /public_metrics
PROM
docker restart prometheus >/dev/null"
    echo "✅ Prometheus retargeted."
    print_endpoints
    exit 0
fi
echo "Observability not detected on $MON_HOST — deploying..."

# ── Build prometheus scrape targets from broker IPs ─────────────────────────
TARGETS=""
IFS=',' read -ra BROKERS <<< "$BROKER_IPS"
for b in "${BROKERS[@]}"; do
    TARGETS="${TARGETS}    - ${b}:${ADMIN_PORT}\n"
done

$SSH bash -s <<REMOTE
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# OCI Ubuntu images firewall everything except SSH at the host level
iptables -P INPUT ACCEPT && iptables -F INPUT && (netfilter-persistent save >/dev/null 2>&1 || true)

# Wait out first-boot apt locks, then install docker + git
for i in \$(seq 1 60); do fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break; sleep 5; done
command -v docker >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
command -v git >/dev/null 2>&1 || apt-get install -y -qq git >/dev/null 2>&1

# Dashboards from the official redpanda-data/observability repo
rm -rf /opt/observability
git clone -q --depth 1 $OBS_REPO /opt/observability-repo
mkdir -p /opt/observability/{dashboards,provisioning/datasources,provisioning/dashboards}
cp /opt/observability-repo/grafana-dashboards/*.json /opt/observability/dashboards/
REMOTE
# custom tiered-storage dashboard ships with this skill
scp -o StrictHostKeyChecking=no -i "$SSH_KEY" "$(dirname "$0")/OCI-Object-Storage-Dashboard.json" root@$MON_HOST:/opt/observability/dashboards/ 2>/dev/null || true
$SSH bash -s <<REMOTE
set -euo pipefail

cat > /opt/observability/prometheus.yml <<'PROM'
global:
  scrape_interval: 10s
  evaluation_interval: 10s

scrape_configs:
- job_name: redpanda
  static_configs:
  - targets:
$(printf "$TARGETS")
  metrics_path: /public_metrics
PROM

cat > /opt/observability/provisioning/datasources/prometheus.yaml <<'DS'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
DS

cat > /opt/observability/provisioning/dashboards/redpanda.yaml <<'DASH'
apiVersion: 1
providers:
  - name: Redpanda
    folder: Redpanda
    type: file
    options:
      path: /var/lib/grafana/dashboards
DASH

cat > /opt/observability/docker-compose.yml <<'COMPOSE'
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus-data:/prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.retention.time=15d
    restart: unless-stopped
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=__GRAFANA_PASSWORD__
      - GF_AUTH_ANONYMOUS_ENABLED=true
      - GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer
    volumes:
      - ./provisioning:/etc/grafana/provisioning
      - ./dashboards:/var/lib/grafana/dashboards
      - grafana-data:/var/lib/grafana
    restart: unless-stopped
  caddy:
    image: caddy:latest
    container_name: caddy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy-data:/data
    restart: unless-stopped
volumes:
  prometheus-data:
  grafana-data:
  caddy-data:
COMPOSE

cat > /opt/observability/Caddyfile <<CADDY
$GRAFANA_DOMAIN {
    reverse_proxy grafana:3000
}
CADDY
sed -i "s/__GRAFANA_PASSWORD__/$GRAFANA_PASSWORD/" /opt/observability/docker-compose.yml

cd /opt/observability
docker compose up -d
REMOTE

# ── Verify ──────────────────────────────────────────────────────────────────
echo "Waiting for Grafana to come up (TLS cert issuance can take ~30s)..."
for i in $(seq 1 30); do
    if curl -sf --max-time 5 "https://$GRAFANA_DOMAIN/api/health" >/dev/null 2>&1; then
        echo ""
        echo "✅ Observability stack deployed successfully"
        echo "   Login: anonymous read-only; admin/$GRAFANA_PASSWORD to edit"
        echo "   Prometheus targets: $BROKER_IPS (:9644 /public_metrics)"
        print_endpoints
        exit 0
    fi
    sleep 5
done
echo "❌ Grafana did not become healthy within 150s — check: $SSH 'cd /opt/observability && docker compose logs'"
exit 1
