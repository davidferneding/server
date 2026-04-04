#!/bin/bash
# Setup script for the Kubernetes home server cluster
# Prerequisites: kubectl, a running Kubernetes cluster (k3s recommended)
#
# Make executable: chmod +x setup.sh
set -euo pipefail

echo "=== Home Server Kubernetes Setup ==="
echo ""

# Check prerequisites
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed."; exit 1; }
command -v sops >/dev/null 2>&1 || { echo "sops is required but not installed. Install: brew install sops"; exit 1; }

# Decrypt secrets if encrypted with SOPS
SOPS_DECRYPTED=()
decrypt_if_needed() {
  local f="$1"
  if [ -f "$f" ] && grep -q "sops:" "$f" 2>/dev/null; then
    echo "  Decrypting $f..."
    sops -d "$f" | kubectl apply -f -
    return 0
  elif [ -f "$f" ]; then
    kubectl apply -f "$f"
    return 0
  fi
  echo "  WARNING: $f not found, skipping..."
  return 0
}

# Step 1: Install Traefik CRDs (skip if using k3s with built-in Traefik)
echo "Step 1: Installing Traefik CRDs..."
echo "If using k3s with built-in Traefik, you may skip this step."
echo "For manual Traefik installation, apply CRDs from:"
echo "  https://doc.traefik.io/traefik/reference/dynamic-configuration/kubernetes-crd/"
echo ""
read -p "Install Traefik CRDs? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  kubectl apply -f https://raw.githubusercontent.com/traefik/traefik/v3.0/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml
fi

# Step 2: Create namespace
echo ""
echo "Step 2: Creating namespace..."
kubectl apply -f namespace.yaml

# Step 3: Apply secrets (auto-decrypts SOPS-encrypted files)
echo ""
echo "Step 3: Applying secrets..."
echo "Secrets should be SOPS-encrypted. See README.md for setup instructions."
echo ""

for secret_file in \
  infrastructure/postgresql/secret.yaml \
  infrastructure/mysql/secret.yaml \
  infrastructure/traefik/secret.yaml \
  apps/paperless/secret.yaml \
  apps/mealie/secret.yaml \
  apps/plant-it/secret.yaml \
  infrastructure/authentik/secret.yaml \
  infrastructure/grafana/secret.yaml \
  backup/secret.yaml; do
  decrypt_if_needed "$secret_file"
done

# Step 4: Deploy infrastructure
echo ""
echo "Step 4: Deploying infrastructure..."
kubectl apply -f infrastructure/postgresql/postgresql.yaml
kubectl apply -f infrastructure/mysql/mysql.yaml
kubectl apply -f infrastructure/redis/redis.yaml

echo "Waiting for databases to be ready..."
kubectl -n server wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql --timeout=120s
kubectl -n server wait --for=condition=ready pod -l app.kubernetes.io/name=mysql --timeout=120s
kubectl -n server wait --for=condition=ready pod -l app.kubernetes.io/name=redis --timeout=60s

# Step 5: Deploy networking
echo ""
echo "Step 5: Deploying Traefik and CrowdSec..."
kubectl apply -f infrastructure/traefik/rbac.yaml
kubectl apply -f infrastructure/traefik/configmap.yaml
kubectl apply -f infrastructure/traefik/traefik.yaml
kubectl apply -f infrastructure/traefik/middlewares.yaml
kubectl apply -f infrastructure/traefik/ingressroute-shorty.yaml
kubectl apply -f infrastructure/crowdsec/crowdsec.yaml

echo "Waiting for Traefik to be ready..."
kubectl -n server wait --for=condition=ready pod -l app.kubernetes.io/name=traefik --timeout=120s

# Step 6: Deploy Authentik (identity provider)
echo ""
echo "Step 6: Deploying Authentik..."
kubectl apply -f infrastructure/authentik/authentik.yaml
kubectl apply -f infrastructure/authentik/middleware.yaml
kubectl apply -f infrastructure/authentik/ingressroute.yaml

echo "Waiting for Authentik to be ready..."
kubectl -n server wait --for=condition=ready pod -l app.kubernetes.io/name=authentik,app.kubernetes.io/component=server --timeout=180s

# Step 7: Deploy monitoring and logging
echo ""
echo "Step 7: Deploying monitoring and logging..."
kubectl apply -f infrastructure/prometheus/prometheus.yaml
kubectl apply -f infrastructure/prometheus/node-exporter.yaml
kubectl apply -f infrastructure/loki/loki.yaml
kubectl apply -f infrastructure/loki/promtail.yaml
kubectl apply -f infrastructure/grafana/grafana.yaml
kubectl apply -f infrastructure/grafana/ingressroute.yaml

echo "Waiting for monitoring to be ready..."
kubectl -n server wait --for=condition=ready pod -l app.kubernetes.io/name=prometheus --timeout=120s
kubectl -n server wait --for=condition=ready pod -l app.kubernetes.io/name=loki --timeout=120s
kubectl -n server wait --for=condition=ready pod -l app.kubernetes.io/name=grafana --timeout=60s

# Step 8: Deploy applications
echo ""
echo "Step 8: Deploying applications..."
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

# Step 9: Deploy backup
echo ""
echo "Step 9: Deploying backup CronJob..."
kubectl apply -f backup/backup.yaml

# Step 10: Apply network policies
echo ""
echo "Step 10: Applying network policies..."
kubectl apply -f policies/

echo ""
echo "=== Setup complete! ==="
echo ""
echo "Check pod status with: kubectl -n server get pods"
echo "Check services with:   kubectl -n server get svc"
echo "Check ingress with:    kubectl -n server get ingressroute"
