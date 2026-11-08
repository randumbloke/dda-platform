output "projects" {
  description = "Data projects of this environment: key core | <business>."
  value       = local.published.projects
}

output "topics" {
  description = "Topic IDs by logical name (and <name>-dlq)."
  value       = local.published.topics
}

output "metadata_feeds" {
  description = "Metadata feed names by logical name."
  value       = local.published.metadata_feeds
}

output "landing_buckets" {
  description = "Landing bucket names by business."
  value       = local.published.landing_buckets
}

output "rollup_queue" {
  description = "Product rollup queue ID."
  value       = google_cloud_tasks_queue.rollups.id
}

output "outputs_object" {
  description = "Object path of the published outputs file."
  value       = "gs://${var.tf_state_bucket}/${google_storage_bucket_object.outputs.name}"
}
