# Partner baseline — spec-exact broker fleet on local NVMe
# 6× VM.DenseIO.E6.Ax.Flex 8 OCPU (16 vCPU) / 96 GB / 6.8TB NVMe / 8 Gbps
# (DenseIO E4 quota is 0 in this tenancy; E6 is the newer generation with
# 576-core quota — see BLENDED_WORKLOAD_SPEC.md)
# Clients sized for ~7 GiB/s aggregate through OMB workers.
region              = "us-ashburn-1"
# compartment_ocid comes from compartment.auto.tfvars (gitignored)
availability_domain = "hJJE:US-ASHBURN-AD-1"
image_ocid          = "ocid1.image.oc1.iad.aaaaaaaaxuoxbmbtrnnkm6n5zcjyu4ac6ocmdcxpdxr6s7ndrcfhroc5maiq"

# DenseIO shapes only support Oracle Linux; A4 bare metal is aarch64 (Ampere)
image_ocid_overrides = {
  redpanda = "ocid1.image.oc1.iad.aaaaaaaa77yanzfh2dh2ezmvcptkd2elz6w3hhvxv6xcikwysmu5ef3ws6ha"
}

# E6 VM: only in AD-1, out of capacity. A4 BM: only offered in AD-3.
# Subnet is regional; clients/monitoring stay in AD-1.
availability_domain_overrides = {
  redpanda = "hJJE:US-ASHBURN-AD-3"
}
public_key_path     = "~/.ssh/redpanda_oci.pub"

# VM.DenseIO.E6.Ax.Flex: AD-1 out of host capacity 2026-07-06 (only AD with
# E6 hardware). Falling back to bare metal Ampere NVMe — quota for exactly 6.
shapes = {
  redpanda = "BM.DenseIO.A4.Ax.72"
  client   = "VM.Standard.E4.Flex"
}

ocpus = {
  redpanda = 8
  client   = 16
}

memory_gbs = {
  redpanda = 96
  client   = 64
}

num_instances = {
  redpanda = 6
  client   = 8
}

boot_volume_gbs = {
  redpanda = 100
  client   = 100
}

boot_volume_vpus = {
  redpanda = 10
  client   = 10
}
