variable "cluster_name" {
  type    = string
  default = "xops"
}

variable "kubeconfig_path" {
  type        = string
  description = "Lokasi kubeconfig yang ditulis provider kind"
  default     = "~/.kube/xops-config"
}

variable "http_port" {
  type        = number
  description = "Port host untuk HTTP. Ganti (mis. 8080) jika port 80 dipakai aplikasi lain di Windows."
  default     = 80
}

variable "https_port" {
  type    = number
  default = 443
}

variable "worker_count" {
  type        = number
  description = "Jumlah worker node. 0 = single node (hemat RAM)."
  default     = 0
}

variable "node_image" {
  type        = string
  description = "Image node kind (opsional). Null = default provider."
  default     = null
}
