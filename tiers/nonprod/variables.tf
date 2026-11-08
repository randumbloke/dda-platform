variable "tier" {
  description = "Tier this stack applies (nonprod, prod)."
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
  default     = "../../envs/labels.json"
}
