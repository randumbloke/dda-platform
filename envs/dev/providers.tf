terraform {
  required_version = "~> 1.16"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.10.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "8.10.0"
      # Reason: google_project_service_identity (modules/service_identities) has no GA form.
    }
  }
}

provider "google" {
  region = var.region
}

provider "google-beta" {
  region = var.region
}
