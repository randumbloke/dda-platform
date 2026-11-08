variable "project_id" {
  description = "Project ID: an estate project ID parameter (hub_project_id, cicd_project_id, core_data_project_id or an entry of domain_analytics_project_ids; section 1.2)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid Google Cloud project ID."
  }
}

variable "project_type" {
  description = "Project role: hub, cicd, core_data or analytics."
  type        = string

  validation {
    condition     = contains(["hub", "cicd", "core_data", "analytics"], var.project_type)
    error_message = "project_type must be one of hub, cicd, core_data, analytics."
  }
}

variable "create_project" {
  description = "Estate parameter create_projects (section 6.13.5). false: supplied mode."
  type        = bool
}

variable "labels" {
  description = "Labels for the project from label_gen: set in create mode, expected in supplied mode."
  type        = map(string)
}

variable "required_label_keys" {
  description = "Label keys the project's role must carry (label_gen required_keys; P1-7)."
  type        = list(string)
}

variable "project_name" {
  description = "Display name in create mode; defaults to the project ID."
  type        = string
  default     = null
}

variable "folder_id" {
  description = "Folder for the project in create mode (section 2.1); unused when supplied."
  type        = string
  default     = null
}

variable "billing_account" {
  description = "Billing account in create mode; unused when supplied."
  type        = string
  default     = null
}

variable "tiers" {
  description = "Tiers the estate declares; with both nonprod and prod, a hub cannot also be the CI/CD project (section 2.2)."
  type        = list(string)
  default     = []
}

variable "cicd_project_id" {
  description = "Estate cicd_project_id (null: the hub is also the CI/CD project)."
  type        = string
  default     = null
}
