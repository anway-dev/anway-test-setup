#!/usr/bin/env bash
# local-orbstack.sh — Bootstrap the full demo stack in OrbStack k8s.
#
# Usage:
#   cd test-cloud-setup
#   cp .env.example .env.local && edit .env.local
#   source .env.local
#   ./scripts/local-orbstack.sh
#
# Prerequisites:
#   - OrbStack running with k8s enabled
#   - Docker, kubectl, helm in PATH
#   - Anway gateway running on host:8510 (docker compose -f infra/docker-compose.dev.yml up -d)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ── 0. Load env ───────────────────────────────────────────────────────────────
if [ -f "${REPO_ROOT}/.env.local" ]; then
  set -a; source "${REPO_ROOT}/.env.local"; set +a
fi
JWT_SECRET="${JWT_SECRET:-local-dev-secret-change-me}"
ANWAY_WEBHOOK_TOKEN="${ANWAY_WEBHOOK_TOKEN:-anway-demo-webhook-token}"

# ── 1. Verify cluster ─────────────────────────────────────────────────────────
log "Verifying OrbStack k8s..."
kubectl cluster-info --request-timeout=5s >/dev/null || die "kubectl not connected — enable k8s in OrbStack"

SERVICES=(
  api-gateway auth-service user-service product-service cart-service
  order-service payment-service inventory-service notification-service
  search-service recommendation-service review-service shipping-service
  analytics-service admin-service
)

# ── 2. Build images ───────────────────────────────────────────────────────────
# OrbStack k8s shares the local Docker image store — no registry push needed.
log "Building service images (OrbStack shares Docker images with k8s)..."
for SVC in "${SERVICES[@]}"; do
  log "  → ${SVC}:local"
  docker build -t "${SVC}:local" "${REPO_ROOT}/services/${SVC}" --quiet
done

log "Building runner images..."
docker build -t traffic-simulator:local "${REPO_ROOT}/runners/traffic-simulator" --quiet
docker build -t chaos-runner:local "${REPO_ROOT}/runners/chaos-runner" --quiet
log "All images built"

# ── 3. Namespaces ─────────────────────────────────────────────────────────────
log "Applying namespaces..."
kubectl apply -f "${REPO_ROOT}/k8s/namespaces/namespaces.yaml"

# ── 4. Service account (local — no IRSA) ─────────────────────────────────────
log "Applying service account..."
kubectl apply -f "${REPO_ROOT}/k8s/local/service-account.yaml"

# ── 5. Secrets ────────────────────────────────────────────────────────────────
log "Creating app-secrets..."
kubectl create secret generic app-secrets \
  --from-literal=JWT_SECRET="${JWT_SECRET}" \
  --from-literal=DATABASE_URL="postgresql://demo:demo@postgresql.demo.svc.cluster.local:5432/demo" \
  --namespace=demo \
  --dry-run=client -o yaml | kubectl apply -f -

log "Creating alertmanager webhook secret..."
kubectl create secret generic alertmanager-webhook \
  --from-literal=token="${ANWAY_WEBHOOK_TOKEN}" \
  --namespace=observability \
  --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

# ── 6. Helm repos ─────────────────────────────────────────────────────────────
log "Adding helm repos..."
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update --fail-on-repo-update-fail 2>/dev/null || helm repo update

# ── 7. Postgres + Redis ───────────────────────────────────────────────────────
log "Deploying postgres..."
helm upgrade --install postgresql bitnami/postgresql \
  --namespace demo \
  --set auth.username=demo \
  --set auth.password=demo \
  --set auth.database=demo \
  --set primary.persistence.enabled=false \
  --wait --timeout=5m

log "Deploying redis..."
helm upgrade --install redis bitnami/redis \
  --namespace demo \
  --set auth.enabled=false \
  --set master.persistence.enabled=false \
  --set replica.replicaCount=0 \
  --wait --timeout=5m

# ── 8. ConfigMap ──────────────────────────────────────────────────────────────
log "Applying ConfigMap..."
kubectl apply -f "${REPO_ROOT}/k8s/services/configmap.yaml"

