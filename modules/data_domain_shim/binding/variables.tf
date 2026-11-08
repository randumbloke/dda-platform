# Inputs as the design section 2.3 `binding` table, plus one optional input (organization_id).

variable "domain_name" {
  description = "The `name` output of the domain or subdomain."
  type        = string
}

variable "policy_member" {
  description = "The `policy_member` output of the same domain, granted ddaDomainDelegate on each resource."
  type        = string
}

variable "bindings" {
  description = "Map of binding key to IAM full resource name. One bindings child per entry, with ID <key> (ds-<dataset with _ as -> or dp-<product-id>)."
  type        = map(string)

  validation {
    condition     = alltrue([for k in keys(var.bindings) : can(regex("^(ds|dp)-[a-z0-9-]+$", k)) && length(k) <= 63])
    error_message = "Binding keys must match ^(ds|dp)-[a-z0-9-]+$ (at most 63 characters; contracts section 2)."
  }

  validation {
    condition = alltrue([
      for r in values(var.bindings) :
      can(regex("^//bigquery\\.googleapis\\.com/projects/[^/]+/datasets/[^/]+$", r)) ||
      can(regex("^//dataplex\\.googleapis\\.com/projects/[^/]+/locations/[^/]+/dataProducts/[^/]+$", r))
    ])
    error_message = "Each binding resource must be a BigQuery dataset (//bigquery.googleapis.com/projects/P/datasets/D) or a data product (//dataplex.googleapis.com/projects/P/locations/L/dataProducts/X) full resource name."
  }
}

variable "organization_id" {
  description = "Optional (not in the design table): organisation ID for the ddaDomainDelegate role name. Default: read from the bound resources' projects."
  type        = string
  default     = null
}
