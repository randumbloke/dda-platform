/**
 * api_services (design section 2.2.1; estate parameter manage_project_services, section 6.13.5).
 *
 *   - manage = true: enables the minimum API set of the project's role(s) with
 *     google_project_service, for_each, disable_on_destroy = false.
 *   - manage = false: enables and disables nothing. Reads every required API with
 *     data.google_project_service and fails the plan with one message that lists each missing API
 *     for the project. VERIFY IN BUILD (VA-100): how the data source reports a disabled API at
 *     provider 8.10.0 (an error per API, or an empty id). Both fail the plan; the aggregate
 *     message below covers the empty-id case.
 *
 * "Optional" rows of section 2.2.1 are not in the minimum set; pass them in extra_services.
 */

terraform {
  required_version = "~> 1.16"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "8.10.0"
    }
  }
}

variable "project_id" {
  description = "Project to enable or check APIs in."
  type        = string
}

variable "project_types" {
  description = "The project's roles (hub, core_data, analytics, cicd). A project with two roles gets the union (section 2.2.1)."
  type        = list(string)

  validation {
    condition     = length(var.project_types) > 0 && alltrue([for t in var.project_types : contains(["hub", "core_data", "analytics", "cicd"], t)])
    error_message = "project_types must be a non-empty list of hub, core_data, analytics, cicd."
  }
}

variable "manage" {
  description = "Estate parameter manage_project_services."
  type        = bool
}

variable "production_hub" {
  description = "true for the production hub, which also needs secretmanager (section 2.2.1)."
  type        = bool
  default     = false
}

variable "extra_services" {
  description = "Optional APIs of section 2.2.1 used by this deployment (full names, for example dataform.googleapis.com)."
  type        = list(string)
  default     = []
}

locals {
  common = ["cloudresourcemanager", "serviceusage", "iam", "logging"]

  # Section 2.2.1, minimum set per project type ("Yes" cells only).
  by_type = {
    hub = concat(local.common, [
      "dataplex", "datacatalog", "datalineage", "dlp", "bigquery", "storage", "pubsub", "run",
      "eventarc", "cloudscheduler", "cloudtasks", "cloudidentity", "aiplatform", "monitoring",
    ], var.production_hub ? ["secretmanager"] : [])
    core_data = concat(local.common, [
      "dataplex", "datalineage", "dlp", "bigquery", "bigquerystorage", "storage",
    ])
    analytics = concat(local.common, [
      "dataplex", "datalineage", "dlp", "bigquery", "bigquerystorage",
    ])
    cicd = concat(local.common, [
      "storage", "pubsub", "cloudbilling", "orgpolicy", "secretmanager", "cloudbuild", "artifactregistry",
    ])
  }

  services = toset(concat(
    distinct(flatten([for t in var.project_types : [for s in local.by_type[t] : "${s}.googleapis.com"]])),
    var.extra_services,
  ))
}

resource "google_project_service" "this" {
  for_each = var.manage ? local.services : toset([])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# VERIFY IN BUILD (VA-100): behaviour of the data source for a disabled API.
data "google_project_service" "check" {
  for_each = var.manage ? toset([]) : local.services

  project = var.project_id
  service = each.value
}

locals {
  missing = var.manage ? [] : sort([for s, d in data.google_project_service.check : s if d.id == null || d.id == ""])
}

output "services" {
  description = "The API set required for this project (enabled by this module, or checked)."
  value       = sort(tolist(local.services))

  precondition {
    condition     = length(local.missing) == 0
    error_message = "Project ${var.project_id} is missing required API(s): ${join(", ", local.missing)}. manage_project_services is false, so the landing zone must enable them (design sections 2.2.1, 6.13.5; VA-100). Nothing was changed."
  }
}

output "enabled" {
  description = "Map of service to its google_project_service ID (manage = true), so dependants can wait on enablement."
  value       = { for s, r in google_project_service.this : s => r.id }
}
