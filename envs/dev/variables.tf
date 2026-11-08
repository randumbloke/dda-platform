variable "env" {
  description = "Environment this stack applies."
  type        = string

  validation {
    condition     = contains(["dev", "test", "uat", "prod"], var.env)
    error_message = "env must be dev, test, uat or prod."
  }
}

variable "tier" {
  description = "Tier of the hub that serves this environment (dev, test: nonprod; uat, prod: prod)."
  type        = string

  validation {
    condition     = contains(["nonprod", "prod"], var.tier)
    error_message = "tier must be nonprod or prod."
  }
}

variable "region" {
  description = "Provider default region (the estate's home region, regions[0])."
  type        = string
}

variable "tf_state_bucket" {
  description = "Terraform state bucket holding bootstrap/estate.json and outputs/ (design section 6.8)."
  type        = string
}

variable "labels_file" {
  description = "Path to envs/labels.json, relative to this root module."
  type        = string
  default     = "../labels.json"
}

variable "components" {
  description = "Component flags by phase (design section 6.17). Resources use count or for_each on them, so the .tf files are identical across environments."
  type = object({
    classifier          = bool
    steward_inbox       = bool
    access_request_gate = bool
    reconciler          = bool
    explainer           = bool
    scan_generator      = bool
    sdp_notifications   = bool
    access_request_sink = bool
    data_access_sink    = bool
    policy_tags         = bool
    evaluator_modules   = list(string)
  })

  validation {
    condition     = !var.components.policy_tags || (var.components.access_request_gate && var.components.reconciler)
    error_message = "policy_tags = true needs access_request_gate and reconciler (design section 6.17; decision P6-36)."
  }
}

variable "audit_log_retention_days" {
  description = "Retention of the dda-audit log bucket (design section 6.16.3)."
  type        = number
  default     = 400
}

variable "metadata_feed_location" {
  description = "Location of the metadata feeds; null = the home region (design section 6.16.3, until VA-59 says otherwise)."
  type        = string
  default     = null
}

variable "notification_channels" {
  description = "Cloud Monitoring notification channel names for the governance engineers' alerts (design section 5.8). Empty: alerts are recorded with no notification."
  type        = list(string)
  default     = []
}
