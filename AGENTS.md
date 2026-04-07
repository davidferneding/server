# AGENTS.md — Home Server Kubernetes GitOps

This repo is a **Kubernetes GitOps** configuration for a personal home server. Flux CD watches the `main` branch and reconciles the cluster. All resources live in the `server` namespace. Traefik is the ingress controller. SOPS+age encrypts all secrets.

---

## Core Commands

```bash
# Secret management
./secrets.sh encrypt        # encrypt all secret.yaml files (safe to commit after)
./secrets.sh decrypt        # decrypt for local editing (never commit decrypted)
./secrets.sh status         # show 🔒/🔓 state of each secret file

# Flux GitOps
flux get all                             # check reconciliation status
flux reconcile kustomization server      # force immediate sync (skips 10m interval)
flux logs --follow                       # watch Flux logs

# Day-to-day kubectl
kubectl -n server get pods
kubectl -n server logs deploy/<name> -f
kubectl -n server rollout restart deploy/<name>
kubectl -n server scale deploy/<name> --replicas=0    # take down a service
kubectl -n server create job --from=cronjob/backup manual-backup  # run backup now
kubectl -n server top pods
kubectl -n server describe pod <pod>
```

No build/test/lint commands — this is pure YAML configuration.

---

## Mandatory Rules for Every Change

### 1. Register in kustomization.yaml
`kustomization.yaml` is the single manifest Flux applies. **Any new file must be added to it.** Flux ignores files not listed there, even if they're `kubectl apply`-able manually.

### 2. Add a Network Policy
`policies/default-deny.yaml` blocks all ingress by default. Every new service, new port, or new caller relationship needs an explicit allow rule. Add it to the right file in `policies/`:
- `apps.yaml` — app-to-Traefik rules
- `databases.yaml` — database access + Prometheus sidecar scraping
- `infrastructure.yaml` — infrastructure service rules
- `monitoring.yaml` — Prometheus/Grafana rules

If a pod is unreachable but exists and its Service is correct, a missing NetworkPolicy is almost always the cause.

### 3. Apply the CrowdSec Middleware
Every `IngressRoute` must include:
```yaml
middlewares:
  - name: crowdsec
    namespace: server
```
There are no exceptions — all external routes pass through the CrowdSec bouncer.

### 4. Use `letsencrypt` TLS on all IngressRoutes
```yaml
tls:
  certResolver: letsencrypt
```
Traefik only exposes port 443 (no HTTP/80 entrypoint is configured).

---

## Resource Patterns

### Labels (required on everything)
```yaml
labels:
  app.kubernetes.io/name: <service-name>
  app.kubernetes.io/component: <app|ingress|config|storage|service|...>
  app.kubernetes.io/part-of: server
```
Network policies use `app.kubernetes.io/name` for pod selectors — consistency is critical.

### Secrets
- Files matching `.*secret\.yaml$` are SOPS-encrypted with age (see `.sops.yaml`)
- `secret.example.yaml` = template (unencrypted, committed), copy to `secret.yaml` and fill values
- The `secrets.sh encrypt` command is idempotent — it skips already-encrypted files
- Flux decrypts secrets automatically using the `sops-age` secret in `flux-system`
- **Never commit a decrypted `secret.yaml`** — run `./secrets.sh status` to verify before pushing

### ConfigMaps for non-secret config
All non-sensitive env vars go in a `ConfigMap`, referenced via `envFrom.configMapRef`. Secrets come in via `env[].valueFrom.secretKeyRef`.

### Resource limits
Every container has `resources.requests` and `resources.limits`. Match the pattern of neighboring services when adding a new container.

### Health probes
Every container has both `readinessProbe` and `livenessProbe`. Databases use `exec` (pg_isready / mysqladmin ping). HTTP services use `httpGet`.

---

## Database Architecture

**Single shared PostgreSQL** (`StatefulSet: postgresql`, `Service: postgresql:5432`) hosts:
- `paperless` — owned by user `paperless`
- `mealie` — owned by user `mealie`
- `authentik` — owned by user `authentik`

All three databases and users are created by the init script in `infrastructure/postgresql/postgresql.yaml` (ConfigMap `postgresql-init`). To add another database, add a block to that init script **and** add the password to `postgresql-secret`.

