# Estate parameters from bootstrap/estate.json (schema estate.schema.json). A missing file fails
# the plan, so this stack cannot run before bootstrap stage 1 (design section 6.13.3).
data "google_storage_bucket_object_content" "estate" {
  bucket = var.tf_state_bucket
  name   = "bootstrap/estate.json"

  lifecycle {
    postcondition {
      condition     = self.content != null && can(jsondecode(self.content).prefix)
      error_message = "bootstrap/estate.json is missing or unreadable in gs://${var.tf_state_bucket}; apply bootstrap stage 1 first (design section 6.13.3)."
    }
  }
}

locals {
  estate = jsondecode(data.google_storage_bucket_object_content.estate.content)

  hub_project_id = local.estate.hub_project_ids[var.tier]

  # Without a dedicated CI/CD project the hub is also the CI/CD project (section 6.13.5).
  hub_project_types = local.estate.cicd_project_id == null ? ["hub", "cicd"] : ["hub"]

  hub_agents = ["dataplex", "dlp", "pubsub"]
}
