# The tier's data governance hub (design sections 2.2, 6.13.2): project factory, APIs and
# service-agent identities.

module "hub_labels" {
  source = "../../modules/label_gen"

  labels_file = var.labels_file
  role        = "hub"
  tier        = var.tier
}

module "hub_project" {
  source = "../../modules/project_factory"

  project_id          = local.hub_project_id
  project_type        = "hub"
  create_project      = local.estate.create_projects
  labels              = module.hub_labels.labels
  required_label_keys = module.hub_labels.required_keys
  tiers               = local.estate.tiers
  cicd_project_id     = local.estate.cicd_project_id

  # Create mode only (create_projects = true): the shared folder is bootstrap's (section 2.1).
  # VERIFY IN BUILD (estate): not used in phase 1 (create_projects = false).
  folder_id       = null
  billing_account = local.estate.billing_account
}

module "hub_apis" {
  source = "../../modules/api_services"

  project_id     = module.hub_project.project_id
  project_types  = local.hub_project_types
  manage         = local.estate.manage_project_services
  production_hub = var.tier == "prod"
}

module "hub_agents" {
  source = "../../modules/service_identities"

  project_id     = module.hub_project.project_id
  project_number = module.hub_project.number
  services       = local.hub_agents
  manage         = local.estate.manage_service_identities

  depends_on = [module.hub_apis]
}
