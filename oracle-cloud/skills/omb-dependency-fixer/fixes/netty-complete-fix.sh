#!/bin/bash
#
# netty-complete-fix.sh - Complete Netty conflict resolution
#
# This fix ensures coordinator and workers have IDENTICAL library versions
# by rebuilding OMB once and deploying the exact same installation everywhere.

set -euo pipefail

OMB_PATH="${1:-}"
CLIENT_IPS="${2:-}"
SSH_KEY="${3:-~/.ssh/id_rsa}"

if [[ -z "$OMB_PATH" ]] || [[ -z "$CLIENT_IPS" ]]; then
    echo "Usage: $0 <omb-path> <client-ips> [ssh-key]"
    exit 1
fi

IFS=',' read -ra CLIENTS <<< "$CLIENT_IPS"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Complete Netty Fix Strategy ===${NC}"
echo "This will rebuild OMB with a single consistent Netty version"
echo "and deploy identical installations to all clients."
echo

# Step 1: Clean rebuild with forced Netty version
echo -e "${YELLOW}Step 1: Rebuilding OMB from scratch with Netty 4.1.79.Final${NC}"

cd "$OMB_PATH"

# Create a custom dependency management section in root pom.xml
cat > /tmp/netty-fix.xml << 'EOF'
<dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>io.netty</groupId>
      <artifactId>netty-bom</artifactId>
      <version>4.1.79.Final</version>
      <type>pom</type>
      <scope>import</scope>
    </dependency>
  </dependencies>
</dependencyManagement>
EOF

# Backup original pom
cp pom.xml pom.xml.backup

# Insert dependency management before dependencies section
if ! grep -q "netty-bom" pom.xml; then
    sed -i '/<dependencies>/i\  <dependencyManagement>\n    <dependencies>\n      <dependency>\n        <groupId>io.netty</groupId>\n        <artifactId>netty-bom</artifactId>\n        <version>4.1.79.Final</version>\n        <type>pom</type>\n        <scope>import</scope>\n      </dependency>\n    </dependencies>\n  </dependencyManagement>' pom.xml
fi

# Clean and rebuild
echo "  Running: mvn clean install -DskipTests -Dlicense.skip=true -U"
if mvn clean install -DskipTests -Dlicense.skip=true -U > /tmp/netty-rebuild.log 2>&1; then
    echo -e "${GREEN}  ✓ Build successful${NC}"
else
    echo -e "${RED}  ✗ Build failed. Check /tmp/netty-rebuild.log${NC}"
    tail -30 /tmp/netty-rebuild.log
    exit 1
fi

# Step 2: Package complete OMB installation
echo -e "${YELLOW}Step 2: Creating complete OMB distribution package${NC}"

BUILD_DIR=$(find benchmark-framework/target -maxdepth 2 -type d -name "benchmark-framework-*" ! -name "*.jar" | head -1)

if [[ -z "$BUILD_DIR" ]]; then
    echo -e "${RED}  Error: Build directory not found${NC}"
    exit 1
fi

cd "$BUILD_DIR"
tar czf /tmp/omb-complete-fixed.tar.gz .

echo -e "${GREEN}  ✓ Package created: $(du -h /tmp/omb-complete-fixed.tar.gz | cut -f1)${NC}"

# Step 3: Deploy to ALL clients with exact same installation
echo -e "${YELLOW}Step 3: Deploying to all ${#CLIENTS[@]} clients${NC}"

for client_ip in "${CLIENTS[@]}"; do
    echo "  → $client_ip"

    # Stop any running workers/benchmarks
    ssh -i "$SSH_KEY" root@"$client_ip" "pkill -f java || true" >/dev/null 2>&1
    sleep 2

    # Remove old installation
    ssh -i "$SSH_KEY" root@"$client_ip" "rm -rf /opt/benchmark" >/dev/null 2>&1

    # Create fresh directory
    ssh -i "$SSH_KEY" root@"$client_ip" "mkdir -p /opt/benchmark" >/dev/null 2>&1

    # Copy complete package
    scp -q -i "$SSH_KEY" /tmp/omb-complete-fixed.tar.gz root@"$client_ip":/tmp/

    # Extract
    ssh -i "$SSH_KEY" root@"$client_ip" "cd /opt/benchmark && tar xzf /tmp/omb-complete-fixed.tar.gz && rm /tmp/omb-complete-fixed.tar.gz" >/dev/null 2>&1

    # Start worker
    ssh -i "$SSH_KEY" root@"$client_ip" "cd /opt/benchmark && nohup bin/benchmark-worker --port 8080 --stats-port 9091 > /tmp/worker.log 2>&1 & echo \$! > /tmp/worker.pid" >/dev/null 2>&1

    echo -e "${GREEN}    ✓ Deployed and started${NC}"
done

# Step 4: Validate
echo -e "${YELLOW}Step 4: Validating all workers${NC}"
echo "  Waiting 20 seconds for workers to initialize..."
sleep 20

FAILURES=0
for client_ip in "${CLIENTS[@]}"; do
    echo -n "  $client_ip: "

    if ssh -i "$SSH_KEY" root@"$client_ip" "curl -s --max-time 3 http://localhost:8080/stats >/dev/null 2>&1"; then
        # Check for errors in recent logs
        ERRORS=$(ssh -i "$SSH_KEY" root@"$client_ip" "tail -30 /tmp/worker.log | grep -i 'NoSuchMethodError\|NoClassDefFoundError' | wc -l")

        if [[ "$ERRORS" -eq 0 ]]; then
            echo -e "${GREEN}✓ healthy (no errors)${NC}"
        else
            echo -e "${YELLOW}⚠ responding but has $ERRORS errors${NC}"
            ((FAILURES++))
        fi
    else
        echo -e "${RED}✗ not responding${NC}"
        ((FAILURES++))
    fi
done

echo

if [[ $FAILURES -eq 0 ]]; then
    echo -e "${GREEN}=== Netty Fix Complete ===${NC}"
    echo -e "${GREEN}All workers healthy and error-free!${NC}"
    echo
    echo "OMB is now ready for benchmarking."
    exit 0
else
    echo -e "${YELLOW}=== Netty Fix Partially Successful ===${NC}"
    echo -e "${YELLOW}$FAILURES worker(s) still have issues.${NC}"
    echo
    echo "Check logs manually:"
    for client_ip in "${CLIENTS[@]}"; do
        echo "  ssh -i $SSH_KEY root@$client_ip 'tail -50 /tmp/worker.log'"
    done
    exit 1
fi
