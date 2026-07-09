# Enable root SSH so the universal scripts (tools/form-redpanda-cluster.sh,
# install-redpanda.sh, install-omb-tools.sh) work unchanged — OCI images
# only permit the default user (ubuntu on Ubuntu, opc on Oracle Linux).
locals {
  cloud_init = base64encode(<<-EOF
    #!/bin/bash
    mkdir -p /root/.ssh
    for u in ubuntu opc; do
      if [ -f /home/$u/.ssh/authorized_keys ]; then
        cp /home/$u/.ssh/authorized_keys /root/.ssh/authorized_keys
        break
      fi
    done
    chmod 600 /root/.ssh/authorized_keys
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    systemctl restart ssh 2>/dev/null || systemctl restart sshd
  EOF
  )
}

resource "oci_core_instance" "redpanda" {
  count = var.num_instances["redpanda"]

  availability_domain = lookup(var.availability_domain_overrides, "redpanda", var.availability_domain)
  compartment_id      = var.compartment_ocid
  display_name        = "redpanda-broker-${count.index}"
  shape               = var.shapes["redpanda"]

  # Fixed-size shapes (e.g. BM.DenseIO.A4.Ax.72) reject shape_config
  dynamic "shape_config" {
    for_each = can(regex("Flex$", var.shapes["redpanda"])) ? [1] : []
    content {
      ocpus         = var.ocpus["redpanda"]
      memory_in_gbs = var.memory_gbs["redpanda"]
    }
  }

  source_details {
    source_type             = "image"
    source_id               = lookup(var.image_ocid_overrides, "redpanda", var.image_ocid)
    boot_volume_size_in_gbs = var.boot_volume_gbs["redpanda"]
    boot_volume_vpus_per_gb = var.boot_volume_vpus["redpanda"]
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.benchmark.id
    assign_public_ip = true
    hostname_label   = "redpanda-${count.index}"
  }

  metadata = {
    ssh_authorized_keys = file(var.public_key_path)
    user_data           = local.cloud_init
  }
}

resource "oci_core_instance" "monitoring" {
  count = var.monitoring_instance_count

  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "benchmark-monitoring"
  shape               = "VM.Standard.E4.Flex"

  shape_config {
    ocpus         = 1
    memory_in_gbs = 8
  }

  source_details {
    source_type             = "image"
    source_id               = var.image_ocid
    boot_volume_size_in_gbs = 100
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.benchmark.id
    assign_public_ip = true
    hostname_label   = "monitoring"
  }

  metadata = {
    ssh_authorized_keys = file(var.public_key_path)
    user_data           = local.cloud_init
  }
}

resource "oci_core_instance" "client" {
  count = var.num_instances["client"]

  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "benchmark-client-${count.index}"
  shape               = var.shapes["client"]

  shape_config {
    ocpus         = var.ocpus["client"]
    memory_in_gbs = var.memory_gbs["client"]
  }

  source_details {
    source_type             = "image"
    source_id               = lookup(var.image_ocid_overrides, "client", var.image_ocid)
    boot_volume_size_in_gbs = var.boot_volume_gbs["client"]
    boot_volume_vpus_per_gb = var.boot_volume_vpus["client"]
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.benchmark.id
    assign_public_ip = true
    hostname_label   = "client-${count.index}"
  }

  metadata = {
    ssh_authorized_keys = file(var.public_key_path)
    user_data           = local.cloud_init
  }
}
