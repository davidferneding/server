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
         │  │ PostgreSQL   │  │  MySQL   │  │ Redis │  │  CrowdSec   │  │
         │  │ • paperless  │  │ • bootdb │  │       │  │  (Security) │  │
         │  │ • mealie     │  │(plant-it)│  │       │  │             │  │
         │  └──────────────┘  └──────────┘  └───────┘  └─────────────┘  │
         └──────────────────────────────────────────────────────────────┘

         ┌──────────────────────────────────────────────────────────────┐
         │  Monitoring & Logging                                        │
         │  ┌────────────────┐  ┌────────────────┐  ┌───────────────┐  │
         │  │ Prometheus     │  │ Node Exporter  │  │ Grafana       │  │
         │  │ metrics store  │  │ (DaemonSet)    │  │ dashboards +  │  │
         │  │ 90d retention  │  │ host metrics   │  │ alerting      │  │
         │  └────────────────┘  └────────────────┘  └───────────────┘  │
         │  ┌────────────────┐  ┌────────────────┐                     │
         │  │ Loki           │  │ Promtail       │                     │
         │  │ log store      │  │ (DaemonSet)    │                     │
         │  │ 90d retention  │  │ log collector  │                     │
         │  └────────────────┘  └────────────────┘                     │
         └──────────────────────────────────────────────────────────────┘

         ┌──────────────────────────────────────────────────────────────┐
         │  Backup CronJob (daily 4:00 AM)                             │
         │  pg_dump + mysqldump → tar.gz → GPG encrypt → rclone       │
         └──────────────────────────────────────────────────────────────┘
```

## Key Changes from Docker Compose

| Aspect | Docker Compose | Kubernetes |
|---|---|---|
| **Databases** | 2× PostgreSQL + 1× MySQL | 1× PostgreSQL (shared) + 1× MySQL |
| **Redis** | 2× Redis (paperless + plant-it) | 1× shared Redis instance |
| **Ingress** | Traefik container + dynamic config file | Traefik Deployment + IngressRoute CRDs |
| **TLS** | Traefik ACME (file-based) | Traefik ACME (PVC-based) |
| **Security** | CrowdSec + Traefik plugin | Same, via shared log PVC |
| **Secrets** | `.env` files | Kubernetes Secrets |
| **Storage** | Docker volumes / bind mounts | PersistentVolumeClaims |
| **Backup** | docker-volume-backup | CronJob with pg_dump/mysqldump + rclone |
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
│   ├── mysql/
│   │   ├── mysql.yaml                     # StatefulSet + Service
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
│   ├── prometheus/
│   │   ├── prometheus.yaml                # Deployment + Service + RBAC + ConfigMap
│   │   └── node-exporter.yaml             # DaemonSet for host metrics
│   ├── loki/
│   │   ├── loki.yaml                      # Deployment + Service + ConfigMap
│   │   └── promtail.yaml                  # DaemonSet log collector + RBAC
│   ├── grafana/
│   │   ├── grafana.yaml                   # Deployment + Service + dashboards
│   │   ├── ingressroute.yaml              # grafana.d-f.dev
│   │   └── secret.example.yaml
│   └── crowdsec/
│       └── crowdsec.yaml                  # Deployment + Service + PVCs
│
├── apps/
│   ├── paperless/                         # Deployment, Gotenberg, Tika, IngressRoute
│   ├── vaultwarden/                       # Deployment, IngressRoute
│   ├── mealie/                            # Deployment, IngressRoute
│   ├── uptime-kuma/                       # Deployment, IngressRoute
│   └── plant-it/                          # Deployment, IngressRoute
│
├── backup/
│   ├── backup.yaml                        # CronJob + backup script ConfigMap
│   └── secret.example.yaml
│
└── policies/
    ├── default-deny.yaml                  # Deny all ingress by default
    ├── databases.yaml                     # PostgreSQL, MySQL, Redis access
    ├── infrastructure.yaml                # Traefik, CrowdSec, Authentik access
    ├── apps.yaml                          # App service access
    └── monitoring.yaml                    # Prometheus, Loki, Grafana access
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
| `auth.d-f.dev` | authentik | 9000 |
| `grafana.d-f.dev` | grafana | 3000 |
| `d-f.dev` | noop (shorty) | — (URL shortener middleware) |

All routes pass through the CrowdSec bouncer middleware and use Let's Encrypt
TLS certificates issued via Porkbun DNS challenge.

## Network Policies

All ingress traffic is denied by default. Each service has explicit policies:

```
Internet → Traefik (:443)
  Traefik → apps (paperless, vaultwarden, mealie, uptime-kuma, plant-it)
  Traefik → infrastructure (authentik, grafana, crowdsec)

Paperless → PostgreSQL, Redis, Gotenberg, Tika
Mealie → PostgreSQL
Plant-it → MySQL, Redis
Authentik → PostgreSQL, Redis
Grafana → Prometheus, Loki
Prometheus → node-exporter, traefik:8082, DB exporters, crowdsec:6060
Promtail → Loki
Backup → PostgreSQL, MySQL
```

## Image Updates (Renovate)

[Renovate](https://docs.renovatebot.com/) is configured via `renovate.json` in
the repo root. Install the [Renovate GitHub App](https://github.com/apps/renovate)
on this repo and it will automatically create PRs for image updates.

- **Patch/minor** updates auto-merge (except databases and security)
- **Major** updates require manual review
- Updates are grouped by category (databases, monitoring, security)
- Runs on weekends to avoid mid-week disruptions

## Prerequisites

- **Kubernetes cluster** — [k3s](https://k3s.io) recommended for home servers
- **kubectl** — configured to connect to your cluster
- **Traefik CRDs** — installed (k3s includes Traefik by default)
- **sops + age** — for secret management (`brew install sops age`)
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
for f in $(find k8s -name 'secret.example.yaml'); do
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

# 3. Run the setup script
chmod +x setup.sh
./setup.sh

# 4. Verify
kubectl -n server get pods
kubectl -n server get svc
kubectl -n server get ingressroute
```

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

All persistent data uses PersistentVolumeClaims with the default StorageClass.
On k3s, this is the `local-path-provisioner` which stores data on the node at
`/var/lib/rancher/k3s/storage/`.

| PVC | Size | Used By |
|---|---|---|
| `data` (StatefulSet) | 10Gi | PostgreSQL |
| `data` (StatefulSet) | 5Gi | MySQL |
| `redis-data` | 1Gi | Redis |
| `paperless-data` | 5Gi | Paperless |
| `paperless-media` | 10Gi | Paperless |
| `paperless-export` | 5Gi | Paperless |
| `paperless-consume` | 1Gi | Paperless |
| `vaultwarden-data` | 1Gi | Vaultwarden |
| `mealie-data` | 5Gi | Mealie |
| `uptime-kuma-data` | 2Gi | Uptime Kuma |
| `plant-it-data` | 2Gi | Plant-it |
| `prometheus-data` | 10Gi | Prometheus (90d metrics) |
| `grafana-data` | 2Gi | Grafana |
| `loki-data` | 10Gi | Loki (90d logs) |
| `traefik-acme` | 100Mi | Traefik (certificates) |
| `traefik-logs` | 1Gi | Traefik → CrowdSec |
| `crowdsec-data` | 2Gi | CrowdSec |
| `crowdsec-config` | 1Gi | CrowdSec |
| `backup-storage` | 20Gi | Backup CronJob |
