# Runbook –  Observability Stack  
**Deployment method**: Docker Compose (single host)  
**GNU/Linux OS**: Debian 11,12,13  
**Shell**: BASH  
**Location on host**: `/opt/observability`  
**Services**:  
- **OpenSearch** ? storage, indexing, search (port 9200)  
- **Logstash** ? data ingestion pipeline (Beats input on 5044)  
- **Grafana** ? dashboards, visualization (port 3000)  
- **CheckMK** ? infrastructure & service monitoring/alerting (port 80 ? root path)  
- **Portainer** ? Docker container management (ports 9000/9443)

**Last updated**: February 23, 2026  
**Assumptions**:  
- All services share the same master password (changed after first login)  
- Stack installed via the custom bash script  
- No external reverse proxy or SSL termination yet (self-signed for OpenSearch)

## 1. Quick Status & Health Overview
All the below commands are copy & paste friendly  
For all commands, you must be in the stack directory.  
From the command line run
`cd /opt/observability`

### Simple Checks  
#### All containers + status/health
docker compose ps
#### Detailed health (running / healthy / starting / unhealthy)
docker inspect --format '{{.Name}} {{json .State.Health.Status}}' $(docker compose ps -q)
#### One-liner Services Summary
docker compose ps --format "table {{.Name}}\t{{.State}}\t{{.Health}}"  
#### Resource usage
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"
#### Disk usage of volumes
docker system df -v | grep -A 10 observability  
#### Quick error scan (last 5–10 minutes)  
Bashdocker compose logs --since 10m | grep -i -E "error|warn|fail|exception|401|403|500|panic|crash"
## 2. Access & Login Information

| Service       | URL                              | Username       | Password              | Notes / First-time actions                          |
|---------------|----------------------------------|----------------|-----------------------|-----------------------------------------------------|
| Grafana       | http://host-ip:3000            | admin          | master password       | add OpenSearch datasource |
| CheckMK       | http://host-ip/                | cmkadmin       | master password       | install agents from UI        |
| OpenSearch    | https://host-ip:9200           | admin          | master password       |   |
| Logstash      | tcp/udp host-ip:5044           | —              | —                     | Beats/Winlogbeat/Filebeat input                     |
| Portainer     | http://host-ip:9000            | first login               | first login    | https://host-ip:9443 for TLS            |

# 3. Daily / Weekly Operations
### Get logs for specific services
docker compose logs -f logstash  
docker compose logs -f opensearch  
docker compose logs -f checkmk    

**You can also use the Portainer Service to view logs**
## CheckMK/Logstash/Grafana Issues
#### Restart individual services
docker compose restart \<service name\>  
### Full stack restart (graceful)
docker compose down  
docker compose up -d --wait --wait-timeout 300
## Verify Logstash ingestion
docker logs logstash | grep -i -E "beats|event|indexing|published|acked"  
docker logs --since 5m logstash | wc -l  
### Count recent log lines (high = good activity)
docker logs --since 5m logstash | wc -l
### Cluster health (green/yellow/red)
curl -k -u admin:"your-password" https://localhost:9200/_cluster/health?pretty

### List indices (look for recent beats-* or logstash-*)
curl -k -u admin:"your-password" https://localhost:9200/_cat/indices?v

### Document count in a recent index
curl -k -u admin:"your-password" https://localhost:9200/logstash-*/_count?pretty

### List indices (look for recent beats-* or logstash-*)
curl -k -u admin:"your-password" https://localhost:9200/_cat/indices?v

### Document count in a recent index
curl -k -u admin:"your-password" https://localhost:9200/logstash-*/_count?pretty
## CheckMK site & agent status
### Site processes
docker exec checkmk omd status   # all should be "running"

### List sites (should show cmk)
docker exec checkmk omd sites

### Check agent connectivity (from CheckMK UI or CLI)
docker exec checkmk cmk -l   # lists monitored hosts


## Backup (weekly or before changes)
cd /opt/observability  
docker compose down  
tar -czf /root/observability-full-$(date +%Y%m%d-%H%M).tar.gz \  
  /var/lib/docker/volumes/observability_* \  
  /opt/observability  
docker compose up -d --wait  

* Store backups off-host (USB, NAS, cloud)
* Test restore periodically in a test VM

# 4. Troubleshooting & Recovery

### Common problems & fixes

| Symptom                              | Likely cause                              | Diagnostic commands                              | Fix / Action                                      |
|--------------------------------------|-------------------------------------------|--------------------------------------------------|---------------------------------------------------|
| Logstash container exits / restarts  | Password mismatch, SSL handshake, config  | `docker logs logstash --tail 200`                | Wipe OpenSearch volume ? re-run install script    |
| CheckMK shows blank page / 500       | Apache or site not fully ready            | `docker logs checkmk | tail -100`              | Wait longer; check `omd status` inside container  |
| Grafana OpenSearch datasource fails  | Wrong URL/creds/SSL                       | Test: `curl -k -u admin:pass https://localhost:9200` | Use `https://opensearch:9200`, skip TLS verify   |
| No data in OpenSearch                | Beats not reaching Logstash               | `netstat -tuln | grep 5044`<br>`docker logs logstash` | Verify agent config; check firewall               |
| High memory / OOM kills              | Java heap too small for workload          | `docker stats`                                   | Increase `-Xmx4g -Xms4g` in LS_JAVA_OPTS          |
| Portainer inaccessible               | Port conflict / first-login not done      | `docker logs portainer`                          | Access http://<ip>:9000 and set admin password    |

### Emergency full reset (last resort – **loses all data**)


`cd /opt/observability`  
`docker compose down --volumes --remove-orphans`  
`rm -rf /opt/observability/*`   

Re-run original install script  

## 5. Maintenance & Upgrades

### Image / version upgrade

Not Implemented - future update

### Performance tuning

* Logstash: Increase heap ? `-Xmx4g -Xms4g` if ingesting high volume  
* OpenSearch: Increase JVM heap in env: `-Xms12g -Xmx12g` (if host has 32+ GB RAM)  
* CheckMK: Monitor tmpfs usage ? `docker exec checkmk df -h /opt/omd/sites/cmk/tmp`
## 6. Additional Best Practices

- **Password management**: Change all service passwords post-install (Grafana UI, CheckMK UI, OpenSearch API)
- **Agent deployment**: From CheckMK ? Setup ? Agents ? Download agent packages (Linux/Windows)
- **Grafana setup**:
  - Add OpenSearch datasource: URL `https://opensearch:9200`, skip TLS verify, basic auth admin/password
  - Import dashboards: Search community for "OpenSearch" or "CheckMK datasource"
- **Alerts & notifications**:
  - CheckMK: Events ? Rules ? Create notification rules (email/Slack/PagerDuty)
  - Grafana: Alerting ? Alert rules ? Create rules on OpenSearch queries
- **Security hardening**:
  - Use reverse proxy (Nginx/Traefik) with Let's Encrypt HTTPS
  - Restrict hosts and ports using upstream firewall
  - Enable OpenSearch audit logging if needed
