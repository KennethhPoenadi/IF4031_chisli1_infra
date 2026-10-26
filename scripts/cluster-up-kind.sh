set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
mkdir -p "$HOME/.kube"
if kind get clusters 2>/dev/null | grep -qx xops; then
  echo "Cluster xops sudah ada."
else
  kind create cluster --config terraform/kind-config.fallback.yaml --kubeconfig "$KUBECONFIG"
fi
kind export kubeconfig --name xops --kubeconfig "$KUBECONFIG"
kubectl get nodes
