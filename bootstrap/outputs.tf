output "tf_state_bucket" {
  description = "Terraform state bucket (§6.8)."
  value       = google_storage_bucket.tfstate.name
}

output "estate_json" {
  description = "gs:// path of bootstrap/estate.json."
  value       = "gs://${google_storage_bucket.tfstate.name}/${google_storage_bucket_object.estate.name}"
}

output "deployer_service_accounts" {
  description = "Apply and plan accounts (§6.7.2)."
  value = {
    apply = local.deployer_email
    plan  = local.deployer_plan_email
  }
}

output "artifact_registry" {
  description = "Image repositories (§6.10)."
  value = {
    dda_ci            = "${local.ar_host}/${local.cicd}/${google_artifact_registry_repository.dda_ci.repository_id}"
    dda_control_plane = "${local.ar_host}/${local.cicd}/${google_artifact_registry_repository.dda_control_plane.repository_id}"
  }
}

output "secrets" {
  description = "Secrets created with no version; add each token as a version after stage 1 (§6.6.2 step 2)."
  value       = { for k, s in google_secret_manager_secret.secret : k => s.id }
}

output "custom_roles" {
  description = "Organisation custom role names."
  value       = local.custom_role
}

output "repositories" {
  description = "GitHub repositories."
  value       = { for k, r in github_repository.repo : k => r.html_url }
}

output "apply_stack_order" {
  description = "Ordered stack list per repository in the apply build (§6.13.1)."
  value       = { for r, stacks in local.apply_stacks : r => [for s in stacks : s.dir] }
}

output "triggers" {
  description = "Cloud Build triggers (stage 2)."
  value       = { for k, t in google_cloudbuild_trigger.trigger : k => t.trigger_id }
}
