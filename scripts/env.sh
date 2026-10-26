# Di-source oleh script lain dan job CI. Jangan dijalankan langsung.
export KUBECONFIG="$HOME/.kube/xops-config"
export TF_BACKEND_PATH="${TF_BACKEND_PATH:-$HOME/.xops/terraform.tfstate}"
