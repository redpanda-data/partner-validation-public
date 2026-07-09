resource "oci_core_vcn" "benchmark" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "redpanda-benchmark-vcn"
  dns_label      = "rpbench"
}

resource "oci_core_internet_gateway" "benchmark" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "redpanda-benchmark-igw"
}

resource "oci_core_route_table" "benchmark" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "redpanda-benchmark-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.benchmark.id
  }
}

resource "oci_core_security_list" "benchmark" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.benchmark.id
  display_name   = "redpanda-benchmark-sl"

  # SSH from anywhere (orchestrated from local machine, not an in-cloud jumpbox)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Grafana on the monitoring node — the published observability endpoint
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 3000
      max = 3000
    }
  }

  # OKE API endpoint (kubectl from workstations)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 6443
      max = 6443
    }
  }

  # HTTP/HTTPS for the TLS reverse proxy (Let's Encrypt + browser access)
  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 80
      max = 80
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"
    tcp_options {
      min = 443
      max = 443
    }
  }

  # Everything within the VCN: Kafka API 9092, RPC 33145, Admin 9644,
  # OMB workers 8080/9091, node_exporter, etc.
  ingress_security_rules {
    protocol = "all"
    source   = var.vcn_cidr
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

resource "oci_core_subnet" "benchmark" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.benchmark.id
  cidr_block        = var.subnet_cidr
  display_name      = "redpanda-benchmark-subnet"
  dns_label         = "bench"
  route_table_id    = oci_core_route_table.benchmark.id
  security_list_ids = [oci_core_security_list.benchmark.id]
}

# OKE node pools may not share the service-LB subnet — dedicated node subnet
resource "oci_core_subnet" "oke_nodes" {
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.benchmark.id
  cidr_block        = "10.0.1.0/24"
  display_name      = "oke-nodes-subnet"
  dns_label         = "okenodes"
  route_table_id    = oci_core_route_table.benchmark.id
  security_list_ids = [oci_core_security_list.benchmark.id]
}

output "oke_nodes_subnet_id" {
  value = oci_core_subnet.oke_nodes.id
}
