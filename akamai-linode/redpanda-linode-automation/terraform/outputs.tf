output "cluster_id" {
  description = "LKE Cluster ID"
  value       = linode_lke_cluster.redpanda.id
}

output "cluster_name" {
  description = "LKE Cluster Name"
  value       = linode_lke_cluster.redpanda.label
}

output "api_endpoint" {
  description = "Kubernetes API endpoint"
  value       = linode_lke_cluster.redpanda.api_endpoints[0]
}

output "kubeconfig_path" {
  description = "Path to kubeconfig file"
  value       = local_file.kubeconfig.filename
}

output "object_storage_bucket" {
  description = "Object Storage bucket name"
  value       = linode_object_storage_bucket.redpanda_tiered.label
}

output "object_storage_endpoint" {
  description = "Object Storage endpoint"
  value       = "${linode_object_storage_bucket.redpanda_tiered.cluster}.linodeobjects.com"
}

output "object_storage_access_key" {
  description = "Object Storage access key"
  value       = linode_object_storage_key.redpanda_tiered_key.access_key
  sensitive   = true
}

output "object_storage_secret_key" {
  description = "Object Storage secret key"
  value       = linode_object_storage_key.redpanda_tiered_key.secret_key
  sensitive   = true
}
