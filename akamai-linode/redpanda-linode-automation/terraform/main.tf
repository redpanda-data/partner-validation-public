terraform {
  required_version = ">= 1.0"

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
  }
}

provider "linode" {
  token = var.linode_token
}

# LKE Cluster
resource "linode_lke_cluster" "redpanda" {
  label       = var.cluster_name
  k8s_version = var.k8s_version
  region      = var.region
  tags        = ["redpanda", "validation"]

  pool {
    type  = var.node_type
    count = var.node_count
    autoscaler {
      min = var.node_count
      max = var.node_count + 3  # Allow scale up to +3 nodes
    }
  }

  lifecycle {
    ignore_changes = [
      pool[0].count  # Allow autoscaler to manage count
    ]
  }
}

# Object Storage Bucket for Tiered Storage
resource "linode_object_storage_bucket" "redpanda_tiered" {
  cluster = var.object_storage_cluster
  label   = var.object_storage_bucket
  acl     = "private"
}

# Object Storage Access Keys
resource "linode_object_storage_key" "redpanda_tiered_key" {
  label = "${var.cluster_name}-tiered-storage"

  bucket_access {
    bucket_name = linode_object_storage_bucket.redpanda_tiered.label
    cluster     = linode_object_storage_bucket.redpanda_tiered.cluster
    permissions = "read_write"
  }
}

# Save kubeconfig to file
resource "local_file" "kubeconfig" {
  content  = base64decode(linode_lke_cluster.redpanda.kubeconfig)
  filename = pathexpand("~/.kube/redpanda-linode-kubeconfig")
  file_permission = "0600"
}
