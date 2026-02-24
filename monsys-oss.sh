#!/usr/bin/env bash
# Copyright (C) 2026 RPE Consulting, LLC
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
#
# Full license text: https://www.gnu.org/licenses/old-licenses/gpl-2.0.txt

set -euo pipefail

LOG="/var/log/observability-build.log"
exec > >(tee -a "$LOG") 2>&1

#######################################
# Safety
#######################################
if [[ $EUID -ne 0 ]]; then
  echo "MUST BE RUN AS ROOT"
  exit 1
fi

#######################################
# Preflight hardware + hypervisor checks
#######################################
CPU_CORES=$(nproc)
MEM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)
DISK_GB=$(df -BG / | awk 'NR==2 {gsub("G","",$2); print $2}')
HYPERVISOR=$(systemd-detect-virt || echo "unknown")
echo "Detected platform: $HYPERVISOR"
echo "Detected CPU cores: $CPU_CORES"
echo "Detected RAM: ${MEM_GB}GB"
echo "Detected disk: ${DISK_GB}GB"
(( CPU_CORES >= 4 )) || { echo "ERROR: Need 4+ CPU cores"; exit 1; }
(( MEM_GB > 20 )) || { echo "ERROR: Need more than 20GB RAM"; exit 1; }
(( DISK_GB >= 150 )) || { echo "ERROR: Need 150GB+ disk"; exit 1; }

#######################################
# Static IP Prompt
#######################################
read -rp "Configure static IP? (y/N): " SETIP
if [[ "${SETIP,,}" == "y" ]]; then
  read -rp "Interface (e.g. eth0): " IFACE
  read -rp "Static IP (CIDR): " IPADDR
  read -rp "Gateway: " GW
  read -rp "DNS (comma-separated): " DNS
  mkdir -p /etc/systemd/network
  cat > /etc/systemd/network/10-static.network <<EOF
[Match]
Name=$IFACE
[Network]
Address=$IPADDR
Gateway=$GW
DNS=${DNS//,/ }
EOF
  systemctl enable systemd-networkd
  systemctl restart systemd-networkd
fi

#######################################
# Password setup - SINGLE MASTER PASSWORD FOR ALL SERVICES
#######################################
echo ""
echo "=== Password Configuration ==="
echo "All services (OpenSearch, Grafana, CheckMK, Logstash) will use THE SAME password."
echo "Provide a strong password (min 12 chars) or leave empty to auto-generate a secure 20-char one."
echo ""
generate_pw() {
  openssl rand -base64 24 | tr -d '/+=' | cut -c1-20
}
read -s -r -p "Master password for ALL services (empty = auto-generate): " MASTER_PW
echo ""
if [[ -z "$MASTER_PW" ]]; then
  MASTER_PW=$(generate_pw)
  echo "Generated master password (used for ALL services): $MASTER_PW"
  echo "SAVE THIS SECURELY NOW! You will need it to log in."
  GENERATED=true
else
  read -s -r -p "Confirm master password: " CONFIRM
  echo ""
  [[ "$MASTER_PW" != "$CONFIRM" ]] && { echo "Passwords do not match."; exit 1; }
  [[ ${#MASTER_PW} -lt 12 ]] && { echo "Error: Password must be at least 12 characters."; exit 1; }
  GENERATED=false
fi

#######################################
# Timezone setup - America/ only
#######################################
echo ""
echo "=== Timezone Configuration ==="
echo "Select the timezone for all Docker containers."
echo ""
echo "1) America/New_York"
echo "2) America/Chicago"
echo "3) America/Denver"
echo "4) America/Los_Angeles"
echo "5) America/Phoenix"
echo "6) America/Anchorage"
echo "7) Pacific/Honolulu"
echo "8) America/Indiana/Indianapolis"
echo "9) America/Detroit"
echo ""
while true; do
  read -rp "Enter number (1-9) [default: 2 (America/Chicago)]: " TZ_CHOICE
  TZ_CHOICE="${TZ_CHOICE:-2}"
  case "$TZ_CHOICE" in
    1) SELECTED_TZ="America/New_York" ;;
    2) SELECTED_TZ="America/Chicago" ;;
    3) SELECTED_TZ="America/Denver" ;;
    4) SELECTED_TZ="America/Los_Angeles" ;;
    5) SELECTED_TZ="America/Phoenix" ;;
    6) SELECTED_TZ="America/Anchorage" ;;
    7) SELECTED_TZ="Pacific/Honolulu" ;;
    8) SELECTED_TZ="America/Indiana/Indianapolis" ;;
    9) SELECTED_TZ="America/Detroit" ;;
    *) echo "Invalid choice. Please enter 1-9."; continue ;;
  esac
  break
