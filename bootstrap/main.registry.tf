/**
 Artifact Registry (§6.10): dda-ci (merge gate and runner images, written only by bootstrap
 administrators) and dda-control-plane (control plane images, immutable tags).
 */

resource "google_artifact_registry_repository" "dda_ci" {
  project       = local.cicd
  location      = local.home_region
  repository_id = "dda-ci"
  format        = "DOCKER"
  description   = "DDA merge gate and Terraform runner images (bootstrap administrators only)."

  docker_config {
    immutable_tags = true
  }

  labels = {
    dda-domain = "shared"
  }

  depends_on = [google_project_service.cicd]
}

resource "google_artifact_registry_repository" "dda_control_plane" {
  project       = local.cicd
  location      = local.home_region
  repository_id = "dda-control-plane"
  format        = "DOCKER"
  description   = "DDA control plane images, tagged by kc-control-plane commit SHA."

  docker_config {
    immutable_tags = true
  }

  labels = {
    dda-domain = "shared"
  }

  depends_on = [google_project_service.cicd]
}

# Builds pull the gate and runner images as the build's service account.
resource "google_artifact_registry_repository_iam_member" "dda_ci_reader" {
  for_each = { apply = local.deployer_email, plan = local.deployer_plan_email }

  project    = local.cicd
  location   = local.home_region
  repository = google_artifact_registry_repository.dda_ci.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${each.value}"
}

# tf-governance-nonprod's writer role; with single_deployer it is tf-deployer (§6.7.2).
resource "google_artifact_registry_repository_iam_member" "control_plane_writer" {
  project    = local.cicd
  location   = local.home_region
  repository = google_artifact_registry_repository.dda_control_plane.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${local.deployer_email}"
}

# Cloud Run service agents of the hubs read control plane images (§6.6.1).
resource "google_artifact_registry_repository_iam_member" "control_plane_hub_run_agent" {
  for_each = local.hub_run_agents

  project    = local.cicd
  location   = local.home_region
  repository = google_artifact_registry_repository.dda_control_plane.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${each.value}"
}
