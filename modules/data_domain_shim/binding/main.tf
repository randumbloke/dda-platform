/**
 * data_domain_shim/binding (design sections 2.3, 2.3.1, 2.3.2; decisions P6-8, P6-27, P6-32).
 *
 * Called only by a domain's own pipeline (core stack), for its own domain. For each binding:
 *   1. grant the domain's policy_member the organisation custom role ddaDomainDelegate on the
 *      resource (dataset: google_bigquery_dataset_access, section 6.15.2; data product:
 *      google_dataplex_data_product_iam_member);
 *   2. create the binding with ID <key> (terraform_data.binding, which depends on the grants);
 *   3. output the binding name. The caller writes the declared bindings file
 *      (hub bindings/<env>/<domain>/bindings.json, schema bindings.schema.json).
 * Removal runs in reverse: the binding is deleted, then the grant is removed.
 *
 * VERIFY IN BUILD (VA-12): that policy_member can be granted a role like any other principal.
 * VERIFY IN BUILD (VA-49): that ddaDomainDelegate is sufficient to create a binding.
 * VERIFY IN BUILD (VA-94): that a google_bigquery_dataset_access iam_member entry accepts the
 * custom role and survives re-applies.
 */

locals {
  dataset_re = "^//bigquery\\.googleapis\\.com/projects/([^/]+)/datasets/([^/]+)$"
  product_re = "^//dataplex\\.googleapis\\.com/projects/([^/]+)/locations/([^/]+)/dataProducts/([^/]+)$"

  datasets = {
    for k, r in var.bindings : k => {
      project    = regex(local.dataset_re, r)[0]
      dataset_id = regex(local.dataset_re, r)[1]
    } if can(regex(local.dataset_re, r))
  }

  products = {
    for k, r in var.bindings : k => {
      project         = regex(local.product_re, r)[0]
      location        = regex(local.product_re, r)[1]
      data_product_id = regex(local.product_re, r)[2]
    } if can(regex(local.product_re, r))
  }

  resource_projects = toset(concat([for d in local.datasets : d.project], [for p in local.products : p.project]))

  organization_id = var.organization_id != null ? var.organization_id : try(
    one(distinct([for p in data.google_project.resource : p.org_id if p.org_id != ""])), null
  )

  delegate_role = "organizations/${coalesce(local.organization_id, "UNKNOWN")}/roles/ddaDomainDelegate"
}

# Organisation of the bound resources, for the custom role's name, when organization_id is not
# given. A project inside a folder reports no org_id; pass organization_id then.
data "google_project" "resource" {
  for_each   = var.organization_id == null ? local.resource_projects : toset([])
  project_id = each.value
}

# Step 1, datasets (section 6.15.2: one google_bigquery_dataset_access entry per grant).
resource "google_bigquery_dataset_access" "delegate" {
  for_each = local.datasets

  project    = each.value.project
  dataset_id = each.value.dataset_id
  role       = local.delegate_role
  iam_member = var.policy_member

  lifecycle {
    precondition {
      condition     = local.organization_id != null
      error_message = "Cannot determine the organisation ID for ddaDomainDelegate; pass organization_id."
    }
  }
}

# Step 1, data products.
resource "google_dataplex_data_product_iam_member" "delegate" {
  for_each = local.products

  project         = each.value.project
  location        = each.value.location
  data_product_id = each.value.data_product_id
  role            = local.delegate_role
  member          = var.policy_member

  lifecycle {
    precondition {
      condition     = local.organization_id != null
      error_message = "Cannot determine the organisation ID for ddaDomainDelegate; pass organization_id."
    }
  }
}

# Step 2. Replaced when the domain, key or resource changes (bindings have no update, DS3).
resource "terraform_data" "binding" {
  for_each = var.bindings

  triggers_replace = {
    domain_name = var.domain_name
    key         = each.key
    resource    = each.value
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "bash '${path.module}/scripts/binding_create.sh'"
    environment = {
      DOMAIN_NAME = var.domain_name
      BINDING_ID  = each.key
      RESOURCE    = each.value
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = "bash '${path.module}/scripts/binding_delete.sh'"
    environment = {
      DOMAIN_NAME = self.triggers_replace.domain_name
      BINDING_ID  = self.triggers_replace.key
      RESOURCE    = self.triggers_replace.resource
    }
  }

  depends_on = [
    google_bigquery_dataset_access.delegate,
    google_dataplex_data_product_iam_member.delegate,
  ]
}
