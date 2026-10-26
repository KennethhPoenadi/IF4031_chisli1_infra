set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
source platform/versions.env

for v in TRAEFIK_VERSION METRICS_SERVER_VERSION KYVERNO_VERSION; do
  if [ -z "${!v:-}" ]; then
    echo "ERROR: $v kosong. Jalankan ./scripts/pin-versions.sh lalu commit platform/versions.env" >&2
    exit 1
  fi
done

kubectl cluster-info >/dev/null

helm repo add traefik        https://traefik.github.io/charts --force-update >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update >/dev/null
helm repo add kyverno        https://kyverno.github.io/kyverno/ --force-update >/dev/null
helm repo update >/dev/null

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

echo "==> Namespace dev & prod"
for ns in dev prod; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

kubectl get pods -A
