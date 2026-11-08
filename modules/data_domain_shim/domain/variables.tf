# Inputs exactly as the design section 2.3 `domain` table.

variable "project" {
  description = "The hub project that hosts the domain."
  type        = string
}

variable "location" {
  description = "The deployment region. VERIFY IN BUILD (VA-17): whether domains are regional or global."
  type        = string
}

variable "data_domain_id" {
  description = "dataDomainId on create, for example customer-dev or raw."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.data_domain_id))
    error_message = "data_domain_id must be lower-case letters, digits and hyphens, starting with a letter."
  }
}

variable "parent_data_domain" {
  description = "parentDataDomain: the parent domain's name, for a subdomain. Immutable: a change forces delete and recreate."
  type        = string
  default     = null
}

variable "display_name" {
  description = "displayName (required by the API)."
  type        = string

  validation {
    condition     = length(trimspace(var.display_name)) > 0
    error_message = "display_name is required."
  }
}

variable "description" {
  description = "description."
  type        = string
  default     = null
}

variable "contacts" {
  description = "contacts (required by the API): list of {role, identity}."
  type = list(object({
    role     = string
    identity = string
  }))

  validation {
    condition     = length(var.contacts) > 0
    error_message = "contacts is required by the API: give at least one {role, identity}."
  }
}

variable "labels" {
  description = "labels."
  type        = map(string)
  default     = {}
}

variable "iam_members" {
  description = <<-EOT
    The domain's whole IAM policy: map of role to list of members, set with setIamPolicy.
    Only four roles are accepted (section 2.3; VA-48, VA-87): organizations/<org>/roles/ddaMetadataSteward,
    roles/dataplex.dataDomainViewer, roles/dataplex.dataDomainEntryReader, and
    organizations/<org>/roles/ddaDomainBinder, the last for the domain's own pipeline service account
    tf-<business>-<tier> only (or tf-deployer when single_deployer is true, section 6.7.2).
  EOT
  type        = map(list(string))
  default     = {}

  validation {
    condition = alltrue([
      for role in keys(var.iam_members) :
      can(regex("^(roles/dataplex\\.dataDomainViewer|roles/dataplex\\.dataDomainEntryReader|organizations/[0-9]+/roles/ddaMetadataSteward|organizations/[0-9]+/roles/ddaDomainBinder)$", role))
    ])
    error_message = "iam_members may grant only ddaMetadataSteward, roles/dataplex.dataDomainViewer, roles/dataplex.dataDomainEntryReader and ddaDomainBinder on a domain. No data role (for example roles/bigquery.dataViewer) can be granted on a domain (design section 2.3; VA-48)."
  }

  validation {
    condition = alltrue(flatten([
      for role, members in var.iam_members : [
        for m in members : can(regex("^(user|group|serviceAccount|principal|principalSet):[^\\s]+$", m))
      ]
    ]))
    error_message = "Each member must be user:, group:, serviceAccount:, principal: or principalSet:."
  }

  validation {
    condition = alltrue(flatten([
      for role, members in var.iam_members : [
        for m in members : (
          can(regex("^serviceAccount:tf-deployer@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", m)) ||
          (
            can(regex("^([a-z][a-z0-9]*)-(dev|test|uat|prod)$", var.data_domain_id)) &&
            can(regex("^serviceAccount:tf-${try(regex("^([a-z][a-z0-9]*)-", var.data_domain_id)[0], "-")}-(nonprod|prod)@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", m))
          )
        )
      ] if endswith(role, "/roles/ddaDomainBinder")
    ]))
    error_message = "ddaDomainBinder may be granted only to the domain's own pipeline service account, tf-<business>-<tier> for domain <business>-<env> (or tf-deployer under single_deployer), so no domain pipeline can bind to another domain (design sections 2.3, 6.7; VA-87)."
  }
}
