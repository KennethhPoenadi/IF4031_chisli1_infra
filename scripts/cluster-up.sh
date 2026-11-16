set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

CLUSTER_PROVIDER="${CLUSTER_PROVIDER:-kind}"

case "$CLUSTER_PROVIDER" in
  kind|k3s) ;;
  *)
    echo "ERROR: CLUSTER_PROVIDER harus bernilai kind atau k3s, bukan $CLUSTER_PROVIDER" >&2
    exit 1
    ;;
esac

command -v kubectl >/dev/null || {
  echo "ERROR: kubectl tidak terpasang di runner" >&2
  exit 1
}

start_kind() {
  command -v terraform >/dev/null || {
    echo "ERROR: terraform tidak terpasang di runner" >&2
    exit 1
  }
  mkdir -p "$(dirname "$TF_BACKEND_PATH")" "$(dirname "$KUBECONFIG")"
  (
    cd terraform
    terraform init -input=false -backend-config="path=${TF_BACKEND_PATH}"
    terraform apply -input=false -auto-approve
  )
}

validate_k3s() {
  if [ ! -r "$KUBECONFIG" ]; then
    echo "ERROR: kubeconfig K3s tidak dapat dibaca: $KUBECONFIG" >&2
    exit 1
  fi

  kubectl cluster-info >/dev/null
  kubectl wait --for=condition=Ready node --all --timeout=180s

  node_count="$(kubectl get nodes -o name | wc -l | tr -d ' ')"
  if [ "$node_count" -lt 2 ]; then
    echo "ERROR: cluster demo membutuhkan minimal 2 node; ditemukan $node_count" >&2
    exit 1
  fi

  versions="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}')"
  non_k3s_count="$(printf '%s\n' "$versions" | grep -Fvc '+k3s' || true)"
  if [ "$non_k3s_count" -ne 0 ]; then
    echo "ERROR: mode k3s menemukan node yang bukan distribusi K3s" >&2
    printf '%s\n' "$versions" >&2
    exit 1
  fi

  control_plane_count="$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o name | wc -l | tr -d ' ')"
  if [ "$control_plane_count" -lt 1 ] || [ "$control_plane_count" -ge "$node_count" ]; then
    echo "ERROR: topologi membutuhkan minimal 1 control-plane dan 1 worker non-control-plane" >&2
    exit 1
  fi

  ingress_count="$(kubectl get nodes -l ingress-ready=true -o name | wc -l | tr -d ' ')"
  if [ "$ingress_count" -lt 1 ]; then
    echo "ERROR: tidak ada node dengan label ingress-ready=true" >&2
    exit 1
  fi

  provider_ids="$(kubectl get nodes -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}')"
  if printf '%s\n' "$provider_ids" | grep -Eq '^(kind|docker)://'; then
    echo "ERROR: cluster berbasis container dengan kernel bersama tidak boleh dipakai untuk demo" >&2
    exit 1
  fi

  k3d_count="$(kubectl get nodes -l k3d.io/cluster -o name | wc -l | tr -d ' ')"
  if [ "$k3d_count" -ne 0 ]; then
    echo "ERROR: node k3d berbagi kernel container dan tidak boleh dipakai untuk demo" >&2
    exit 1
  fi
}

case "$CLUSTER_PROVIDER" in
  kind)
    echo "==> Menyiapkan cluster kind untuk development"
    start_kind
    ;;
  k3s)
    echo "==> Memvalidasi cluster K3s untuk demo"
    validate_k3s
    ;;
esac

echo "Cluster $CLUSTER_PROVIDER siap. Gunakan: export KUBECONFIG=$KUBECONFIG"
kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,CONTROL-PLANE:.metadata.labels.node-role\.kubernetes\.io/control-plane,INTERNAL-IP:.status.addresses[?(@.type=="InternalIP")].address,KERNEL:.status.nodeInfo.kernelVersion,KUBERNETES:.status.nodeInfo.kubeletVersion'
