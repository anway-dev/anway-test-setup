#!/usr/bin/env bash
# local-k8s.sh — Bootstrap the full demo stack in local minikube.
#
# Usage:
#   cp .env.example .env.local && fill in JWT_SECRET and ANWAY_WEBHOOK_TOKEN
#   source .env.local
#   ./scripts/local-k8s.sh
#
# What it does:
#   1. Starts minikube (8 GB RAM, 4 CPUs)
#   2. Builds all 15 service images + runners directly into minikube (no registry)
#   3. Deploys postgres + redis via helm (bitnami)
#   4. Applies K8s namespaces, service account, secrets, configmap, deployments
#   5. Installs kube-prometheus-stack + loki via helm
#      Alertmanager fires → Anway gateway on host → incident_created graph event
#   6. Deploys traffic-simulator + chaos-runner
#   7. Prints how to wire KUBECONFIG into Anway so pipelines deploy here
#
# Subsequent deploys go through Anway:
#   deploy_trigger event → Anway gate UI → approve → pipeline deploy stage
#   (set KUBECONFIG in apps/gateway/.env to ~/.kube/config)

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

# ── 1. Minikube ───────────────────────────────────────────────────────────────
log "Checking minikube..."
if minikube status --format='{{.Host}}' 2>/dev/null | grep -q Running; then
  log "minikube already running — skipping start"
else
  log "Starting minikube (8 GB RAM, 4 CPUs, Docker driver)..."
  minikube start \
    --driver=docker \
    --memory=5120 \
    --cpus=2
fi

log "Waiting for Kubernetes API server..."
until kubectl cluster-info --request-timeout=3s >/dev/null 2>&1; do sleep 3; done

log "Enabling addons..."
minikube addons enable metrics-server
minikube addons enable ingress

# ── 2. Build images directly into minikube ────────────────────────────────────
# Use `minikube image build` — avoids docker-env / client version mismatch
SERVICES=(
  api-gateway auth-service user-service product-service cart-service
  order-service payment-service inventory-service notification-service
  search-service recommendation-service review-service shipping-service
  analytics-service admin-service
)

log "Building service images into minikube..."
for SVC in "${SERVICES[@]}"; do
  log "  → ${SVC}:local"
  minikube image build -t "${SVC}:local" "${REPO_ROOT}/services/${SVC}"
done

log "Building runner images..."
minikube image build -t traffic-simulator:local "${REPO_ROOT}/runners/traffic-simulator"
minikube image build -t chaos-runner:local "${REPO_ROOT}/runners/chaos-runner"
log "All images built"

# ── 4. Namespaces ─────────────────────────────────────────────────────────────
log "Applying namespaces..."
kubectl apply -f "${REPO_ROOT}/k8s/namespaces/namespaces.yaml"

# ── 5. Service account (local — no IRSA) ─────────────────────────────────────
log "Applying service account..."
kubectl apply -f "${REPO_ROOT}/k8s/local/service-account.yaml"

# ── 6. K8s Secrets (plain — no External Secrets Operator needed locally) ─────
log "Creating app-secrets..."
kubectl create secret generic app-secrets \
  --from-literal=JWT_SECRET="${JWT_SECRET}" \
  --from-literal=DATABASE_URL="postgresql://demo:demo@postgresql.demo.svc.cluster.local:5432/demo" \
  --namespace=demo \
  --dry-run=client -o yaml | kubectl apply -f -

log "Creating alertmanager webhook token secret..."
kubectl create secret generic alertmanager-webhook \
  --from-literal=token="${ANWAY_WEBHOOK_TOKEN}" \
  --namespace=observability \
  --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

# ── 7. Helm repos ─────────────────────────────────────────────────────────────
log "Adding helm repos..."
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update

# ── 8. Postgres + Redis ───────────────────────────────────────────────────────
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

# ── 9. ConfigMap ──────────────────────────────────────────────────────────────
log "Applying ConfigMap..."
kubectl apply -f "${REPO_ROOT}/k8s/services/configmap.yaml"

