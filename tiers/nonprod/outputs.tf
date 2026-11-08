output "hub_project_id" {
  description = "The tier's hub project ID."
  value       = module.hub_project.project_id
}

output "hub_project_number" {
  description = "The tier's hub project number."
  value       = module.hub_project.number
}

output "service_agents" {
  description = "Hub service-agent emails by short name."
  value       = module.hub_agents.emails
}

output "apis" {
  description = "The hub's required API set."
  value       = module.hub_apis.services
}

output "outputs_object" {
  description = "Object path of the published outputs file."
  value       = "gs://${var.tf_state_bucket}/${google_storage_bucket_object.outputs.name}"
}
