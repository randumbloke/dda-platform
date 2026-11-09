/**
 CI/CD project APIs (§2.2.1, CI/CD column) and service agents.
 */

locals {
  cicd_services = toset([
    "storage.googleapis.com",
    "pubsub.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com", # admin-activity alert (§6.15.4)
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
    "iam.googleapis.com",
    "cloudbilling.googleapis.com",
    "orgpolicy.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudidentity.googleapis.com", # group memberships (§6.6.4), billed to the CI/CD project
  ])
}

resource "google_project_service" "cicd" {
  for_each = var.manage_project_services ? local.cicd_services : toset([])

  project            = local.cicd
  service            = each.value
  disable_on_destroy = false
}

data "google_project" "cicd" {
  project_id = local.cicd
}

data "google_project" "hub" {
  for_each   = var.hub_project_ids
  project_id = each.value
}

# Cloud Build service agent: needs secretAccessor on the connection token (§6.4.1).
resource "google_project_service_identity" "cloudbuild" {
  provider = google-beta
  count    = var.manage_service_identities ? 1 : 0

  project = local.cicd
  service = "cloudbuild.googleapis.com"

  depends_on = [google_project_service.cicd]
}

locals {
  # VERIFY IN BUILD (VA-93, VA-101): google_project_service_identity for cloudbuild.googleapis.com
  # generates both <number>@cloudbuild.gserviceaccount.com (returned in .email) and the P4SA
  # service-<number>@gcp-sa-cloudbuild.iam.gserviceaccount.com, which 2nd-gen connections use.
  cloudbuild_agent = "service-${data.google_project.cicd.number}@gcp-sa-cloudbuild.iam.gserviceaccount.com"

  run_agent_projects = toset(concat(values(var.hub_project_ids), local.data_projects))
}

# Cloud Run API and service identities on hubs and data projects, needed before stage 1 grants
# roles/artifactregistry.reader on dda-control-plane and dda-pipelines (verified live 2026-11-09).
resource "google_project_service" "run_on_workload_projects" {
  for_each = var.manage_project_services ? local.run_agent_projects : toset([])

  project            = each.value
  service            = "run.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service_identity" "run_on_workload_projects" {
  provider = google-beta
  for_each = var.manage_service_identities ? local.run_agent_projects : toset([])

  project = each.value
  service = "run.googleapis.com"

  depends_on = [google_project_service.run_on_workload_projects]
}

locals {
  # Cloud Run service agent of each hub: reads dda-control-plane (§6.6.1).
  hub_run_agents = {
    for t, p in data.google_project.hub : t => (
      var.manage_service_identities
      ? google_project_service_identity.run_on_workload_projects[p.project_id].email
      : "service-${p.number}@serverless-robot-prod.iam.gserviceaccount.com"
    )
  }
}
