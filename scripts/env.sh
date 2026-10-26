export KUBECONFIG="$HOME/.kube/xops-config"
export TF_BACKEND_PATH="${TF_BACKEND_PATH:-$HOME/.xops/terraform.tfstate}"
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"