# ── 9. Deploy services ────────────────────────────────────────────────────────
log "Deploying ${#SERVICES[@]} demo services..."
for SVC in "${SERVICES[@]}"; do
  MANIFEST="${REPO_ROOT}/k8s/services/${SVC}/deployment.yaml"
  [ -f "$MANIFEST" ] || { log "  SKIP ${SVC} — no manifest found"; continue; }
  sed \
    -e "s|\${ECR_REGISTRY}/anway-demo/\([^:]*\):\${IMAGE_TAG}|\1:local|g" \
    "$MANIFEST" | \
  # imagePullPolicy: Never — images are local, never pull from registry
  awk '/image: [a-z]/{print; print "          imagePullPolicy: Never"; next}1' | \
  # 1 replica locally to save resources
  sed 's/replicas: [0-9]*/replicas: 1/' | \
  # Inject app-secrets alongside configMapRef
  awk '/name: service-urls/{print; print "            - secretRef:"; print "                name: app-secrets"; next}1' | \
  kubectl apply -f -
done

# Remove HPAs — minReplicas:2 would override replicas:1
log "Removing HPAs..."
kubectl delete hpa --all -n demo --ignore-not-found 2>/dev/null || true

# ── 10. Observability ─────────────────────────────────────────────────────────
log "Installing kube-prometheus-stack..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace observability \
  --create-namespace \
  -f "${REPO_ROOT}/k8s/observability/prometheus/values-local.yaml" \
  --timeout=10m

log "Installing loki-stack..."
helm upgrade --install loki grafana/loki-stack \
  --namespace observability \
  -f "${REPO_ROOT}/k8s/observability/loki/values-local.yaml" \
  --timeout=5m

log "Applying Grafana dashboards configmap..."
kubectl apply -f "${REPO_ROOT}/k8s/observability/grafana/dashboards-configmap.yaml"

# ── 11. Runners ───────────────────────────────────────────────────────────────
log "Deploying traffic-simulator..."
sed \
  -e "s|\${ECR_REGISTRY}/anway-demo/traffic-simulator:\${IMAGE_TAG}|traffic-simulator:local|g" \
  "${REPO_ROOT}/k8s/runners/traffic-simulator.yaml" | \
  awk '/image: [a-z]/{print; print "          imagePullPolicy: Never"; next}1' | \
  kubectl apply -f -

log "Deploying chaos-runner..."
sed \
  -e "s|\${ECR_REGISTRY}/anway-demo/chaos-runner:\${IMAGE_TAG}|chaos-runner:local|g" \
  "${REPO_ROOT}/k8s/runners/chaos-runner.yaml" | \
  awk '/image: [a-z]/{print; print "          imagePullPolicy: Never"; next}1' | \
  kubectl apply -f -

# ── 12. Wait for rollout ──────────────────────────────────────────────────────
log "Waiting for service pods (2 min timeout per service)..."
for SVC in "${SERVICES[@]}"; do
  kubectl rollout status deployment/"${SVC}" -n demo --timeout=120s 2>/dev/null \
    || log "  WARNING: ${SVC} not ready yet (kubectl get pods -n demo)"
done

# ── 13. Summary ───────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Demo stack ready in OrbStack k8s"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Pods:"
kubectl get pods -n demo --no-headers 2>/dev/null | awk '{printf "   %-40s %s\n", $1, $3}'
echo ""
echo " Port-forwards (run in separate terminals):"
echo "   Grafana      : kubectl port-forward svc/kube-prometheus-stack-grafana 3001:80 -n observability"
echo "                  → http://localhost:3001  (admin / admin)"
echo "   Prometheus   : kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n observability"
echo "   Alertmanager : kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 -n observability"
echo "   API Gateway  : kubectl port-forward svc/api-gateway 8080:3000 -n demo"
echo ""
echo " Anway k8s connector config:"
echo "   KUBECONFIG: ${HOME}/.kube/config"
echo "   Namespace:  demo"
echo "   (gateway dev compose already mounts ${HOME}/.kube — connector works immediately)"
echo ""
echo " Alertmanager → Anway: http://host.docker.internal:8510/api/events/alert"
echo " Alerts fire → War Room in Anway UI once webhook token matches."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
