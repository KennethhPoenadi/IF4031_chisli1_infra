# Mengambil versi chart stabil terbaru lalu menuliskannya ke platform/versions.env.
# Jalankan SEKALI, lalu commit hasilnya agar instalasi reproducible.
set -euo pipefail
cd "$(dirname "$0")/.."

helm repo add traefik        https://traefik.github.io/charts --force-update >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update >/dev/null
helm repo add kyverno        https://kyverno.github.io/kyverno/ --force-update >/dev/null
helm repo update >/dev/null

latest() {
  helm search repo "$1" -o json | jq -r --arg n "$1" '[.[] | select(.name==$n)][0].version'
}

T=$(latest traefik/traefik)
M=$(latest metrics-server/metrics-server)
K=$(latest kyverno/kyverno)

cat > platform/versions.env <<EOF
# Dihasilkan oleh scripts/pin-versions.sh
TRAEFIK_VERSION=$T
METRICS_SERVER_VERSION=$M
KYVERNO_VERSION=$K
EOF
cat platform/versions.env
