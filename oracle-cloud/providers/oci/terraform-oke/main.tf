# OKE cluster for the Partner Kubernetes-based Redpanda benchmark.
# Reuses the benchmark VCN/subnet from ../terraform (security list allows
# all intra-VCN traffic, plus 6443 public for kubectl).
#
# Node pool mirrors the target DenseIO.E4.Flex8 CPU/RAM ratio (8 OCPU,
# 16 GB/OCPU) on Standard E4 + block volumes until Oracle grants DenseIO
# quota/capacity — then switch node_shape to VM.DenseIO.E4.Flex and
# storage to local NVMe.

terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.0"
    }
  }
}

provider "oci" {
  config_file_profile = "DEFAULT"
  region              = var.region
}

variable "region" {
  default = "us-ashburn-1"
}

variable "compartment_ocid" {}

variable "vcn_id" {
  default = "ocid1.vcn.oc1.iad.CHANGE_ME"  # refresh after terraform apply — see REDEPLOY_CHECKLIST
}

variable "subnet_id" {
  # benchmark regional public subnet (API endpoint, service LBs)
  default = "ocid1.subnet.oc1.iad.CHANGE_ME"  # refresh after terraform apply — see REDEPLOY_CHECKLIST
}

variable "node_subnet_id" {
  # dedicated node subnet — OKE forbids node pools on the service-LB subnet
  default = "ocid1.subnet.oc1.iad.CHANGE_ME"  # refresh after terraform apply — see REDEPLOY_CHECKLIST
}

variable "kubernetes_version" {
  default = "v1.34.2"
}

variable "node_image_ocid" {
  # Oracle-Linux-9.7 OKE-1.34.2 (x86)
  default = "ocid1.image.oc1.iad.aaaaaaaay46std52b4dzl3w4xyovodzygd6volmvtaetgs3e2znoasxvoyna"
}

variable "availability_domain" {
  default = "hJJE:US-ASHBURN-AD-1"
}

variable "node_count" {
  default = 6
}

# VM.Standard.E4.Flex (block volumes) or VM.DenseIO.E6.Ax.Flex (local NVMe —
# confirmed compatible with the OKE node image). DenseIO E6: 12 GB/OCPU
# default, hardware only in AD-1.
variable "node_shape" {
  default = "VM.Standard.E4.Flex"
}

variable "node_ocpus" {
  default = 8
}

variable "node_memory_gbs" {
  default = 128
}

variable "public_key_path" {
  default = "~/.ssh/redpanda_oci.pub"
}

resource "oci_containerengine_cluster" "benchmark" {
  compartment_id     = var.compartment_ocid
  kubernetes_version = var.kubernetes_version
  name               = "redpanda-benchmark-oke"
  vcn_id             = var.vcn_id
  type               = "ENHANCED_CLUSTER"

  endpoint_config {
    is_public_ip_enabled = true
    subnet_id            = var.subnet_id
  }

  options {
    service_lb_subnet_ids = [var.subnet_id]
  }
}

resource "oci_containerengine_node_pool" "brokers" {
  cluster_id         = oci_containerengine_cluster.benchmark.id
  compartment_id     = var.compartment_ocid
  kubernetes_version = var.kubernetes_version
  name               = "redpanda-brokers"
  node_shape         = var.node_shape

  node_shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gbs
  }

  node_source_details {
    source_type             = "IMAGE"
    image_id                = var.node_image_ocid
    boot_volume_size_in_gbs = 200
  }

  node_config_details {
    size = var.node_count

    placement_configs {
      availability_domain = var.availability_domain
      subnet_id           = var.node_subnet_id
    }
  }

  ssh_public_key = file(var.public_key_path)
}

output "cluster_id" {
  value = oci_containerengine_cluster.benchmark.id
}

output "cluster_endpoint" {
  value = oci_containerengine_cluster.benchmark.endpoints
}
