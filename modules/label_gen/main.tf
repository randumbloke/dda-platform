/**
 * label_gen: the labels of design section 1.6 for one resource, read from envs/labels.json.
 *
 * Decision P1-7: dda-env only where one environment applies (core data and analytics projects,
 * scans); hub projects carry dda-tier; the CI/CD project carries dda-domain=shared only.
 * The file also says which label keys each project role must carry, which the project factory
 * checks on supplied projects (sections 2.2, 6.13.5).
 */

terraform {
  required_version = ">= 1.17"
}

variable "labels_file" {
  description = "Path to envs/labels.json."
  type        = string
}

variable "role" {
  description = "Resource role: a key of `roles` in labels.json (hub, cicd, core_data, analytics, dataset, scan, component)."
  type        = string
}

variable "env" {
  description = "Environment (dev, test, uat, prod), or null where no single environment applies."
  type        = string
  default     = null
}

variable "tier" {
  description = "Tier (nonprod, prod), or null."
  type        = string
  default     = null
}

variable "domain" {
  description = "Value of dda-domain where the role takes it from the caller (a domain ID such as customer-dev); null keeps the file's value."
  type        = string
  default     = null
}

variable "extra" {
  description = "Further labels for this resource (for example dda-component, dda-stage)."
  type        = map(string)
  default     = {}
}

locals {
  doc  = jsondecode(file(var.labels_file))
  role = local.doc.roles[var.role]
  keys = try(local.role.keys, [])

  scoped = merge(
    try(local.role.static, {}),
    contains(local.keys, "dda-env") && var.env != null ? { "dda-env" = var.env } : {},
    contains(local.keys, "dda-tier") && var.tier != null ? { "dda-tier" = var.tier } : {},
    contains(local.keys, "dda-domain") && var.domain != null ? { "dda-domain" = var.domain } : {},
  )

  labels = merge(try(local.doc.common, {}), local.scoped, var.extra)
}

output "labels" {
  description = "Labels to set on the resource (create mode) or to expect on it (supplied mode)."
  value       = local.labels
}

output "required_keys" {
  description = "Label keys section 1.6 scopes to this role (P1-7); a supplied project lacking one fails the plan."
  value       = try(local.role.required, [])
}
