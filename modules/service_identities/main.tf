/**
 * service_identities (design section 2.4.5; estate parameter manage_service_identities).
 *
 *   - manage = true: generates each agent with google_project_service_identity (Beta; register
 *     entry and fallback in design section 7.2), in the same apply that enables the APIs.
 *     VERIFY IN BUILD (VA-93): that this creates the Dataplex and Sensitive Data Protection agents
 *     on a supplied project, so grants in the same apply succeed.
 *   - manage = false: computes each agent's email from the project number and creates nothing.
 *     VERIFY IN BUILD (VA-101): the email patterns below.
 *
 * Callers set depends_on = [module.<api_services>] so the APIs are enabled first.
 */

terraform {
  required_version = "~> 1.16"

  required_providers {
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "8.10.0"
      # Reason: google_project_service_identity has no GA form at 8.10.0.
    }
  }
}

variable "project_id" {
  description = "Project ID."
  type        = string
}

variable "project_number" {
  description = "Project number (from project_factory)."
  type        = string
}

variable "services" {
  description = "Agents to generate, by short name: dataplex, dlp, pubsub."
  type        = list(string)

  validation {
    condition     = alltrue([for s in var.services : contains(["dataplex", "dlp", "pubsub"], s)])
    error_message = "services may contain dataplex, dlp, pubsub."
  }
}

variable "manage" {
  description = "Estate parameter manage_service_identities."
  type        = bool
}

locals {
  api = {
    dataplex = "dataplex.googleapis.com"
    dlp      = "dlp.googleapis.com"
    pubsub   = "pubsub.googleapis.com"
  }

  # VERIFY IN BUILD (VA-101): computed agent emails.
  computed = {
    dataplex = "service-${var.project_number}@gcp-sa-dataplex.iam.gserviceaccount.com"
    dlp      = "service-${var.project_number}@dlp-api.iam.gserviceaccount.com"
    pubsub   = "service-${var.project_number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  }
}

# VERIFY IN BUILD (VA-93)
resource "google_project_service_identity" "this" {
  provider = google-beta
  for_each = var.manage ? toset(var.services) : toset([])

  project = var.project_id
  service = local.api[each.value]
}

# The emails are computed from the project number in both modes, so they are known at plan; in
# manage mode the output waits for the generated identities.
output "emails" {
  description = "Map of agent short name to email."
  value       = { for s in var.services : s => local.computed[s] }

  depends_on = [google_project_service_identity.this]
}

# VERIFY IN BUILD (VA-101): warns if a generated agent's email differs from the computed form.
check "agent_email_form" {
  assert {
    condition     = alltrue([for s, r in google_project_service_identity.this : r.email == null || r.email == local.computed[s]])
    error_message = "A generated service agent email differs from the computed form; update local.computed (VA-101)."
  }
}
