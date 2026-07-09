variable "region" {
  default = "us-ashburn-1"
}

variable "compartment_ocid" {
  description = "Compartment to deploy into (tenancy root if no sub-compartment)"
}

variable "availability_domain" {
  description = "AD name, e.g. hJJE:US-ASHBURN-AD-1"
}

variable "image_ocid" {
  description = "Default image OCID (Ubuntu 22.04) for the region"
}

# Per-role image override — e.g. DenseIO E6 shapes only support Oracle Linux
variable "image_ocid_overrides" {
  type    = map(string)
  default = {}
}

# Per-role AD override — DenseIO host capacity varies by AD (subnet is regional)
variable "availability_domain_overrides" {
  type    = map(string)
  default = {}
}

variable "public_key_path" {
  default = "~/.ssh/redpanda_oci.pub"
}

# Flex shapes: OCPUs and memory are free parameters, which is what
# makes the post-tier-1 custom-shape scale-up a tfvars-only change.
variable "shapes" {
  type = map(string)
  default = {
    redpanda = "VM.Standard.E4.Flex"
    client   = "VM.Standard.E4.Flex"
  }
}

variable "ocpus" {
  type = map(number)
  default = {
    redpanda = 2 # 4 vCPUs
    client   = 4 # 8 vCPUs
  }
}

variable "memory_gbs" {
  type = map(number)
  default = {
    redpanda = 8
    client   = 16
  }
}

variable "num_instances" {
  type = map(number)
  default = {
    redpanda = 3
    client   = 4
  }
}

variable "boot_volume_gbs" {
  type = map(number)
  default = {
    redpanda = 200
    client   = 100
  }
}

# 10 = balanced, 20 = higher performance, 30+ = ultra (block volume VPUs/GB)
variable "boot_volume_vpus" {
  type = map(number)
  default = {
    redpanda = 20
    client   = 10
  }
}

variable "monitoring_instance_count" {
  default = 1
}

variable "vcn_cidr" {
  default = "10.0.0.0/16"
}

variable "subnet_cidr" {
  default = "10.0.0.0/24"
}
