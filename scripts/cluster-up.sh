set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

mkdir -p "$(dirname "$TF_BACKEND_PATH")" "$HOME/.kube"

cd terraform
terraform init -input=false -backend-config="path=${TF_BACKEND_PATH}"
terraform apply -input=false -auto-approve

echo "Cluster siap. Gunakan: export KUBECONFIG=$KUBECONFIG"
kubectl get nodes