**MySQL** (`StatefulSet: mysql`, `Service: mysql:3306`) hosts:
- `bootdb` — used by plant-it (root user)
- Started with `--mysql-native-password` arg — required for plant-it compatibility

**Single shared Redis** (`Deployment: redis`, `Service: redis:6379`):
- paperless: DB 0 (default)
- authentik: DB 1 (`AUTHENTIK_REDIS__DB: "1"`)
- plant-it: DB 0 (default — potential namespace collision if keys clash)

All three databases and Redis run sidecars (postgres-exporter, mysqld-exporter, redis-exporter) for Prometheus scraping. They expose metrics on ports 9187, 9104, 9121 respectively. The pods carry `prometheus.io/scrape: "true"` and `prometheus.io/port` annotations so Prometheus auto-discovers them.

---

## Authentication Architecture

**Authentik** (`auth.d-f.dev`) is the identity provider for the whole cluster.

Two integration patterns:

| Pattern | Used by | How |
|---|---|---|
| Native OIDC | Grafana, Paperless, Mealie | App configured with Authentik as OIDC provider directly |
| Forward-auth | Uptime-Kuma, Plant-it (if needed) | Add `authentik-auth` middleware to IngressRoute |

The `authentik-auth` middleware (defined in `infrastructure/authentik/middleware.yaml`) delegates auth to `http://authentik:9000/outpost.goauthentik.io/auth/traefik`. Use it only for apps without native OIDC support.

Grafana's OIDC is configured via env vars in `grafana.yaml`. Role mapping uses Authentik groups: `grafana_admins` → Admin, `grafana_editors` → Editor, else Viewer.


---

## Traefik & Plugins

Traefik config lives in `infrastructure/traefik/configmap.yaml` (static config). Two plugins are loaded:

- **crowdsec-bouncer** (`v1.4.0`) — reads LAPI from `crowdsec:8080`, key from `/etc/traefik/secrets/CROWDSEC_API_KEY`
- **shorty** (`v1.0.1`) — URL shortener for `d-f.dev`. Short links are defined in the `shorty` Middleware in `middlewares.yaml`

CrowdSec reads Traefik's access logs via the shared PVC `traefik-logs` (mounted at `/logs/` in Traefik, `/var/log/traefik` in CrowdSec). Both pods must be running and share that PVC.

TLS certificates use **Porkbun DNS challenge**. Credentials come from `traefik-secret` as env vars (`PORKBUN_API_KEY`, `PORKBUN_SECRET_API_KEY`). Certs are stored in the `traefik-acme` PVC.

Metrics exposed on `:8082` (not `:8080`) — the metrics entrypoint is named `metrics` in the static config.

---

## Monitoring

**Prometheus** scrapes via two mechanisms:
1. Static targets: `node-exporter:9100`, `traefik:8082`
2. Pod annotation discovery (namespace `server` only): pods with `prometheus.io/scrape: "true"` + `prometheus.io/port: "<port>"` are auto-scraped

Retention: 90 days for both Prometheus and Loki.

**Node-exporter** runs as a DaemonSet with `hostPID: true` and `hostNetwork: true` — it uses `hostPort: 9100` and mounts the host's root filesystem. This is intentional for host-level metrics.

**Grafana** (`grafana.d-f.dev`) has a pre-provisioned dashboard (`home-server-overview`) via ConfigMap. The Prometheus datasource is also provisioned. Additional dashboards can be added to the `grafana-dashboards` ConfigMap.

**Note:** Loki and Promtail are referenced in `setup.sh` and the README architecture diagram but their manifests (`infrastructure/loki/`) **do not exist in this repo**. They appear to be planned but not yet implemented.

---

## Backup

CronJob runs daily at `0 4 * * *` (4 AM). Uses an ephemeral `alpine:3.21` container that installs tools at startup (`apk add postgresql16-client mysql-client gnupg rclone`).

Backup flow: `pg_dump` + `mariadb-dump` (not `mysqldump`) → tar.gz → GPG encrypt (AES256) → rclone upload → cleanup old backups.

**Excluded from backup** intentionally: Loki (`loki-data`) and Prometheus (`prometheus-data`) — too large, regenerable.

