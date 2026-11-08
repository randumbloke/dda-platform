/**
 * project_factory (design section 2.2; decisions P6-33, P1-7).
 *
 * Modes, set by the estate parameters of section 6.13.5:
 *   - create (create_project = true): creates the project in its folder, links billing and sets
 *     the section 1.6 labels.
 *   - supplied (create_project = false): reads the project with the google_project data source and
 *     never creates, moves, relabels or deletes it. A postcondition fails the plan if the project
 *     lacks a label that section 1.6 scopes to its role (P1-7), or carries a dda-env / dda-tier
 *     value other than the one this stack expects.
 *
 * APIs (api_services) and service-agent identities (service_identities) are separate modules
 * that the stack calls with this module's outputs; the factory creates no service accounts
 * (section 2.4).
 */

locals {
  supplied = !var.create_project

  project_id = local.supplied ? data.google_project.supplied[0].project_id : google_project.created[0].project_id
  number     = local.supplied ? tostring(data.google_project.supplied[0].number) : tostring(google_project.created[0].number)

  supplied_labels = local.supplied ? (data.google_project.supplied[0].labels == null ? {} : data.google_project.supplied[0].labels) : {}
  actual_labels   = local.supplied ? local.supplied_labels : var.labels

  # Keys whose value, not only presence, is checked on a supplied project.
  value_checked_keys = [for k in ["dda-env", "dda-tier"] : k if contains(keys(var.labels), k)]
}

data "google_project" "supplied" {
  count      = local.supplied ? 1 : 0
  project_id = var.project_id

  lifecycle {
    postcondition {
      condition     = length(setsubtract(toset(var.required_label_keys), toset(keys(self.labels == null ? {} : self.labels)))) == 0
      error_message = "Supplied ${var.project_type} project ${var.project_id} lacks required label(s) ${join(", ", sort(tolist(setsubtract(toset(var.required_label_keys), toset(keys(self.labels == null ? {} : self.labels))))))} (design sections 1.6, 2.2, 6.13.5; decision P1-7). Ask the landing zone to set them: Terraform never relabels a supplied project."
    }

    postcondition {
      condition = alltrue([
        for k in local.value_checked_keys : lookup(self.labels == null ? {} : self.labels, k, var.labels[k]) == var.labels[k]
      ])
      error_message = "Supplied ${var.project_type} project ${var.project_id} carries ${join(", ", [for k in local.value_checked_keys : "${k}=${lookup(self.labels == null ? {} : self.labels, k, "")}"])}; this stack expects ${join(", ", [for k in local.value_checked_keys : "${k}=${var.labels[k]}"])}."
    }
  }
}

resource "google_project" "created" {
  count = local.supplied ? 0 : 1

  project_id          = var.project_id
  name                = coalesce(var.project_name, var.project_id)
  folder_id           = var.folder_id
  billing_account     = var.billing_account
  labels              = var.labels
  auto_create_network = false
  deletion_policy     = "PREVENT"

  lifecycle {
    precondition {
      condition     = var.folder_id != null && var.billing_account != null
      error_message = "Create mode needs folder_id and billing_account (design section 2.2)."
    }
  }
}