# ── 10. Deploy services ───────────────────────────────────────────────────────
log "Deploying services to demo namespace..."
for SVC in "${SERVICES[@]}"; do
  MANIFEST="${REPO_ROOT}/k8s/services/${SVC}/deployment.yaml"
  [ -f "$MANIFEST" ] || continue
  sed \
    -e "s|\${ECR_REGISTRY}/anway-demo/\([^:]*\):\${IMAGE_TAG}|\1:local|g" \
    -e "s|serviceAccountName: demo-services|serviceAccountName: demo-services|g" \
    "$MANIFEST" | \
  # Inject imagePullPolicy: Never after each image: line (local images, never pull)
  awk '/image: /{print; print "          imagePullPolicy: Never"; next}1' | \
  # Use 1 replica locally to save resources
  sed 's/replicas: [0-9]*/replicas: 1/' | \
  # Inject app-secrets alongside configMapRef (manifests only have configMapRef)
  awk '/name: service-urls/{print; print "            - secretRef:"; print "                name: app-secrets"; next}1' | \
  kubectl apply -f -
done

# Delete HPAs — minReplicas:2 overrides our replicas:1 setting above
log "Removing HPAs (local: 1 replica per service, no autoscaling)..."
kubectl delete hpa --all -n demo --ignore-not-found 2>/dev/null || true

# ── 11. Observability ─────────────────────────────────────────────────────────
# Clear any stuck helm operations from a previous interrupted run
PROM_STATUS=$(helm status kube-prometheus-stack -n observability -o json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 || echo "")
if echo "$PROM_STATUS" | grep -q "pending"; then
  log "Clearing stuck kube-prometheus-stack helm operation..."
  helm uninstall kube-prometheus-stack -n observability 2>/dev/null || true
  sleep 5
fi

log "Installing Prometheus + Alertmanager..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace observability \
  --create-namespace \
  -f "${REPO_ROOT}/k8s/observability/prometheus/values-local.yaml" \
  --timeout=10m

# ── 12. Runners — traffic-simulator only ─────────────────────────────────────
log "Deploying traffic-simulator..."
sed \
  -e "s|\${ECR_REGISTRY}/anway-demo/traffic-simulator:\${IMAGE_TAG}|traffic-simulator:local|g" \
  "${REPO_ROOT}/k8s/runners/traffic-simulator.yaml" | \
  awk '/image: /{print; print "          imagePullPolicy: Never"; next}1' | \
  kubectl apply -f -

# ── 13. Wait for pods ─────────────────────────────────────────────────────────
log "Waiting for service pods to be ready (2 min timeout per service)..."
for SVC in "${SERVICES[@]}"; do
  kubectl rollout status deployment/"${SVC}" -n demo --timeout=120s 2>/dev/null \
    || log "  WARNING: ${SVC} not ready yet (check: kubectl get pods -n demo)"
done

# ── 14. Wire Anway → minikube ─────────────────────────────────────────────────
KUBECONFIG_PATH="${HOME}/.kube/config"
MINIKUBE_IP="$(minikube ip)"
API_GW_PORT="$(kubectl get svc api-gateway -n demo -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo '30080')"
GRAFANA_PORT="$(kubectl get svc kube-prometheus-stack-grafana -n observability -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo '')"
PROMETHEUS_PORT="$(kubectl get svc kube-prometheus-stack-prometheus -n observability -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo '')"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Demo stack ready in minikube"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Minikube IP : ${MINIKUBE_IP}"
echo ""
echo " Port-forward:"
echo "   Grafana       : kubectl port-forward svc/kube-prometheus-stack-grafana 3001:80 -n observability"
echo "                   → http://localhost:3001  (admin / admin)"
echo "   Prometheus    : kubectl port-forward svc/kube-prometheus-stack-prometheus 9090:9090 -n observability"
echo "   Alertmanager  : kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 -n observability"
echo "   API Gateway   : kubectl port-forward svc/api-gateway 8080:3000 -n demo"
echo ""
echo " Pods:"
kubectl get pods -n demo --no-headers | awk '{printf "   %-40s %s\n", $1, $3}'
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Wire Anway → minikube (for pipeline deploys)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Add to apps/gateway/.env:"
echo "   KUBECONFIG=${KUBECONFIG_PATH}"
echo "   HELM_CHART=oci://registry-1.docker.io/bitnamicharts/common  # or path to a demo chart"
echo "   HELM_NAMESPACE_PROD=demo"
echo "   ANWAY_WEBHOOK_TOKEN=${ANWAY_WEBHOOK_TOKEN}"
echo ""
echo " Then in Anway UI: register the GitHub connector to get deploy_trigger events."
echo " Each push → gate surfaces in Pipelines → approve → Anway deploys to minikube."
echo ""
echo " Alertmanager → Anway webhook already configured."
echo " Alerts will appear in Anway War Room once a trigger fires."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
