/**
 * data_domain_shim/domain (design sections 2.3, 2.3.2; ADR-008 DS1-DS4; decisions P6-26, P6-27).
 *
 * The only Terraform code that creates, updates or deletes a data domain (Preview; no Terraform
 * resource, no gcloud). Shaped like the native resource a provider would offer, so a later
 * native resource changes only these internals. Called only by cdmc-governance.
 *
 * Resources (section 2.3.2 table):
 *   terraform_data.domain  replaced when project, location, data_domain_id or parent_data_domain
 *                          changes; create POST (409: compare), destroy DELETE (404: success).
 *   terraform_data.update  replaced when the SHA-256 of display_name, description, contacts and
 *                          labels changes; PATCH with an updateMask of the changed fields.
 *   terraform_data.iam     replaced when the SHA-256 of iam_members changes (and when the domain
 *                          is recreated, since a new domain has an empty policy); get/setIamPolicy
 *                          with etag, whole policy, allowed roles only.
 *   data.http.domain       GET the domain after create to read policyMember.
 *
 * Scripts run in the runner image (curl, jq) and take the build account's token from the
 * metadata server (VA-95). Operations are polled every 5 s for up to 10 min (VA-96).
 * Terraform cannot see drift here; the reconciler is the drift control (DS4).
 */

locals {
  domain_body = merge(
    {
      displayName = var.display_name
      description = var.description == null ? "" : var.description
      contacts    = [for c in var.contacts : { role = c.role, identity = c.identity }]
      labels      = var.labels
    },
    var.parent_data_domain == null ? {} : { parentDataDomain = var.parent_data_domain },
  )

  mutable_body = {
    displayName = var.display_name
    description = var.description == null ? "" : var.description
    contacts    = [for c in var.contacts : { role = c.role, identity = c.identity }]
    labels      = var.labels
  }

  iam_bindings = [for role in sort(keys(var.iam_members)) : { role = role, members = sort(distinct(var.iam_members[role])) }]

  domain_url = "https://dataplex.googleapis.com/v1/projects/${var.project}/locations/${var.location}/dataDomains/${var.data_domain_id}"
}

resource "terraform_data" "domain" {
  # The latest declaration, updated in place (no replacement), so the destroy step can check that
  # it deletes the domain this module declared (see domain_delete.sh).
  input = local.domain_body

  triggers_replace = {
    project            = var.project
    location           = var.location
    data_domain_id     = var.data_domain_id
    parent_data_domain = coalesce(var.parent_data_domain, "-")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "bash '${path.module}/scripts/domain_create.sh'"
    environment = {
      PROJECT        = var.project
      LOCATION       = var.location
      DATA_DOMAIN_ID = var.data_domain_id
      DOMAIN_BODY    = jsonencode(local.domain_body)
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = "bash '${path.module}/scripts/domain_delete.sh'"
    environment = {
      PROJECT        = self.triggers_replace.project
      LOCATION       = self.triggers_replace.location
      DATA_DOMAIN_ID = self.triggers_replace.data_domain_id
      DOMAIN_BODY    = jsonencode(self.input)
    }
  }
}

resource "terraform_data" "update" {
  triggers_replace = sha256(jsonencode(local.mutable_body))

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "bash '${path.module}/scripts/domain_update.sh'"
    environment = {
      PROJECT        = var.project
      LOCATION       = var.location
      DATA_DOMAIN_ID = var.data_domain_id
      DOMAIN_BODY    = jsonencode(local.mutable_body)
    }
  }

  # No destroy step: the domain's delete removes it.
  depends_on = [terraform_data.domain]
}

resource "terraform_data" "iam" {
  triggers_replace = sha256(jsonencode(local.iam_bindings))

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "bash '${path.module}/scripts/domain_iam.sh'"
    environment = {
      PROJECT        = var.project
      LOCATION       = var.location
      DATA_DOMAIN_ID = var.data_domain_id
      IAM_BINDINGS   = jsonencode(local.iam_bindings)
    }
  }

  lifecycle {
    # A recreated domain starts with an empty policy, so set it again.
    replace_triggered_by = [terraform_data.domain.id]
  }

  # No destroy step: deleting the domain removes its policy.
  depends_on = [terraform_data.update]
}

data "google_client_config" "current" {}

# Read after terraform_data.domain to get policyMember. Runs in plans too, so plan accounts need
# dataplex.dataDomains.get. VERIFY IN BUILD (VA-85): roles/viewer holds it.
data "http" "domain" {
  url    = local.domain_url
  method = "GET"

  request_headers = {
    Authorization = "Bearer ${data.google_client_config.current.access_token}"
    Accept        = "application/json"
  }

  retry {
    attempts     = 3
    min_delay_ms = 2000
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && try(jsondecode(self.response_body).policyMember.iamPolicyNamePrincipal, "") != "" # VERIFY IN BUILD (VA-12)
      error_message = "Could not read policyMember of data domain ${var.data_domain_id} (HTTP ${self.status_code})."
    }
  }

  depends_on = [terraform_data.domain]
}
