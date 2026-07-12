#!/usr/bin/env bash
# Full stack deploy — run once after terraform apply to bootstrap K8s manifests
# Usage: ./scripts/deploy.sh
# Requires: .env sourced, aws cli + kubectl + helm in PATH

set -euo pipefail

# Load env (never commit .env)
if [ -f "$(dirname "$0")/../.env" ]; then
  set -a; source "$(dirname "$0")/../.env"; set +a
fi

: "${AWS_REGION:?AWS_REGION must be set}"
: "${TF_VAR_grafana_admin_password:?TF_VAR_grafana_admin_password must be set}"
: "${ANWAY_WEBHOOK_URL:?ANWAY_WEBHOOK_URL must be set}"

# Pull outputs from terraform
CLUSTER_NAME=$(terraform -chdir=terraform output -raw cluster_name)
ECR_REGISTRY=$(terraform -chdir=terraform output -raw ecr_registry)
APP_IRSA_ROLE_ARN=$(terraform -chdir=terraform output -raw app_irsa_role_arn)

echo "==> Cluster: $CLUSTER_NAME | ECR: $ECR_REGISTRY"

# Update kubeconfig
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"

# Namespaces + service account (with IRSA annotation)
kubectl apply -f k8s/namespaces/namespaces.yaml
sed "s|\${APP_IRSA_ROLE_ARN}|${APP_IRSA_ROLE_ARN}|g" k8s/namespaces/service-account.yaml | kubectl apply -f -

# External Secrets Operator (needs to exist before ExternalSecret resources)
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm upgrade --install external-secrets external-secrets/external-secrets -n kube-system --wait

# ConfigMap + secrets injection
kubectl apply -f k8s/services/configmap.yaml
kubectl apply -f k8s/services/secrets-injection.yaml

# Wait for secrets to sync
echo "==> Waiting for secrets to sync from Secrets Manager..."
sleep 30

# Deploy services (use :latest if no tag provided)
IMAGE_TAG="${IMAGE_TAG:-latest}"
for SVC_DIR in k8s/services/*/; do
  SVC=$(basename "$SVC_DIR")
  if [ -f "$SVC_DIR/deployment.yaml" ]; then
    sed \
      -e "s|\${ECR_REGISTRY}|${ECR_REGISTRY}|g" \
      -e "s|\${IMAGE_TAG}|${IMAGE_TAG}|g" \
      "$SVC_DIR/deployment.yaml" | kubectl apply -f -
  fi
done

echo "==> Waiting for service rollout..."
for SVC in api-gateway auth-service user-service product-service cart-service order-service payment-service inventory-service notification-service search-service recommendation-service review-service shipping-service analytics-service admin-service; do
  kubectl rollout status deployment/$SVC -n demo --timeout=120s || echo "WARNING: $SVC not ready"
done

# Observability stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

sed \
  -e "s|\${GRAFANA_ADMIN_PASSWORD}|${TF_VAR_grafana_admin_password}|g" \
  -e "s|\${ANWAY_WEBHOOK_URL}|${ANWAY_WEBHOOK_URL}|g" \
  k8s/observability/prometheus/values.yaml > /tmp/prom-values.yaml

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n observability --create-namespace \
  -f /tmp/prom-values.yaml --timeout 10m

helm upgrade --install loki grafana/loki-stack \
  -n observability \
  -f k8s/observability/loki/values.yaml --timeout 5m

kubectl apply -f k8s/observability/grafana/dashboards-configmap.yaml

# Runners
sed \
  -e "s|\${ECR_REGISTRY}|${ECR_REGISTRY}|g" \
  -e "s|\${IMAGE_TAG}|${IMAGE_TAG}|g" \
  k8s/runners/traffic-simulator.yaml | kubectl apply -f -

sed \
  -e "s|\${ECR_REGISTRY}|${ECR_REGISTRY}|g" \
  -e "s|\${IMAGE_TAG}|${IMAGE_TAG}|g" \
  k8s/runners/chaos-runner.yaml | kubectl apply -f -

echo ""
echo "==> Stack deployed successfully!"
echo ""
echo "Services:"
kubectl get svc -n demo
echo ""
echo "Pods:"
kubectl get pods -n demo
echo ""
echo "Grafana (port-forward):"
echo "  kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n observability"
echo "  Login: admin / <TF_VAR_grafana_admin_password>"
