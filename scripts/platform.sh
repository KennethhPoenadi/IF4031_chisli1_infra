set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
source platform/versions.env

for v in TRAEFIK_VERSION METRICS_SERVER_VERSION KYVERNO_VERSION ARGOCD_VERSION KEDA_VERSION; do
  if [ -z "${!v:-}" ]; then
    echo "ERROR: $v kosong. Jalankan ./scripts/pin-versions.sh lalu commit platform/versions.env" >&2
    exit 1
  fi
done

kubectl cluster-info >/dev/null

helm repo add traefik        https://traefik.github.io/charts --force-update >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update >/dev/null
helm repo add kyverno        https://kyverno.github.io/kyverno/ --force-update >/dev/null
helm repo add argo           https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo add kedacore       https://kedacore.github.io/charts --force-update >/dev/null
helm repo update >/dev/null

if kubectl get deployment -n kyverno >/dev/null 2>&1; then
  echo "==> Menunggu Kyverno siap"
  kubectl wait --for=condition=Available deployment --all -n kyverno --timeout=300s
fi

echo "==> Traefik $TRAEFIK_VERSION"
helm upgrade --install traefik traefik/traefik \
  -n traefik --create-namespace --version "$TRAEFIK_VERSION" \
  -f platform/traefik-values.yaml --wait --timeout 5m

echo "==> metrics-server $METRICS_SERVER_VERSION"
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system --version "$METRICS_SERVER_VERSION" \
  -f platform/metrics-server-values.yaml --wait --timeout 5m

echo "==> Kyverno $KYVERNO_VERSION"
helm upgrade --install kyverno kyverno/kyverno \
  -n kyverno --create-namespace --version "$KYVERNO_VERSION" \
  --wait --timeout 8m
kubectl wait --for=condition=Available deployment --all -n kyverno --timeout=300s

# KEDA harus terpasang sebelum Argo CD menyinkronkan ScaledObject konsumer.
echo "==> KEDA $KEDA_VERSION"
helm upgrade --install keda kedacore/keda \
  -n keda --create-namespace --version "$KEDA_VERSION" \
  --wait --timeout 5m

echo "==> Argo CD $ARGOCD_VERSION"
helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace --version "$ARGOCD_VERSION" \
  -f platform/argocd-values.yaml --wait --timeout 8m

echo "==> Namespace dev dan $APP_NAMESPACE"
for ns in dev "$APP_NAMESPACE"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

kubectl get pods -A
