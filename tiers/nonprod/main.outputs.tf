# Published values (design section 6.13.3; schema outputs_platform_tier.schema.json).
locals {
  published = {
    tier               = var.tier
    hub_project_id     = module.hub_project.project_id
    hub_project_number = module.hub_project.number
    service_agents     = module.hub_agents.emails
  }
}

resource "google_storage_bucket_object" "outputs" {
  bucket       = var.tf_state_bucket
  name         = "outputs/dda-platform/tiers/${var.tier}/outputs.json"
  content_type = "application/json"
  content      = jsonencode(local.published)
}
