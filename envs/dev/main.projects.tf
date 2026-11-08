# Core data and analytics projects, their APIs and service-agent identities (design sections 2.2,
# 2.2.1, 2.4.5, 6.13.2). With create_projects = false (phase 1) the projects are supplied: read,
# label-checked (P1-7), never created, moved, relabelled or deleted. No folders are created
# (section 6.13.1).

module "data_project_labels" {
  source   = "../../modules/label_gen"
  for_each = local.data_project_roles

  labels_file = var.labels_file
  role        = contains(each.value, "core_data") ? "core_data" : "analytics"
  env         = var.env
  # An analytics project for one domain carries that domain's ID; one shared by several domains
  # carries `shared` (sections 1.6, 2.1).
  domain = contains(each.value, "core_data") ? null : (
    length(local.analytics_project_businesses[each.key]) == 1 ? "${local.analytics_project_businesses[each.key][0]}-${var.env}" : "shared"
  )
}

module "data_projects" {
  source   = "../../modules/project_factory"
  for_each = local.data_project_roles

  project_id          = each.key
  project_type        = contains(each.value, "core_data") ? "core_data" : "analytics"
  create_project      = local.estate.create_projects
  labels              = module.data_project_labels[each.key].labels
  required_label_keys = module.data_project_labels[each.key].required_keys

  # Create mode only. Environment folders (shared/<env>, <business>/<env>) are not drafted in
  # phase 1 (create_projects = false); see README "Incomplete".
  folder_id       = null
  billing_account = local.estate.billing_account
}

module "data_project_apis" {
  source   = "../../modules/api_services"
  for_each = local.data_project_roles

  project_id    = module.data_projects[each.key].project_id
  project_types = each.value
  manage        = local.estate.manage_project_services
}

module "data_project_agents" {
  source   = "../../modules/service_identities"
  for_each = local.data_project_roles

  project_id     = module.data_projects[each.key].project_id
  project_number = module.data_projects[each.key].number
  services       = ["dataplex", "dlp"]
  manage         = local.estate.manage_service_identities

  depends_on = [module.data_project_apis]
}

# Project-level grants to service agents (section 6.15.1: dda-platform environment stack).
# Sensitive Data Protection: the role project-level discovery needs on its own project
# (section 2.4.5). VERIFY IN BUILD (VA-58): that roles/dlp.projectdriver is that role and is
# sufficient for discovery.
resource "google_project_iam_member" "dlp_discovery" {
  for_each = local.data_project_roles

  project = module.data_projects[each.key].project_id
  role    = "roles/dlp.projectdriver"
  member  = "serviceAccount:${module.data_project_agents[each.key].emails["dlp"]}"
}