done
echo "Selected timezone: $SELECTED_TZ"

#######################################
# Docker image versions
#######################################
OPENSEARCH_TAG="3.5.0"
LOGSTASH_TAG="latest"   
GRAFANA_TAG="latest"
CHECKMK_TAG="2.4.0-2026.02.23"

#######################################
# Install Docker & Compose
#######################################
apt update && apt upgrade -y
apt install -y curl ca-certificates gnupg lsb-release jq openssl
if ! command -v docker >/dev/null; then
  echo "[*] Installing Docker..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

#######################################
# Create project directory and files
#######################################
mkdir -p /opt/observability
cd /opt/observability

# Dump password if generated
if [[ "$GENERATED" == true ]]; then
  cat > /root/Services-Secrets.txt <<EOF
Generated Master Password - $(date '+%Y-%m-%d %H:%M:%S %Z')
============================================================
This password is used for ALL services:
- OpenSearch admin[](https://your-ip:9200)
- Grafana admin[](http://your-ip:3000)
- CheckMK admin[](http://your-ip/)
- Logstash → OpenSearch output
Master password: ${MASTER_PW}
WARNING:
- CHANGE ALL PASSWORDS IMMEDIATELY after first login!
- OpenSearch password only applies on first boot (empty volume).
- Delete this file after saving securely.
EOF
  chmod 600 /root/Services-Secrets.txt
  echo "Master password written to /root/Services-Secrets.txt (review and delete after use!)"
else
  echo "Password was user-provided (no auto-dump created)."
fi

# docker-compose.yml with Logstash image fixed + previous healthcheck improvements
cat > docker-compose.yml <<EOF
services:
  opensearch:
    image: opensearchproject/opensearch:${OPENSEARCH_TAG}
    container_name: opensearch
    environment:
      - TZ=${SELECTED_TZ}
      - cluster.name=opensearch-cluster
      - node.name=opensearch
      - discovery.type=single-node
      - bootstrap.memory_lock=true
      - "OPENSEARCH_JAVA_OPTS=-Xms8g -Xmx8g"
      - plugins.security.disabled=false
      - OPENSEARCH_INITIAL_ADMIN_PASSWORD=${MASTER_PW}
    ulimits:
      memlock: -1
      nofile: 65536
    volumes:
      - opensearch-data:/usr/share/opensearch/data
      - opensearch-backup:/usr/share/opensearch/backups
    ports:
      - "9200:9200"
      - "9300:9300"
    healthcheck:
      test: ["CMD-SHELL", "curl -s -f -k -u admin:${MASTER_PW} https://localhost:9200/_cluster/health | grep -q '\"status\":\"green\"' || grep -q '\"status\":\"yellow\"'"]
      interval: 15s
      timeout: 10s
      retries: 8
      start_period: 60s
    networks: [observability-net]

  logstash:
    image: opensearchproject/logstash-oss-with-opensearch-output-plugin:${LOGSTASH_TAG}
    container_name: logstash
    depends_on:
      opensearch:
        condition: service_healthy
    environment:
      - TZ=${SELECTED_TZ}
      - "LS_JAVA_OPTS=-Xmx2g -Xms2g"
    volumes:
      - ./logstash/config/logstash.yml:/usr/share/logstash/config/logstash.yml:ro
      - ./logstash/pipeline:/usr/share/logstash/pipeline:ro
    ports:
      - "5044:5044"
      - "9600:9600"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9600/_node/pipelines"]
      interval: 20s
      timeout: 5s
      retries: 5
      start_period: 30s
    restart: unless-stopped
    networks: [observability-net]

  grafana:
    image: grafana/grafana:${GRAFANA_TAG}
    container_name: grafana
    depends_on:
      opensearch:
        condition: service_healthy
    environment:
      - TZ=${SELECTED_TZ}
      - GF_SECURITY_ADMIN_PASSWORD=${MASTER_PW}
      - GF_INSTALL_PLUGINS=grafana-clock-panel,grafana-worldmap-panel,checkmk-cloud-datasource
    ports:
      - "3000:3000"
    volumes:
      - grafana-data:/var/lib/grafana
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:3000/api/health"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    networks: [observability-net]

  checkmk:
    image: checkmk/check-mk-raw:${CHECKMK_TAG}
    container_name: checkmk
    environment:
      - TZ=${SELECTED_TZ}
      - CMK_PASSWORD=${MASTER_PW}
    ulimits:
      nofile: 1024
    tmpfs:
      - /opt/omd/sites/cmk/tmp:uid=1000,gid=1000
    volumes:
      - checkmk-data:/omd/sites
      - /etc/localtime:/etc/localtime:ro
    ports:
      - "80:5000"
    healthcheck:
      test: ["CMD-SHELL", "curl -s -o /dev/null -w '%{http_code}' http://localhost:5000/ | grep -q '^302$' || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 12
      start_period: 120s
    networks: [observability-net]

  portainer:
    image: portainer/portainer-ce:alpine
    container_name: portainer
    restart: unless-stopped
    environment:
      - TZ=${SELECTED_TZ}
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer-data:/data
    ports:
      - "9000:9000"
      - "9443:9443"
    healthcheck:
      test: ["CMD", "nc", "-z", "localhost", "9000"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 15s
    networks: [observability-net]

volumes:
  opensearch-data:
  opensearch-backup:
  grafana-data:
  checkmk-data:
  portainer-data:

networks:
  observability-net:
    driver: bridge
EOF

# Logstash config files
mkdir -p /opt/observability/logstash/config logstash/pipeline
cat > /opt/observability/logstash/config/logstash.yml <<'EOF'
http.host: "0.0.0.0"
EOF
cat > /opt/observability/logstash/pipeline/logstash.conf <<EOF
input { beats { port => 5044 } }
output {
  opensearch {
    hosts => ["https://opensearch:9200"]
    user => "admin"
    password => "${MASTER_PW}"
    ssl => true
    ssl_certificate_verification => false
    index => "%{[@metadata][beat]}-%{+YYYY.MM.dd}"
  }
}
EOF

#######################################
# Pull & Start with health wait
#######################################
echo "[*] Pulling Docker images..."
docker compose pull --quiet || { echo "[ERROR] Image pull failed"; exit 1; }

echo "[*] Starting services and waiting until they are healthy..."
echo " This may take 2–5 minutes (especially first run with OpenSearch & CheckMK)"

docker compose up -d --wait --wait-timeout 300 || {
  echo "[ERROR] Services did not become healthy within 5 minutes."
  echo "Check status and logs:"
  docker compose ps
  echo ""
  docker compose logs --tail=50
  exit 1
}

echo "[OK] All services are healthy or running."

# Inform about CheckMK access
echo "[*] CheckMK default site 'cmk' auto-created by container."
echo "    Access UI at: http://$(hostname -I | awk '{print $1}')/   (login: cmkadmin / your master password)"

#######################################
# MOTD
#######################################
IP=$(hostname -I | awk '{print $1}' | head -n1 || echo "your-server-ip")
cat > /etc/motd <<EOF
================================================================================
          Observability Stack (OpenSearch + Grafana + CheckMK + Logstash)
================================================================================
Hostname: $(hostname)
Primary IP: $IP
Timezone: $SELECTED_TZ
Services (ALL use the SAME password - admin / your master password):
  Grafana:        http://$IP:3000
  CheckMK:        http://$IP              (cmkadmin / password)
  OpenSearch:     https://$IP:9200
  Logstash beats: $IP:5044
  Portainer:      http://$IP:9000         (or https://$IP:9443 if configured)
Security Notes - CRITICAL:
- CHANGE ALL PASSWORDS IMMEDIATELY after first login!
- OpenSearch password only sets on FIRST boot (empty data volume)
- Re-running script won't change OpenSearch password unless volume is wiped
- Password stored in /opt/observability/docker-compose.yml
- If generated: /root/Services-Secrets.txt → delete after use
- No host firewall → use VLAN / upstream protection
Logs: cd /opt/observability && docker compose logs -f <service>
Build log: $LOG
================================================================================
EOF
chmod 644 /etc/motd

#######################################
# Final summary
#######################################
echo ""
echo "======================================"
echo " OBSERVABILITY STACK READY"
echo " (All services share same password)"
echo "======================================"
echo ""
echo "Access points:"
echo " • Grafana     → http://$IP:3000               (admin / password)"
echo " • CheckMK     → http://$IP                    (cmkadmin / password)"
echo " • OpenSearch  → https://$IP:9200              (admin / password)"
echo " • Logstash    → $IP:5044                      (beats input)"
echo " • Portainer   → http://$IP:9000               (or https://$IP:9443)"
echo ""
echo "Next steps:"
echo "  1. Log into each service → CHANGE passwords immediately"
echo "  2. OpenSearch: use Dev Tools or security API to update admin password"
echo "  3. Verify Logstash: docker logs logstash"
echo "  4. Delete /root/Services-Secrets.txt if generated"
echo "  5. Secure access (VLAN, firewall, HTTPS proxy recommended)"
echo ""
echo "Grafana plugins installed:"
echo " • grafana-clock-panel"
echo " • grafana-worldmap-panel"
echo " • checkmk-cloud-datasource"
echo ""
echo "Manage stack: cd /opt/observability && docker compose [up -d | down | logs -f]"
echo "======================================"
