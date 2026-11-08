terraform {
  required_version = "~> 1.16"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.10.0"
    }
    # The only use of hashicorp/http in the estate (design sections 2.3.2, 6.11; P6-27).
    http = {
      source  = "hashicorp/http"
      version = "~> 3.6"
    }
  }
}
