# Estate parameters (bootstrap/estate.json) and the tier stack's published values. A missing file
# fails the plan, so a stack applied out of order changes nothing (design section 6.13.3).

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

data "google_storage_bucket_object_content" "tier_outputs" {
  bucket = var.tf_state_bucket
  name   = "outputs/dda-platform/tiers/${var.tier}/outputs.json"

  lifecycle {
    postcondition {
      condition     = self.content != null && can(jsondecode(self.content).hub_project_number)
      error_message = "outputs/dda-platform/tiers/${var.tier}/outputs.json is missing; apply tiers/${var.tier}/ first (design sections 6.13.1, 6.13.3)."
    }
  }
}

locals {
  estate = jsondecode(data.google_storage_bucket_object_content.estate.content)
  tier   = jsondecode(data.google_storage_bucket_object_content.tier_outputs.content)

  regions     = local.estate.regions
  home_region = local.regions[0]

  hub_project_id       = local.tier.hub_project_id
  hub_agents           = local.tier.service_agents
  core_data_project_id = local.estate.core_data_project_ids[var.env]

  # Map of business to analytics project ID. Several domains may share one analytics project
  # (3-project layout, section 1.2).
  analytics_project_ids = local.estate.domain_analytics_project_ids[var.env]
  businesses            = sort(keys(local.analytics_project_ids))

  # Distinct data projects of this environment and their roles.
  data_project_ids = distinct(concat([local.core_data_project_id], [for b in local.businesses : local.analytics_project_ids[b]]))
  data_project_roles = {
    for p in local.data_project_ids : p => compact([
      p == local.core_data_project_id ? "core_data" : "",
      contains(values(local.analytics_project_ids), p) ? "analytics" : "",
    ])
  }
  analytics_project_businesses = {
    for p in local.data_project_ids : p => [for b in local.businesses : b if local.analytics_project_ids[b] == p]
  }
}

module "ids" {
  source = "../../modules/id_gen"

  prefix                       = local.estate.prefix
  env                          = var.env
  tier                         = var.tier
  businesses                   = local.businesses
  hub_project_id               = local.hub_project_id
  core_data_project_id         = local.core_data_project_id
  domain_analytics_project_ids = local.analytics_project_ids
}

module "platform_labels" {
  source = "../../modules/label_gen"

  labels_file = var.labels_file
  role        = "platform"
  env         = var.env
}
