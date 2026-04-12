# Home Server — Kubernetes Architecture

## Overview

This directory contains Kubernetes manifests that replicate (and improve upon) the
Docker Compose-based home server. All services run in a single `server` namespace,
managed by Traefik as the ingress controller with CrowdSec for security.

## Architecture Diagram

```
                        ┌─────────────────────────────────────────────┐
                        │              Internet (HTTPS :443)          │
                        └────────────────────┬────────────────────────┘
                                             │
                        ┌────────────────────▼────────────────────────┐
                        │         Traefik (Ingress Controller)        │
                        │   ┌─────────────┐  ┌────────────────────┐  │
                        │   │ ACME/Porkbun│  │ Plugins            │  │
                        │   │ Let'sEncrypt│  │ • CrowdSec Bouncer │  │
                        │   └─────────────┘  │ • Shorty (URLs)    │  │
                        │                    └────────────────────┘  │
                        └──┬───────┬──────┬──────┬──────┬──────┬─────┘
                           │       │      │      │      │      │
              ┌────────────▼──┐ ┌──▼───┐ ┌▼────┐ ┌▼────┐ ┌▼───┐ ┌▼────────┐
              │  Paperless    │ │Vault-│ │Mea- │ │Upti-│ │d-f │ │ Plant-it │
              │  paperless.   │ │warden│ │lie  │ │me   │ │.dev│ │plants.d- │
              │  d-f.dev      │ │pw.d- │ │food.│ │Kuma │ │    │ │f.dev     │
              │  :8000        │ │f.dev │ │d-f. │ │     │ │    │ │:3000/:80 │
              │               │ │:80   │ │dev  │ │:3001│ │    │ │80        │
              │  ┌──────────┐ │ └──┬───┘ │:9000│ └──┬──┘ └────┘ └────┬────┘
              │  │Gotenberg │ │    │     └──┬──┘    │                 │
              │  │Tika      │ │    │        │       │                 │
              │  └──────────┘ │    │        │       │                 │
              └───────┬───────┘    │        │       │                 │
                      │            │        │       │                 │
         ┌────────────▼────────────▼────────▼───────▼─────────────────▼──┐
         │                     Shared Infrastructure                     │
         │  ┌──────────────┐  ┌──────────┐  ┌───────┐  ┌─────────────┐  │
         │  │ PostgreSQL   │  │ MariaDB  │  │ Redis │  │  CrowdSec   │  │
         │  │ • paperless  │  │ • bootdb │  │       │  │  (Security) │  │
         │  │ • mealie     │  │(plant-it)│  │       │  │             │  │
         │  └──────────────┘  └──────────┘  └───────┘  └─────────────┘  │
         └──────────────────────────────────────────────────────────────┘

         ┌──────────────────────────────────────────────────────────────┐
         │  Monitoring                                                  │
         │  ┌────────────────┐  ┌────────────────┐  ┌───────────────┐  │
         │  │ Prometheus     │  │ Node Exporter  │  │ Grafana       │  │
         │  │ metrics store  │  │ (DaemonSet)    │  │ dashboards +  │  │
         │  │ 90d retention  │  │ host metrics   │  │ alerting      │  │
         │  └────────────────┘  └────────────────┘  └───────────────┘  │
         └──────────────────────────────────────────────────────────────┘

         ┌──────────────────────────────────────────────────────────────┐
         │  Backup CronJob (daily 4:00 AM)                             │
         │  pg_dump + mariadb-dump → tar.gz → GPG encrypt → rclone       │
         └──────────────────────────────────────────────────────────────┘
```

## Key Changes from Docker Compose

| Aspect | Docker Compose | Kubernetes |
|---|---|---|
| **Databases** | 2× PostgreSQL + 1× MySQL | 1× PostgreSQL (shared) + 1× MariaDB |
| **Redis** | 2× Redis (paperless + plant-it) | 1× shared Redis instance |
| **Ingress** | Traefik container + dynamic config file | Traefik Deployment + IngressRoute CRDs |
| **TLS** | Traefik ACME (file-based) | Traefik ACME (PVC-based) |
| **Security** | CrowdSec + Traefik plugin | Same, via shared log PVC |
| **Secrets** | `.env` files | Kubernetes Secrets |
| **Storage** | Docker volumes / bind mounts | PersistentVolumeClaims |
| **Backup** | docker-volume-backup | CronJob with pg_dump/mariadb-dump + rclone |
| **Health** | Docker restart policies | Liveness/readiness probes + resource limits |

