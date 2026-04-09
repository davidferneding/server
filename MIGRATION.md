# Migration Guide: Docker Compose → Kubernetes

This guide walks through migrating the existing Docker Compose home server to
the Kubernetes setup in this directory.

## Migration Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        BEFORE (Docker Compose)                      │
│                                                                     │
│  paperless-db (PG) ──┐                                              │
│  mealie-db    (PG) ──┤  ← 2 separate PostgreSQL instances           │
│  plant-it-db  (MySQL)│  ← 1 MySQL instance                         │
│  paperless-redis  ───┤  ← 2 separate Redis instances                │
│  plant-it-redis   ───┘                                              │
│                                                                     │
│  traefik ← dynamic config file + .env secrets                       │
│  docker-volume-backup ← stops containers during backup              │
└─────────────────────────────────────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        AFTER (Kubernetes)                            │
│                                                                     │
│  postgresql (PG) ────┐  ← 1 shared PostgreSQL (paperless + mealie)  │
│  mariadb     (MariaDB)┤ ← 1 MariaDB (plant-it)                      │
│  redis       ─────────┘ ← 1 shared Redis                            │
│                                                                     │
│  traefik ← IngressRoute CRDs + K8s Secrets                         │
│  backup CronJob ← pg_dump/mariadb-dump, no downtime                │
└─────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

1. A running Kubernetes cluster (k3s recommended: `curl -sfL https://get.k3s.io | sh -`)
2. `kubectl` configured (`k3s` sets this up at `/etc/rancher/k3s/k3s.yaml`)
3. DNS records pointing `*.d-f.dev` to your server's IP

### If using k3s

k3s ships with Traefik, but this setup deploys its own Traefik instance with
custom plugins (CrowdSec bouncer, Shorty). Disable k3s's built-in Traefik:

```bash
# /etc/rancher/k3s/config.yaml
disable:
  - traefik
```

Then restart k3s: `sudo systemctl restart k3s`

## Step-by-Step Migration

### Phase 1: Prepare Secrets

Copy each `secret.example.yaml` to `secret.yaml` and fill in real values:

```bash
for f in $(find . -name 'secret.example.yaml'); do
  cp "$f" "${f%.example.yaml}.yaml"
done
```

**Secret files to edit:**

| File | Keys |
|---|---|
| `infrastructure/postgresql/secret.yaml` | `POSTGRES_PASSWORD`, `PAPERLESS_DB_PASSWORD`, `MEALIE_DB_PASSWORD` |
| `infrastructure/mariadb/secret.yaml` | `MARIADB_ROOT_PASSWORD` |
| `infrastructure/traefik/secret.yaml` | `PORKBUN_API_KEY`, `PORKBUN_SECRET_API_KEY`, `CROWDSEC_API_KEY` |
| `apps/paperless/secret.yaml` | `PAPERLESS_SECRET_KEY` |
| `apps/mealie/secret.yaml` | `SMTP_PASSWORD` |
| `apps/plant-it/secret.yaml` | `JWT_SECRET` |
| `backup/secret.yaml` | `GPG_PASSPHRASE`, `rclone.conf` (Dropbox or B2 config) |

> Use the same values from your current `.env` files where applicable.

### Phase 2: Export Data from Docker Compose

**Stop all services and create data exports:**

```bash
# From the server/ root directory (Docker Compose setup)
docker compose down

# Dump PostgreSQL databases
docker compose run --rm paperless-db \
  pg_dump -U paperless paperless > /tmp/paperless.sql

# For mealie, the DB container name might differ
docker compose run --rm mealie-db \
  pg_dump -U mealie mealie > /tmp/mealie.sql

# Dump MySQL
docker compose run --rm plant-it-db \
  mysqldump -u root -proot bootdb > /tmp/bootdb.sql
```

**Copy file-based data directories:**

```bash
# These paths match the Docker bind mounts in the compose files
cp -r data/paperless /tmp/paperless-data
cp -r data/vaultwarden /tmp/vaultwarden-data
cp -r data/mealie /tmp/mealie-data
cp -r data/uptime /tmp/uptime-data
cp -r data/plant-it /tmp/plant-it-data
cp -r data/crowdsec /tmp/crowdsec-data
```

### Phase 3: Deploy Infrastructure

```bash
# Install Traefik CRDs (skip if already installed)
kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v3.0/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml

# Create namespace and secrets
kubectl apply -f namespace.yaml
kubectl apply -f infrastructure/postgresql/secret.yaml
kubectl apply -f infrastructure/mariadb/secret.yaml
kubectl apply -f infrastructure/traefik/secret.yaml

# Deploy databases
kubectl apply -f infrastructure/postgresql/postgresql.yaml
kubectl apply -f infrastructure/mariadb/mariadb.yaml
kubectl apply -f infrastructure/redis/redis.yaml

# Wait for databases
kubectl -n server wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql --timeout=120s
kubectl -n server wait --for=condition=ready pod -l app.kubernetes.io/name=mariadb --timeout=120s
```

### Phase 4: Restore Data

```bash
# Restore PostgreSQL data
kubectl -n server cp /tmp/paperless.sql postgresql-0:/tmp/paperless.sql
kubectl -n server exec postgresql-0 -- \
  psql -U paperless -d paperless -f /tmp/paperless.sql

kubectl -n server cp /tmp/mealie.sql postgresql-0:/tmp/mealie.sql
kubectl -n server exec postgresql-0 -- \
  psql -U mealie -d mealie -f /tmp/mealie.sql

# Restore MariaDB data
MARIADB_POD=$(kubectl -n server get pod -l app.kubernetes.io/name=mariadb -o jsonpath='{.items[0].metadata.name}')
kubectl -n server cp /tmp/bootdb.sql ${MARIADB_POD}:/tmp/bootdb.sql
kubectl -n server exec ${MARIADB_POD} -- \
  mariadb -u root -p"$(kubectl -n server get secret mariadb-secret -o jsonpath='{.data.MARIADB_ROOT_PASSWORD}' | base64 -d)" bootdb < /tmp/bootdb.sql
```

