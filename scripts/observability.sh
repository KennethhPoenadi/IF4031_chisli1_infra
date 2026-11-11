#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
source platform/versions.env

NS=observability
O=platform/observability

for v in PROMETHEUS_VERSION GRAFANA_VERSION LOKI_VERSION TEMPO_VERSION ALLOY_VERSION; do
  if [ -z "${!v:-}" ]; then
    echo "ERROR: $v kosong. Jalankan ./scripts/pin-versions.sh lalu commit platform/versions.env" >&2
    exit 1
  fi
done

kubectl cluster-info >/dev/null

helm repo add grafana              https://grafana.github.io/helm-charts --force-update >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo update >/dev/null

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl -n "$NS" get secret grafana-admin >/dev/null 2>&1; then
  pass="${GRAFANA_ADMIN_PASSWORD:-$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)}"
  kubectl -n "$NS" create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-literal=admin-password="$pass" >/dev/null
  echo "Secret grafana-admin dibuat. Baca kata sandinya dengan:"
  echo "  kubectl -n $NS get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d"
fi

install() {
  echo "==> $1 $3"
  helm upgrade --install "$1" "$2" -n "$NS" --version "$3" -f "$4" --wait --timeout 6m
}

install loki       grafana/loki                        "$LOKI_VERSION"       "$O/loki-values.yaml"
install tempo      grafana/tempo                       "$TEMPO_VERSION"      "$O/tempo-values.yaml"
install prometheus prometheus-community/prometheus     "$PROMETHEUS_VERSION" "$O/prometheus-values.yaml"
install alloy      grafana/alloy                       "$ALLOY_VERSION"      "$O/alloy-values.yaml"
install grafana    grafana/grafana                     "$GRAFANA_VERSION"    "$O/grafana-values.yaml"

echo "==> dashboard"
for f in "$O"/dashboards/*.json; do
  name="dashboard-$(basename "$f" .json)"
  kubectl -n "$NS" create configmap "$name" --from-file="$(basename "$f")=$f" --dry-run=client -o yaml \
    | kubectl label --local -f - grafana_dashboard=1 -o yaml \
    | kubectl apply -f -
done

kubectl -n "$NS" get pods
echo "Grafana: http://grafana.localtest.me (pengguna: admin)"