## Directory Structure

```
├── namespace.yaml                         # server namespace
├── kustomization.yaml                     # Kustomize manifest
├── setup.sh                               # Interactive deployment script
│
├── infrastructure/
│   ├── postgresql/
│   │   ├── postgresql.yaml                # StatefulSet + Service + init ConfigMap
│   │   └── secret.example.yaml
│   ├── mariadb/
│   │   ├── mariadb.yaml                   # StatefulSet + Service
│   │   └── secret.example.yaml
│   ├── redis/
│   │   └── redis.yaml                     # Deployment + Service + PVC
│   ├── traefik/
│   │   ├── rbac.yaml                      # ServiceAccount + ClusterRole
│   │   ├── configmap.yaml                 # Traefik static config
│   │   ├── traefik.yaml                   # Deployment + Service + PVCs
│   │   ├── middlewares.yaml               # CrowdSec, status-redirect, shorty
│   │   ├── ingressroute-shorty.yaml       # d-f.dev URL shortener
│   │   └── secret.example.yaml
│   ├── authentik/
│   │   ├── authentik.yaml                 # Server + Worker Deployments + ConfigMap
│   │   ├── middleware.yaml                # Traefik forward-auth middleware
│   │   ├── ingressroute.yaml              # auth.d-f.dev
│   │   └── secret.example.yaml
│   ├── headscale/
│   │   ├── headscale.yaml                 # Deployment + Service + PVC + ConfigMap
│   │   └── ingressroute.yaml              # headscale.d-f.dev
│   ├── prometheus/
│   │   ├── prometheus.yaml                # Deployment + Service + RBAC + ConfigMap
│   │   └── node-exporter.yaml             # DaemonSet for host metrics
│   ├── grafana/
│   │   ├── grafana.yaml                   # Deployment + Service + dashboards
│   │   ├── ingressroute.yaml              # grafana.d-f.dev
│   │   └── secret.example.yaml
│   ├── crowdsec/
│       └── crowdsec.yaml                  # Deployment + Service + PVCs
│   └── flux/
│       ├── source.yaml                    # GitRepository (polls repo)
│       └── sync.yaml                      # Kustomization (reconciles cluster)
│
├── apps/
│   ├── paperless/                         # Deployment, Gotenberg, Tika, IngressRoute
│   ├── vaultwarden/                       # Deployment, IngressRoute
│   ├── mealie/                            # Deployment, IngressRoute
│   ├── uptime-kuma/                       # Deployment, IngressRoute
│   ├── plant-it/                          # Deployment, IngressRoute
│   └── home-assistant/                    # Deployment, IngressRoute
│
├── backup/
│   ├── backup.yaml                        # CronJob + backup script ConfigMap
│   └── secret.example.yaml
│
└── policies/
    ├── default-deny.yaml                  # Deny all ingress by default
    ├── databases.yaml                     # PostgreSQL, MariaDB, Redis access
    ├── infrastructure.yaml                # Traefik, CrowdSec, Authentik, Headscale access
    ├── apps.yaml                          # App service access
    └── monitoring.yaml                    # Prometheus, Grafana, Node Exporter access
```

## Services & Routing

| Domain | Service | Port |
|---|---|---|
| `paperless.d-f.dev` | paperless | 8000 |
| `pw.d-f.dev` | vaultwarden | 80 |
| `food.d-f.dev` | mealie | 9000 |
| `uptime.d-f.dev` | uptime-kuma | 3001 |
| `status.d-f.dev` | uptime-kuma | 3001 (redirects `/` → `/status/`) |
| `plants.d-f.dev` | plant-it | 3000 (frontend), 8080 (API) |
| `home.d-f.dev` | home-assistant | 8123 |
| `auth.d-f.dev` | authentik | 9000 |
| `headscale.d-f.dev` | headscale | 8080 |
| `grafana.d-f.dev` | grafana | 3000 |
| `d-f.dev` | noop (shorty) | — (URL shortener middleware) |

All routes pass through the CrowdSec bouncer middleware and use Let's Encrypt
TLS certificates issued via Porkbun DNS challenge.

## Network Policies

All ingress traffic is denied by default. Each service has explicit policies:

```
Internet → Traefik (:443)
  Traefik → apps (paperless, vaultwarden, mealie, uptime-kuma, plant-it, home-assistant)
  Traefik → infrastructure (authentik, headscale, grafana, crowdsec)

Paperless → PostgreSQL, Redis, Gotenberg, Tika
Mealie → PostgreSQL
Plant-it → MariaDB, Redis
Authentik → PostgreSQL, Redis
Grafana → Prometheus
Prometheus → node-exporter, traefik:8082, DB exporters, crowdsec:6060
Backup → PostgreSQL, MariaDB
```

## Image Updates (Renovate) & GitOps (Flux CD)

[Renovate](https://docs.renovatebot.com/) is configured via `renovate.json` in
the repo root. Install the [Renovate GitHub App](https://github.com/apps/renovate)
on this repo and it will automatically create PRs for image updates.

- **Patch/minor** updates auto-merge (except databases and security)
- **Major** updates require manual review
- Updates are grouped by category (databases, monitoring, security)
- Runs on weekends to avoid mid-week disruptions

[Flux CD](https://fluxcd.io/) watches this repository and auto-reconciles
the cluster whenever changes are merged to `main`. This means Renovate PRs
that auto-merge will be deployed automatically within minutes.

- Source: `infrastructure/flux/source.yaml` — polls the repo every 1 minute
- Sync: `infrastructure/flux/sync.yaml` — reconciles every 10 minutes
- SOPS decryption is handled natively by Flux (age key in `flux-system/sops-age` secret)
- Run `flux get all` to check reconciliation status
- Run `flux reconcile kustomization server` to trigger an immediate sync

## Prerequisites

- **Kubernetes cluster** — [k3s](https://k3s.io) recommended for home servers
- **kubectl** — configured to connect to your cluster
- **Traefik CRDs** — installed (k3s includes Traefik by default)
- **sops + age** — for secret management (`brew install sops age`)
- **flux** — for GitOps (`brew install fluxcd/tap/flux`)
- **DNS** — `*.d-f.dev` pointing to your cluster's external IP

## Secret Management (SOPS + age)

Secrets are encrypted with [SOPS](https://github.com/getsops/sops) using
[age](https://github.com/FiloSottile/age) keys, so they can safely live in git.

**First-time setup:**
```bash
# Install tools
brew install sops age

# Generate an age keypair
age-keygen -o keys.txt
# Output: public key age1abc...

# Put the PUBLIC key in .sops.yaml
# Back up keys.txt in Vaultwarden (this is the ONLY thing you need to recover)
```

**Daily workflow:**
```bash
# Create secrets from templates
for f in $(find . -name 'secret.example.yaml'); do
  cp "$f" "${f%.example.yaml}.yaml"
done
# Edit each secret.yaml with real values

# Encrypt all secrets (safe to commit)
./secrets.sh encrypt

# Check status
./secrets.sh status

# Decrypt for editing
./secrets.sh decrypt
```

**Disaster recovery:** Clone the repo + `keys.txt` → all secrets are restored.

## Quick Start

```bash
# 1. Create secrets from templates
for f in $(find . -name 'secret.example.yaml'); do
  cp "$f" "${f%.example.yaml}.yaml"
done
# Edit each secret.yaml with real values

# 2. Encrypt secrets
./secrets.sh encrypt

# 3. Generate a deploy key for Flux
ssh-keygen -t ed25519 -f ~/.ssh/flux_deploy_key -N ''
# Add the public key as a deploy key in GitHub repo settings (Settings → Deploy keys)

# 4. Run the setup script
chmod +x setup.sh
./setup.sh

# 5. Verify
kubectl -n server get pods
flux get all
```

## Dedicated Pi Worker Node

To keep the Raspberry Pi reserved for Pi-only workloads, use `pi_agent_quickstart.sh`. It now installs Tailscale, joins the Pi to the self-hosted Headscale control plane, writes `/etc/rancher/k3s/config.yaml` with the Pi label and taint, installs the k3s agent, and enables both `tailscaled` and `k3s-agent` so the Pi reconnects automatically on boot.

### 1. Create a Headscale user and reusable auth key

Run these from a machine that already has `kubectl` access to the cluster:

```bash
kubectl -n server exec deploy/headscale -- headscale users create home
kubectl -n server exec deploy/headscale -- headscale users list
kubectl -n server exec deploy/headscale -- headscale preauthkeys create --user <numeric-user-id> --reusable
```

If `home` already exists, do not recreate it; just use its numeric ID from `headscale users list` when creating the key. Save the generated auth key. You will use it for both the hosted server and the Pi.

### 2. Join the hosted server to Headscale

Install Tailscale on the hosted server, connect it to `headscale.d-f.dev`, and note its Tailscale IP:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
sudo tailscale up --login-server=https://headscale.d-f.dev --authkey <preauth-key>
sudo tailscale ip -4
```

### 3. Add the hosted server's Tailscale address to k3s

Merge the hosted server's Tailscale IP or DNS name into the existing k3s server config so the API certificate is valid over Tailscale too:

```yaml
# /etc/rancher/k3s/config.yaml on the hosted server
tls-san:
  - d-f.dev
  - <server-tailscale-ip-or-dns>
```

Then restart k3s:

```bash
sudo systemctl restart k3s
```

### 4. Join the Pi

Get the cluster token from the existing k3s server node:

```bash
cat /var/lib/rancher/k3s/server/node-token
```

Then run the quickstart script on the Pi as root. It will prompt for the Headscale auth key, the hosted server's Tailscale IP or DNS name, and the k3s token:

```bash
sudo ./pi_agent_quickstart.sh
```

If the script reports that it enabled memory cgroups in `/boot/firmware/cmdline.txt` or `/boot/cmdline.txt`, reboot the Pi once and run the script again. That Raspberry Pi OS kernel setting is required before `k3s-agent` can start.

The script hardcodes these cluster-specific settings and discovers the Pi's Tailscale IPv4 address automatically for the node registration:

```yaml
login-server: https://headscale.d-f.dev
node-ip: <detected tailscale IPv4>
node-external-ip: <detected tailscale IPv4>
flannel-iface: tailscale0
kubelet-arg:
  - node-ip=<detected tailscale IPv4>
node-label:
  - server.d-f.dev/node-role=pi
node-taint:
  - server.d-f.dev/node-role=pi:NoSchedule
```

If `kubectl logs`, `kubectl exec`, or ingress traffic to Pi-hosted apps fails, rerun `sudo ./pi_agent_quickstart.sh` on the Pi or update `/etc/rancher/k3s/config.yaml` there so `node-ip`, `node-external-ip`, and `kubelet-arg: node-ip=...` all use the detected Tailscale IPv4, then restart `k3s-agent`. From the hosted server, verify kubelet reachability with `curl -sk https://<pi-tailscale-ip>:10250/healthz`.

Normal workloads will avoid the Pi automatically because of the taint. Pi-only workloads should add both a selector and a matching toleration, as shown in `apps/pi-health/pi-health.yaml`.

## Operations

```bash
# View logs for a service
kubectl -n server logs deploy/paperless -f

# Restart a deployment
kubectl -n server rollout restart deploy/mealie

# Scale a service (e.g., for maintenance)
kubectl -n server scale deploy/vaultwarden --replicas=0

# Trigger manual backup
kubectl -n server create job --from=cronjob/backup manual-backup

# Check backup job status
kubectl -n server get jobs -l app.kubernetes.io/name=backup

# View resource usage
kubectl -n server top pods
```

## Storage

Most persistent data uses PersistentVolumeClaims with the default StorageClass.
On k3s, this is the `local-path-provisioner` which stores data on the node at
`/var/lib/rancher/k3s/storage/`. Uptime Kuma uses a `hostPath` volume instead.

| Volume | Size | Used By |
|---|---|---|
| `data` (StatefulSet) | 10Gi | PostgreSQL |
| `data` (StatefulSet) | 5Gi | MariaDB |
| `redis-data` | 1Gi | Redis |
| `paperless-data` | 5Gi | Paperless |
| `paperless-media` | 10Gi | Paperless |
| `paperless-export` | 5Gi | Paperless |
| `paperless-consume` | 1Gi | Paperless |
| `vaultwarden-data` | 1Gi | Vaultwarden |
| `mealie-data` | 5Gi | Mealie |
| `hostPath /data/uptime-kuma` | — | Uptime Kuma |
| `plant-it-data` | 2Gi | Plant-it |
| `home-assistant-data` | 5Gi | Home Assistant |
| `prometheus-data` | 10Gi | Prometheus (90d metrics) |
| `grafana-data` | 2Gi | Grafana |
| `traefik-acme` | 100Mi | Traefik (certificates) |
| `traefik-logs` | 1Gi | Traefik → CrowdSec |
| `crowdsec-data` | 2Gi | CrowdSec |
| `crowdsec-config` | 1Gi | CrowdSec |
| `backup-storage` | 40Gi | Backup CronJob |
