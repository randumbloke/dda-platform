/**
 Bootstrap providers (design §6.6, §6.11).

 Applied only by a bootstrap administrator (OD-2: a member of dda-bootstrap-admins), from their
 own credentials:
   - google / google-beta: Application Default Credentials of the administrator
     (`gcloud auth application-default login`). Cloud Identity calls are billed to the CI/CD
     project through user_project_override.
   - github: the administrator's own token from the environment (GITHUB_TOKEN), never stored.
 */

terraform {
  required_version = "~> 1.16"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.10.0"
    }
    # Reason: google_project_service_identity (Cloud Build service agent) has no GA form.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "8.10.0"
    }
    # bootstrap/ only (design §6.11).
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }
}

provider "google" {
  project               = var.cicd_project_id
  region                = local.home_region
  billing_project       = var.cicd_project_id
  user_project_override = true
}

provider "google-beta" {
  project               = var.cicd_project_id
  region                = local.home_region
  billing_project       = var.cicd_project_id
  user_project_override = true
}

provider "github" {
  # Personal account in `user` mode (P6-34), organisation in `organization` mode.
  # Token: GITHUB_TOKEN from the administrator's environment.
  owner = var.github_owner
}
