/**
 * id_gen: names and IDs of design section 1.6 and the phase 1 contracts
 * (deployment/contracts/README.md section 2). Project names are defaults only: project IDs are
 * inputs (section 1.2), so callers use the estate's IDs and these names only in create mode.
 */

terraform {
  required_version = ">= 1.17"
}

variable "prefix" {
  description = "Project name prefix (estate parameter `prefix`)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.prefix))
    error_message = "prefix must be 2-10 lower-case letters or digits, starting with a letter."
  }
}

variable "env" {
  description = "Environment, or null for a tier stack."
  type        = string
  default     = null
}

variable "tier" {
  description = "Tier (nonprod, prod), or null."
  type        = string
  default     = null
}

variable "businesses" {
  description = "Business names of the domains (for example [\"customer\", \"accounts\"])."
  type        = list(string)
  default     = []
}

variable "hub_project_id" {
  description = "Hub project ID, for service account emails; null when not known to the caller."
  type        = string
  default     = null
}

variable "core_data_project_id" {
  description = "Core data project ID, for landing bucket names and ingest service account emails."
  type        = string
  default     = null
}

variable "domain_analytics_project_ids" {
  description = "Map of business to analytics project ID, for analytics service account emails."
  type        = map(string)
  default     = {}
}

variable "datasets" {
  description = "Dataset IDs (`<business>_<stage>`) to derive binding IDs for."
  type        = list(string)
  default     = []
}

variable "products" {
  description = "Data product IDs to derive binding IDs for."
  type        = list(string)
  default     = []
}

variable "scans" {
  description = "Data quality scans to name: list of {dataset, table}."
  type = list(object({
    dataset = string
    table   = string
  }))
  default = []
}

locals {
  env_suffix = var.env == null ? "" : "-${var.env}"

  # Section 1.6 default project names.
  project_names = {
    hub       = var.tier == null ? null : "${var.prefix}-dgov-hub-${var.tier}"
    cicd      = "${var.prefix}-dda-cicd"
    core_data = var.env == null ? null : "${var.prefix}-core-dwh-${var.env}"
    analytics = { for b in var.businesses : b => var.env == null ? null : "${var.prefix}-${b}-analytics-${var.env}" }
  }

  # Data domain IDs: <business>-<env>; subdomains are the lifecycle stage.
  domain_ids = { for b in var.businesses : b => "${b}${local.env_suffix}" }

  # Service accounts `<component>-<env>` in the hosting project (section 2.4; ingest accounts in
  # the core data project per section 2.4.2).
  domain_service_accounts = var.env == null ? {} : {
    for b in var.businesses : b => {
      ingest = var.core_data_project_id == null ? null : "${b}-ingest-${var.env}@${var.core_data_project_id}.iam.gserviceaccount.com"
      analytics = lookup(var.domain_analytics_project_ids, b, null) == null ? null : (
        "${b}-analytics-${var.env}@${var.domain_analytics_project_ids[b]}.iam.gserviceaccount.com"
      )
    }
  }

  hub_service_accounts = var.env == null || var.hub_project_id == null ? {} : {
    for c in ["classifier", "evaluator", "gate", "reconciler", "explainer"] :
    c => "${c}-${var.env}@${var.hub_project_id}.iam.gserviceaccount.com"
  }

  # Landing bucket `<core_data_project_id>-<business>-landing` (contracts section 2).
  landing_buckets = var.core_data_project_id == null ? {} : {
    for b in var.businesses : b => "${var.core_data_project_id}-${b}-landing"
  }

  # Event plumbing names carry the environment as a suffix (section 2.5).
  topics = {
    for t in ["kc-evaluator", "kc-classifier", "sdp-profiles", "access-requests", "product-classification", "notifications", "narratives", "findings"] :
    t => "${t}${local.env_suffix}"
  }
  dead_letter_topics = { for k, v in local.topics : k => "${v}-dlq" }
  metadata_feeds     = { for f in ["feed-evaluator", "feed-classifier"] : f => "${f}${local.env_suffix}" }
  rollup_queue       = "product-rollups${local.env_suffix}"
  audit_log_bucket   = "dda-audit${local.env_suffix}"
  audit_dataset      = "audit_logs${var.env == null ? "" : "_${var.env}"}"
  audit_sinks        = { for s in ["access-requests", "bigquery-data-access"] : s => "${s}${local.env_suffix}" }

  # Binding IDs (contracts section 2): ds-<dataset with _ as -> and dp-<product-id>.
  dataset_binding_ids = { for d in var.datasets : d => "ds-${replace(d, "_", "-")}" }
  product_binding_ids = { for p in var.products : p => "dp-${p}" }

  # Scan ID: dq-<dataset>-<table> with _ as -; over 63 characters, the first 54 characters, a
  # hyphen and the first 8 hex digits of the SHA-256 of the full (untruncated) ID.
  scan_full = { for s in var.scans : "${s.dataset}.${s.table}" => lower(replace("dq-${s.dataset}-${s.table}", "_", "-")) }
  scan_ids = {
    for k, id in local.scan_full : k => length(id) <= 63 ? id : "${substr(id, 0, 54)}-${substr(sha256(id), 0, 8)}"
  }
}

output "project_names" {
  description = "Default project names (section 1.6); create mode only."
  value       = local.project_names
}

output "domain_ids" {
  description = "Map of business to data domain ID."
  value       = local.domain_ids
}

output "domain_service_accounts" {
  description = "Map of business to {ingest, analytics} service account emails."
  value       = local.domain_service_accounts
}

output "hub_service_accounts" {
  description = "Map of control plane component to its service account email for this environment."
  value       = local.hub_service_accounts
}

output "landing_buckets" {
  description = "Map of business to landing bucket name."
  value       = local.landing_buckets
}

output "topics" {
  description = "Map of logical topic name to deployed topic ID."
  value       = local.topics
}

output "dead_letter_topics" {
  description = "Map of logical topic name to its dead-letter topic ID."
  value       = local.dead_letter_topics
}

output "metadata_feeds" {
  description = "Map of logical feed name to deployed feed ID."
  value       = local.metadata_feeds
}

output "rollup_queue" {
  description = "Cloud Tasks queue ID for product rollups."
  value       = local.rollup_queue
}

output "audit_log_bucket" {
  description = "Log bucket ID for the data-access sink."
  value       = local.audit_log_bucket
}

output "audit_dataset" {
  description = "Linked BigQuery dataset ID of the audit log bucket."
  value       = local.audit_dataset
}

output "audit_sinks" {
  description = "Map of logical sink name to deployed sink name."
  value       = local.audit_sinks
}

output "dataset_binding_ids" {
  description = "Map of dataset ID to binding ID."
  value       = local.dataset_binding_ids
}

output "product_binding_ids" {
  description = "Map of product ID to binding ID."
  value       = local.product_binding_ids
}

output "scan_ids" {
  description = "Map of `<dataset>.<table>` to data quality scan ID."
  value       = local.scan_ids
}
