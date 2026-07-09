output "broker_public_ips" {
  value = oci_core_instance.redpanda[*].public_ip
}

output "broker_private_ips" {
  value = oci_core_instance.redpanda[*].private_ip
}

output "monitoring_public_ip" {
  value = try(oci_core_instance.monitoring[0].public_ip, null)
}

output "monitoring_private_ip" {
  value = try(oci_core_instance.monitoring[0].private_ip, null)
}

output "client_public_ips" {
  value = oci_core_instance.client[*].public_ip
}

output "client_private_ips" {
  value = oci_core_instance.client[*].private_ip
}
