# Support fleet for OKE-based runs: OMB clients + monitoring ONLY
# (brokers live in the OKE node pool — no VM brokers)
region              = "us-ashburn-1"
availability_domain = "hJJE:US-ASHBURN-AD-1"
image_ocid          = "ocid1.image.oc1.iad.aaaaaaaaxuoxbmbtrnnkm6n5zcjyu4ac6ocmdcxpdxr6s7ndrcfhroc5maiq"
public_key_path     = "~/.ssh/redpanda_oci.pub"

# DenseIO only boots Oracle Linux — clients get OL9 (cloud-init handles opc user)
image_ocid_overrides = {
  client = "ocid1.image.oc1.iad.aaaaaaaa4n6qszi7i4u4vpphmxnv5djj26hewj5gtdfw2z7f7mchb6xue7ea"
}

shapes = {
  redpanda = "VM.Standard.E4.Flex" # unused (count 0)
  client   = "VM.DenseIO.E4.Flex"  # standard-e4 limit pulled 2026-07-09; DenseIO grant intact
}

ocpus = {
  redpanda = 2
  client   = 8   # DenseIO E4 fixed config 8/128/1
}

memory_gbs = {
  redpanda = 8
  client   = 128 # fixed with 8 OCPU
}

num_instances = {
  redpanda = 0
  client   = 12
}

boot_volume_gbs = {
  redpanda = 100
  client   = 100
}

boot_volume_vpus = {
  redpanda = 10
  client   = 10
}
