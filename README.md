# Observability-Stack
## Summary of the AIO Installation Script

This bash script (`monsys-oss.sh`) performs a fully automated, single-host installation of a complete observability and monitoring stack using Docker Compose. It is designed for Debian-based Linux systems and requires root privileges.

### Main Steps Performed by the Script

1. **System Readiness Check**  
   - Verifies minimum hardware: ≥4 CPU cores, ≥20 GB RAM, ≥150 GB free disk  
   - Detects virtualization platform (e.g. KVM, VMware, VirtualBox)

2. **Optional Static IP Setup**  
   - Prompts user to configure a static IP via systemd-networkd (optional)

3. **Single Master Password Collection**  
   - Asks for one strong password (≥12 chars) used across all services  
   - Auto-generates a secure 20-character password if left blank  
     - Saves generated password to `/root/Services-Secrets.txt` (chmod 600)

4. **Timezone Selection**  
   - Prompts user to choose from common America/* timezones (default: America/Chicago)

5. **Docker & Compose Installation**  
   - Updates system packages  
   - Installs Docker CE + Compose plugin if not already present

6. **Project Setup**  
   - Creates directory `/opt/observability`  
   - Writes `docker-compose.yml` with all services, volumes, networks, healthchecks  
   - Creates Logstash configuration files in `./logstash/config` and `./logstash/pipeline`

7. **Service Definition & Startup**  
   - Defines five Docker services with healthchecks  
   - Pulls images quietly  
   - Starts stack with `docker compose up -d --wait --wait-timeout 300`  
   - Waits until all containers report healthy

8. **Finalization**  
   - Updates `/etc/motd` with access URLs, logins, and security notes  
   - Prints a final summary screen with URLs, next steps, and reminders

### Services Installed & Configured

| Service       | Image / Tag                                          | Main Purpose                                 | Exposed Ports       | Default Credentials                   | Persistent Volume                  |
|---------------|------------------------------------------------------|----------------------------------------------|---------------------|---------------------------------------|------------------------------------|
| OpenSearch    | opensearchproject/opensearch:3.5.0                   | Log/metrics storage & search backend         | 9200, 9300          | admin / master password               | opensearch-data, opensearch-backup |
| Logstash      | opensearchproject/logstash-oss-with-opensearch-output-plugin:latest | Ingests Beats data → OpenSearch              | 5044 (Beats), 9600 (API) | —                                     | — (config bind-mounted from host)  |
| Grafana       | grafana/grafana:latest                               | Dashboards, visualization, alerting          | 3000                | admin / master password               | grafana-data                       |
| CheckMK       | checkmk/check-mk-raw:2.4.0-2026.02.23                | Host/service monitoring & alerting           | 80 → 5000           | cmkadmin / master password            | checkmk-data                       |
| Portainer     | portainer/portainer-ce:alpine                        | Web UI to manage Docker containers           | 9000 (HTTP), 9443 (HTTPS) | Set on first login                    | portainer-data                     |

### Key Features & Characteristics

- Single master password used for simplicity during initial setup  
- All services run with healthchecks → startup waits for readiness  
- CheckMK uses default site `cmk` → web UI served at root `http://<ip>/`  
- Logstash configured to ingest Beats data and forward to OpenSearch with SSL disabled verification  
- No external dependencies beyond Docker  
- Security reminders in MOTD and final output (change passwords, restrict access)  
- Persistent data stored in named Docker volumes under `/var/lib/docker/volumes/`
