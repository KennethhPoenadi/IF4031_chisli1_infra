provider "kind" {}

locals {
  control_plane_patch = <<-EOT
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  EOT
}

resource "kind_cluster" "xops" {
  name            = var.cluster_name
  node_image      = var.node_image
  wait_for_ready  = true
  kubeconfig_path = pathexpand(var.kubeconfig_path)

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role                   = "control-plane"
      kubeadm_config_patches = [local.control_plane_patch]

      extra_port_mappings {
        container_port = 80
        host_port      = var.http_port
      }

      extra_port_mappings {
        container_port = 443
        host_port      = var.https_port
      }
    }

    dynamic "node" {
      for_each = range(var.worker_count)
      content {
        role = "worker"
      }
    }
  }
}
