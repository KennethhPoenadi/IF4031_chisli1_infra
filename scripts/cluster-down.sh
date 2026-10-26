set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
cd terraform
terraform init -input=false -backend-config="path=${TF_BACKEND_PATH}"
terraform destroy -input=false -auto-approve
