# Tier 1 — 60 MB/s target, 3 brokers
# OCI equivalent of Linode g7-dedicated-8gb (4 vCPU / 8 GB): E4.Flex 2 OCPU / 8 GB
region              = "us-ashburn-1"
# compartment_ocid is tenancy-specific and intentionally NOT committed.
# Put it in compartment.auto.tfvars (gitignored) or export TF_VAR_compartment_ocid.
availability_domain = "hJJE:US-ASHBURN-AD-1"
image_ocid          = "ocid1.image.oc1.iad.aaaaaaaaxuoxbmbtrnnkm6n5zcjyu4ac6ocmdcxpdxr6s7ndrcfhroc5maiq"
public_key_path     = "~/.ssh/redpanda_oci.pub"

shapes = {
  redpanda = "VM.Standard.E4.Flex"
  client   = "VM.Standard.E4.Flex"
}

ocpus = {
  redpanda = 2
  client   = 4
}

memory_gbs = {
  redpanda = 8
  client   = 16
}

num_instances = {
  redpanda = 3
  client   = 4
}

boot_volume_gbs = {
  redpanda = 200
  client   = 100
}

boot_volume_vpus = {
  redpanda = 20
  client   = 10
}
