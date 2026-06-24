# --------------------------------------------------------------------------
# Bootstrap: strip the default AWS VPC CNI (aws-node) and kube-proxy so that
# Cilium can fully own pod networking and service routing.
# --------------------------------------------------------------------------
resource "null_resource" "remove_default_cni" {
  triggers = {
    cluster = module.eks.cluster_name
    region  = var.region
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -euo pipefail
      export PATH="/opt/homebrew/bin:$PATH"
      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region} --kubeconfig ./.bootstrap-kubeconfig
      export KUBECONFIG=./.bootstrap-kubeconfig
      kubectl -n kube-system delete daemonset aws-node    --ignore-not-found
      kubectl -n kube-system delete daemonset kube-proxy  --ignore-not-found
    EOT
  }

  depends_on = [module.eks]
}

# Render Cilium values, injecting the EKS API endpoint so kube-proxy
# replacement can reach the API server directly.
locals {
  eks_api_host = replace(module.eks.cluster_endpoint, "https://", "")

  # Only wire up the pull secret when its JSON has been supplied.
  create_pull_secret = trimspace(var.isovalent_pull_secret_json) != ""
}

# Image pull secret for the Isovalent Enterprise images on quay.io/isovalent.
resource "kubernetes_secret" "isovalent_pull_secret" {
  count = local.create_pull_secret ? 1 : 0

  metadata {
    name      = var.isovalent_pull_secret_name
    namespace = "kube-system"
  }

  type = "kubernetes.io/dockerconfigjson"

  data = {
    ".dockerconfigjson" = var.isovalent_pull_secret_json
  }
}

resource "helm_release" "cilium" {
  name       = "cilium"
  repository = var.isovalent_helm_repo
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"

  # Allow nodes/pods time to settle.
  wait    = true
  timeout = 900

  values = [
    templatefile("${path.module}/../cilium/values.yaml.tftpl", {
      eks_api_host     = local.eks_api_host
      eks_api_port     = "443"
      pull_secret_name = local.create_pull_secret ? var.isovalent_pull_secret_name : ""
      timescape_target = var.enable_timescape ? "hubble-timescape-export.${var.timescape_namespace}.svc.cluster.local:4260" : ""
    })
  ]

  depends_on = [
    null_resource.remove_default_cni,
    kubernetes_secret.isovalent_pull_secret,
  ]
}