**Restore file-based data** (method depends on your StorageClass):

```bash
# For k3s local-path-provisioner, find PVC paths:
kubectl -n server get pvc -o custom-columns=NAME:.metadata.name,VOLUME:.spec.volumeName

# Copy data into the PVC backing directories (typically /var/lib/rancher/k3s/storage/)
# Example for vaultwarden:
PV_PATH=$(kubectl get pv $(kubectl -n server get pvc vaultwarden-data -o jsonpath='{.spec.volumeName}') \
  -o jsonpath='{.spec.hostPath.path}')
sudo cp -r /tmp/vaultwarden-data/* ${PV_PATH}/
```

### Phase 5: Deploy Networking & Applications

```bash
# Traefik + CrowdSec
kubectl apply -f infrastructure/traefik/rbac.yaml
kubectl apply -f infrastructure/traefik/configmap.yaml
kubectl apply -f infrastructure/traefik/traefik.yaml
kubectl apply -f infrastructure/traefik/middlewares.yaml
kubectl apply -f infrastructure/traefik/ingressroute-shorty.yaml
kubectl apply -f infrastructure/crowdsec/crowdsec.yaml

# Wait for Traefik
kubectl -n server wait --for=condition=ready pod -l app.kubernetes.io/name=traefik --timeout=120s

# Deploy application secrets
kubectl apply -f apps/paperless/secret.yaml
kubectl apply -f apps/mealie/secret.yaml
kubectl apply -f apps/plant-it/secret.yaml

# Deploy applications
kubectl apply -f apps/paperless/paperless.yaml
kubectl apply -f apps/paperless/gotenberg.yaml
kubectl apply -f apps/paperless/tika.yaml
kubectl apply -f apps/paperless/ingressroute.yaml
kubectl apply -f apps/vaultwarden/vaultwarden.yaml
kubectl apply -f apps/vaultwarden/ingressroute.yaml
kubectl apply -f apps/mealie/mealie.yaml
kubectl apply -f apps/mealie/ingressroute.yaml
kubectl apply -f apps/uptime-kuma/uptime-kuma.yaml
kubectl apply -f apps/uptime-kuma/ingressroute.yaml
kubectl apply -f apps/plant-it/plant-it.yaml
kubectl apply -f apps/plant-it/ingressroute.yaml
```

### Phase 6: Deploy Backup

```bash
kubectl apply -f backup/secret.yaml
kubectl apply -f backup/backup.yaml

# Test with a manual run
kubectl -n server create job --from=cronjob/backup test-backup
kubectl -n server logs -f job/test-backup
```

### Phase 7: Verify

```bash
# All pods should be Running
kubectl -n server get pods

# All services should have ClusterIPs
kubectl -n server get svc

# IngressRoutes should be listed
kubectl -n server get ingressroute

# Test HTTPS endpoints
curl -sI https://paperless.d-f.dev
curl -sI https://pw.d-f.dev
curl -sI https://food.d-f.dev
curl -sI https://uptime.d-f.dev
curl -sI https://plants.d-f.dev
```

## Rollback Plan

If anything goes wrong, the original Docker Compose setup remains unchanged:

```bash
cd /path/to/server   # original Docker Compose root
docker compose up -d
```

The Kubernetes resources can be fully removed with:

```bash
kubectl delete namespace server
kubectl delete clusterrole traefik-role
kubectl delete clusterrolebinding traefik-role-binding
```

## What Changed

### Database Consolidation

**Before:** 2 PostgreSQL instances (paperless-db, mealie-db) + 1 MySQL (plant-it-db)
**After:** 1 PostgreSQL instance with 2 databases + 1 MariaDB instance

The shared PostgreSQL uses an init script (`init-databases.sh`) that creates
both `paperless` and `mealie` databases with separate users on first boot.

### Redis Consolidation

**Before:** 2 Redis instances (paperless-redis, plant-it-redis)
**After:** 1 shared Redis instance

Both Paperless and Plant-it use database 0 by default. Key collisions are
unlikely due to application-specific prefixes.

### Backup Strategy

**Before:** `docker-volume-backup` stops containers, copies Docker volumes, encrypts,
uploads to Dropbox.

**After:** Kubernetes CronJob runs `pg_dump`/`mariadb-dump` (no downtime) and copies
file-based PVC data. Same GPG encryption, uploaded via rclone (currently Dropbox,
easily switchable to Backblaze B2 or any other provider).

### Health Checks

**New in K8s:** Every deployment has readiness and liveness probes. Kubernetes
automatically restarts unhealthy pods (replacing Docker's `restart: unless-stopped`).

### Resource Limits

**New in K8s:** Every container has CPU/memory requests and limits, preventing any
single service from consuming all node resources.

## Troubleshooting

```bash
# Pod stuck in CrashLoopBackOff
kubectl -n server describe pod <pod-name>
kubectl -n server logs <pod-name> --previous

# PVC stuck in Pending
kubectl -n server describe pvc <pvc-name>
# Check StorageClass: kubectl get storageclass

# Traefik not routing
kubectl -n server logs deploy/traefik
kubectl -n server get ingressroute -o yaml

# Database connection refused
kubectl -n server exec -it deploy/paperless -- \
  pg_isready -h postgresql -p 5432

# CrowdSec not receiving logs
kubectl -n server exec deploy/crowdsec -- ls -la /var/log/traefik/
```
