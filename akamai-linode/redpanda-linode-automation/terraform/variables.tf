variable "linode_token" {
  description = "Linode API Token"
  type        = string
  sensitive   = true
}

variable "cluster_name" {
  description = "Name of the LKE cluster"
  type        = string
  default     = "redpanda-validation"
}

variable "k8s_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.28"
}

variable "region" {
  description = "Linode region"
  type        = string
  default     = "us-east"
}

variable "node_type" {
  description = "Linode node type (plan)"
  type        = string
  default     = "g6-dedicated-8"  # Dedicated 16GB
}

variable "node_count" {
  description = "Number of nodes in the pool"
  type        = number
  default     = 3
}

variable "object_storage_cluster" {
  description = "Object Storage cluster region"
  type        = string
  default     = "us-east-1"
}

variable "object_storage_bucket" {
  description = "Object Storage bucket name"
  type        = string
}
