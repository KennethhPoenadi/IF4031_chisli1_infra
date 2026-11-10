set -euo pipefail
cd "$(dirname "$0")/.."

helm repo add traefik        https://traefik.github.io/charts --force-update >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update >/dev/null
helm repo add kyverno        https://kyverno.github.io/kyverno/ --force-update >/dev/null
helm repo add argo                 https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo add grafana              https://grafana.github.io/helm-charts --force-update >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null
helm repo update >/dev/null

latest() {
  helm search repo "$1" -o json | jq -r --arg n "$1" '[.[] | select(.name==$n)][0].version'
}

T=$(latest traefik/traefik)
M=$(latest metrics-server/metrics-server)
K=$(latest kyverno/kyverno)
A=$(latest argo/argo-cd)
P=$(latest prometheus-community/prometheus)
G=$(latest grafana/grafana)
L=$(latest grafana/loki)
TP=$(latest grafana/tempo)
AL=$(latest grafana/alloy)

cat > platform/versions.env <<EOF
TRAEFIK_VERSION=$T
METRICS_SERVER_VERSION=$M
KYVERNO_VERSION=$K
ARGOCD_VERSION=$A
PROMETHEUS_VERSION=$P
GRAFANA_VERSION=$G
LOKI_VERSION=$L
TEMPO_VERSION=$TP
ALLOY_VERSION=$AL
EOF
cat platform/versions.env
