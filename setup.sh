#!/bin/bash
# Setup script for the Kubernetes home server cluster
# Prerequisites: kubectl, flux, a running Kubernetes cluster (k3s recommended)
#
# Make executable: chmod +x setup.sh
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

echo "=== Home Server Kubernetes Setup ==="
echo ""

# Check prerequisites
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed."; exit 1; }
command -v sops >/dev/null 2>&1 || { echo "sops is required but not installed. Install: brew install sops"; exit 1; }
command -v flux >/dev/null 2>&1 || { echo "flux is required but not installed. Install: brew install fluxcd/tap/flux"; exit 1; }

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
  infrastructure/mariadb/secret.yaml \
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
kubectl apply -f infrastructure/mariadb/mariadb.yaml
kubectl apply -f infrastructure/redis/redis.yaml

echo "Waiting for databases to be ready..."
kubectl -n server wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql --timeout=120s
kubectl -n server wait --for=condition=ready pod -l app.kubernetes.io/name=mariadb --timeout=120s
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

# Step 6: Deploy Authentik and Headscale
echo ""
echo "Step 6: Deploying Authentik and Headscale..."
kubectl apply -f infrastructure/authentik/authentik.yaml
kubectl apply -f infrastructure/authentik/middleware.yaml
kubectl apply -f infrastructure/authentik/ingressroute.yaml
kubectl apply -f infrastructure/headscale/headscale.yaml
kubectl apply -f infrastructure/headscale/ingressroute.yaml

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

# Step 11: Install Flux CD for GitOps
echo ""
echo "Step 11: Installing Flux CD..."
echo "Flux will watch the Git repository and auto-reconcile on changes."
echo ""

flux check --pre
flux install

# Provide the age private key so Flux can decrypt SOPS secrets
echo ""
echo "Creating SOPS age decryption secret for Flux..."
if [ -f keys.txt ]; then
  kubectl create secret generic sops-age \
    --namespace=flux-system \
    --from-file=age.agekey=keys.txt \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "WARNING: keys.txt not found. Create the SOPS secret manually:"
  echo "  kubectl create secret generic sops-age --namespace=flux-system --from-file=age.agekey=keys.txt"
fi

# Create deploy key secret for Git access
echo ""
echo "Setting up Git repository access..."
if [ -f ~/.ssh/flux_deploy_key ]; then
  kubectl create secret generic flux-deploy-key \
    --namespace=flux-system \
    --from-file=identity=~/.ssh/flux_deploy_key \
    --from-literal=known_hosts="$(ssh-keyscan github.com 2>/dev/null)" \
    --type=Opaque \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "WARNING: ~/.ssh/flux_deploy_key not found."
  echo "Generate a deploy key and add it to your GitHub repo:"
  echo "  ssh-keygen -t ed25519 -f ~/.ssh/flux_deploy_key -N ''"
  echo "  # Add the public key as a deploy key in GitHub repo settings"
  echo "  kubectl create secret generic flux-deploy-key --namespace=flux-system \\"
  echo "    --from-file=identity=~/.ssh/flux_deploy_key \\"
  echo "    --from-literal=known_hosts=\"\$(ssh-keyscan github.com 2>/dev/null)\" \\"
  echo "    --type=Opaque"
fi

# Apply Flux GitRepository and Kustomization
echo ""
echo "Applying Flux sync configuration..."
kubectl apply -f infrastructure/flux/source.yaml
kubectl apply -f infrastructure/flux/sync.yaml

echo ""
echo "=== Setup complete! ==="
echo ""
echo "Check pod status with:  kubectl -n server get pods"
echo "Check services with:    kubectl -n server get svc"
echo "Check ingress with:     kubectl -n server get ingressroute"
echo "Check Flux status with: flux get all"