Backup destination is configured via `rclone.conf` in `backup-secret`. Currently Dropbox (`d-f-dev` remote, path `/d-f-dev/backups`). A Backblaze B2 config block is commented out in `backup/secret.example.yaml` as a ready alternative.

Retention: 90 days (`BACKUP_RETENTION_DAYS=90`). Backup PVC is 40Gi.

To run a manual backup: `kubectl -n server create job --from=cronjob/backup manual-backup`

---

## Flux CD & GitOps

- **Source** (`infrastructure/flux/source.yaml`): polls `github.com/davidferneding/server.git` on `main` every 1 minute via SSH deploy key
- **Sync** (`infrastructure/flux/sync.yaml`): reconciles every 10 minutes, retries every 2 minutes on failure, timeout 5 minutes
- `prune: true` — resources removed from `kustomization.yaml` are deleted from the cluster
- `wait: true` — Flux waits for health checks before marking reconciliation complete
- SOPS decryption happens automatically via the `sops-age` secret in `flux-system`

Flux watches the entire repo root (`.`). Everything in `kustomization.yaml` gets applied.

---

## Renovate

Auto-merges patch and minor updates on weekends. **Does NOT auto-merge:**
- Databases (`postgres`, `mysql`, `redis`) — grouped, manual review
- Security (`crowdsec`, `authentik`) — grouped, manual review
- `vaultwarden/server` — any update requires manual review

Major updates always require manual review. Renovate scans all `.yaml` files for container image references.

---

## Upgrading PostgreSQL

The StatefulSet uses a `pgautoupgrade` init container to handle major-version upgrades automatically and idempotently. On every pod start it:

1. Checks `$PGDATA/PG_VERSION` — if the file is absent (fresh install) or already matches `TARGET_VERSION`, exits immediately (no-op)
2. If a mismatch is found, sets `PGAUTO_ONESHOT=yes` and execs the pgautoupgrade entrypoint, which runs `pg_upgrade` and exits
3. The main `postgres:<n>` container then starts normally

**To upgrade from version N to version N+1**, bump only the two image tags in `infrastructure/postgresql/postgresql.yaml`:
- `initContainers[0].image`: `pgautoupgrade/pgautoupgrade:N+1-debian`
- `containers[0].image`: `postgres:N+1`

The script uses `$PG_MAJOR` (an env var the official postgres/pgautoupgrade image sets automatically) as the target version, so no script changes are needed — Renovate can handle both bumps unattended.

The init container only has `POSTGRES_USER`, `PGDATA`, and `POSTGRES_PASSWORD` — it does **not** need the per-database password env vars (those are only used by the `docker-entrypoint-initdb.d` init script on a fresh install).

## Gotchas

- **Uptime-Kuma uses `hostPath: /data/uptime-kuma`** instead of a PVC — inconsistent with all other apps. Data is on the node's filesystem, not a PVC.
- **Traefik has no HTTP/80 entrypoint** — there's no redirect from HTTP to HTTPS because nothing listens on 80. All traffic must hit 443 directly.
- **The `server` namespace has `app.kubernetes.io/part-of: server` label** — some selectors and policies may rely on namespace labels.
- **PostgreSQL `PGDATA` is set to `/var/lib/postgresql/data/pgdata`** (a subdirectory) — this is to avoid a known issue with PostgreSQL complaining about a non-empty data directory when using PVCs.
- **Authentik has two Deployments** (`authentik-server` + `authentik-worker`) sharing the same ConfigMap and image, but with different `args` (`server` vs `worker`). The `authentik` Service only selects `component: server`.
- **MySQL uses `root` user for everything** — plant-it connects as root, and mysqld-exporter also uses root credentials.
- **Redis has no password** — it's protected only by network policy, not authentication.
- **The `shorty` middleware links are hardcoded in `middlewares.yaml`** — to add a short link, add to the `spec.plugin.shorty.links` map and commit.
- **CrowdSec AppSec is disabled** (`crowdsecAppsecEnabled: false`) in the middleware config, even though the AppSec port (7422) is listed in the CrowdSec Service and the CrowdSec container loads AppSec collections.
