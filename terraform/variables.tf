variable "region" {
  description = "AWS region (Sydney)."
  type        = string
  default     = "ap-southeast-2"
}

variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
  default     = "isovalent-syd"
}

variable "cluster_version" {
  description = "Kubernetes control plane version."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "instance_type" {
  description = "EC2 instance type for the managed node group."
  type        = string
  default     = "m5.large"
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

# --------------------------------------------------------------------------
# Isovalent Enterprise
# --------------------------------------------------------------------------
variable "isovalent_helm_repo" {
  description = "Isovalent Enterprise Helm repository."
  type        = string
  default     = "https://helm.isovalent.com"
}

variable "cilium_version" {
  description = "Isovalent Enterprise Cilium Helm chart / image version (chart 'cilium')."
  type        = string
  default     = "1.18.10"
}

variable "tetragon_version" {
  description = "Isovalent Enterprise Tetragon Helm chart version (chart 'tetragon')."
  type        = string
  default     = "1.18.3"
}

# Contents of the Isovalent/Cisco-issued image pull secret, as a complete
# Docker config JSON (the file you get from Isovalent support / the customer
# portal). Leave empty to skip secret creation (e.g. when supplied out-of-band).
# Provide via TF_VAR_isovalent_pull_secret_json or a *.auto.tfvars file that is
# NOT committed to git.
variable "isovalent_pull_secret_json" {
  description = "Docker config JSON for pulling quay.io/isovalent Enterprise images."
  type        = string
  default     = ""
  sensitive   = true
}

variable "isovalent_pull_secret_name" {
  description = "Name of the Kubernetes image pull secret used by the Enterprise charts."
  type        = string
  default     = "isovalent-pull-secret"
}

# --------------------------------------------------------------------------
# Hubble Timescape + Enterprise Hubble UI (Phase 2 — opt-in)
# Correlated, long-term store for Hubble network flows AND Tetragon events.
# Disabled by default: setting this to false keeps the main plan unchanged.
# Requires object storage (S3) + ClickHouse, both provisioned here.
# --------------------------------------------------------------------------
variable "enable_timescape" {
  description = "Provision Hubble Timescape, ClickHouse, and the Enterprise Hubble UI."
  type        = bool
  default     = false
}

variable "timescape_namespace" {
  description = "Namespace for Timescape, ClickHouse, and the Enterprise Hubble UI."
  type        = string
  default     = "hubble-timescape"
}

variable "timescape_version" {
  description = "hubble-timescape Helm chart version (helm.isovalent.com)."
  type        = string
  default     = "1.18.8"
}

variable "timescape_flows_ttl" {
  description = <<-EOT
    Flow retention for Timescape lite (migrate.flows.ttl). Lite stores data on
    node EPHEMERAL disk (~1 GB/hour at demo traffic, ~20 GB node capacity), so
    keep this bounded. 6h (~6 GB) is a safe default for a demo day; raise only
    if you attach a persistent volume to the lite ClickHouse.
  EOT
  type        = string
  default     = "6h"
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    Project   = "isovalent-eks"
    Stack     = "cilium-enterprise"
    ManagedBy = "terraform"
    Region    = "ap-southeast-2"
  }
}
