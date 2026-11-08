/**
 Bootstrap inputs (design §6.6, §6.16.1).

 Non-sensitive values: bootstrap.tfvars (committed).
 Sensitive values (organisation ID, billing account, customer ID, team membership lists):
 bootstrap.auto.tfvars (git-ignored; a copy is kept in the bootstrap state folder).
 */

# --------------------------------------------------------------------------------------------
# Stage (design §6.6.1, §6.6.2)
# --------------------------------------------------------------------------------------------

variable "stage" {
  description = "Bootstrap stage. 1: foundation (§6.6.1 stage 1 row). 2: adds the connection, linked repositories, triggers with inline builds, first markers and identities.json. Stage 2 includes every stage 1 resource."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2], var.stage)
    error_message = "stage must be 1 or 2."
  }
}

variable "merge_gate_image_digest" {
  description = "Digest (sha256:...) of dda-ci/merge-gate, built by a bootstrap administrator from the reviewed dda-platform commit (§6.6.2 step 2). Required at stage 2."
  type        = string
  default     = null

  validation {
    condition     = var.merge_gate_image_digest == null || can(regex("^sha256:[0-9a-f]{64}$", var.merge_gate_image_digest))
    error_message = "merge_gate_image_digest must be sha256:<64 hex>."
  }
}

variable "runner_image_digest" {
  description = "Digest (sha256:...) of dda-ci/terraform-runner (§6.4.2). Required at stage 2."
  type        = string
  default     = null

  validation {
    condition     = var.runner_image_digest == null || can(regex("^sha256:[0-9a-f]{64}$", var.runner_image_digest))
    error_message = "runner_image_digest must be sha256:<64 hex>."
  }
}

variable "github_app_installation_id" {
  description = "Installation ID of the Cloud Build GitHub App on the account or organisation (§6.4.1 step 1). Required at stage 2."
  type        = number
  default     = null
}

# --------------------------------------------------------------------------------------------
# Estate parameters (§6.16.1); sensitive ones from bootstrap.auto.tfvars
# --------------------------------------------------------------------------------------------

variable "organization_id" {
  description = "Organisation ID (bootstrap.auto.tfvars)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.organization_id))
    error_message = "organization_id must be numeric."
  }
}

variable "customer_id" {
  description = "Cloud Identity customer ID, for example C0xxxxxxx (bootstrap.auto.tfvars)."
  type        = string

  validation {
    condition     = can(regex("^C[0-9a-z]+$", var.customer_id))
    error_message = "customer_id must look like C0123abcd."
  }
}

variable "billing_account" {
  description = "Billing account ID (bootstrap.auto.tfvars)."
  type        = string

  validation {
    condition     = can(regex("^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$", var.billing_account))
    error_message = "billing_account must be XXXXXX-XXXXXX-XXXXXX (upper-case hex)."
  }
}

variable "prefix" {
  description = "Project name prefix (§1.6)."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,9}$", var.prefix))
    error_message = "prefix must be 2-10 lower-case letters or digits, starting with a letter."
  }
}

variable "environments" {
  description = "Environments the estate declares, in promotion order."
  type        = list(string)

  validation {
    condition     = length(var.environments) > 0 && alltrue([for e in var.environments : contains(["dev", "test", "uat", "prod"], e)])
    error_message = "environments must be a non-empty subset of dev, test, uat, prod."
  }
}

variable "tiers" {
  description = "Tiers the estate declares."
  type        = list(string)

  validation {
    condition     = length(var.tiers) > 0 && alltrue([for t in var.tiers : contains(["nonprod", "prod"], t)])
    error_message = "tiers must be a non-empty subset of nonprod, prod."
  }
}

variable "regions" {
  description = "Deployment regions; the first is the home region (§2.10.1)."
  type        = list(string)
  default     = ["australia-southeast1"]

  validation {
    condition     = length(var.regions) > 0
    error_message = "regions must have at least one entry."
  }
}

variable "group_domain" {
  description = "Domain of the Google groups (§1.6)."
  type        = string
}

variable "hub_project_ids" {
  description = "Hub project ID per tier (§1.2)."
  type        = map(string)

  validation {
    condition     = alltrue([for k, v in var.hub_project_ids : contains(["nonprod", "prod"], k) && can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", v))])
    error_message = "hub_project_ids keys must be tiers and values valid project IDs."
  }
}

variable "cicd_project_id" {
  description = "Dedicated CI/CD project ID, or null when the hub is also the CI/CD project (§6.13.5). The provider default project is this value, so phase 1 requires it."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.cicd_project_id))
    error_message = "cicd_project_id must be a valid project ID. A null CI/CD project (hub as CI/CD) is not supported by this draft."
  }
}

variable "core_data_project_ids" {
  description = "Core data project ID per environment."
  type        = map(string)
}

variable "domain_analytics_project_ids" {
  description = "Analytics project ID per environment and business domain."
  type        = map(map(string))
}

variable "create_projects" {
  description = "§6.13.5. false: projects are supplied; bootstrap creates no folder or project."
  type        = bool
  default     = true
}

variable "manage_project_services" {
  description = "§6.13.5. true: Terraform enables APIs."
  type        = bool
  default     = true
}

variable "manage_service_identities" {
  description = "§6.13.5. true: Terraform generates service agents."
  type        = bool
  default     = true
}

variable "manage_org_policies" {
  description = "§6.13.5. false (OD-1): bootstrap sets no organisation policy and creates the admin-activity sink on the CI/CD project."
  type        = bool
  default     = true
}

variable "github_owner_type" {
  description = "organization or user (§6.6, P6-34)."
  type        = string
  default     = "organization"

  validation {
    condition     = contains(["organization", "user"], var.github_owner_type)
    error_message = "github_owner_type must be organization or user."
  }
}

variable "github_owner" {
  description = "GitHub organisation or personal account that owns the repositories."
  type        = string
}

variable "single_deployer" {
  description = "§6.7.2. true: every trigger applies as tf-deployer and plans as tf-deployer-plan. One tier only."
  type        = bool
  default     = false
}

variable "repository_visibility" {
  description = "Visibility of every repository (§6.1, P6-20)."
  type        = string
  default     = "private"

  validation {
    condition     = contains(["private", "public"], var.repository_visibility)
    error_message = "repository_visibility must be private or public."
  }
}

variable "github_rulesets_enabled" {
  description = "Option 2 of §6.5.4: a ruleset on main in every repository."
  type        = bool
  default     = false
}

# --------------------------------------------------------------------------------------------
# Domains, groups and identities
# --------------------------------------------------------------------------------------------

variable "domains" {
  description = "Business domains; each gets a dda-<business> repository (§6.6.5)."
  type        = list(string)

  validation {
    condition     = alltrue([for d in var.domains : can(regex("^[a-z][a-z0-9]{1,20}$", d))])
    error_message = "Each domain must be a short lower-case business name, for example customer."
  }
}

variable "approval_groups" {
  description = "Group name => list of {github_login, google_account} (§6.6.4). Includes dda-<d>-producers. bootstrap.auto.tfvars."
  type = map(list(object({
    github_login   = string
    google_account = string
  })))
  default = {}

  validation {
    condition     = alltrue([for g in keys(var.approval_groups) : can(regex("^dda-[a-z0-9-]+$", g))])
    error_message = "Group names must start with dda-."
  }
}

variable "group_repositories" {
  description = "In user mode, the repositories whose collaborators each approval group's members become (§6.6). dda-<d>-producers groups are added for their own domain repository automatically."
  type        = map(list(string))
  default = {
    "dda-platform-engineers"   = ["dda-platform"]
    "dda-governance-engineers" = ["cdmc-governance", "kc-control-plane"]
    "dda-governance-admins"    = ["cdmc-governance"]
  }
}

variable "machine_users" {
  description = "GitHub machine users (§6.6.3). Their merges fail merge gate check 6."
  type = object({
    gate_bot    = string
    scangen_bot = string
  })
  default = {
    gate_bot    = "dda-gate-bot"
    scangen_bot = "dda-scangen-bot"
  }
}

variable "manage_group_memberships" {
  description = "Set Google group memberships from approval_groups (§6.6.4). The groups themselves must already exist (§2.4.6)."
  type        = bool
  default     = true
}

variable "manage_deployer_service_accounts" {
  description = "true: bootstrap creates tf-deployer and tf-deployer-plan (§6.6.1). false: they were created by hand (change task 2.5) and are only read."
  type        = bool
  default     = true
}

variable "token_expiry_dates" {
  description = "Secret name => token expiry date (YYYY-MM-DD), set as label expire_time at rotation (§6.6.3)."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for v in values(var.token_expiry_dates) : can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", v))])
    error_message = "Expiry dates must be YYYY-MM-DD."
  }
}

variable "alert_notification_emails" {
  description = "Email addresses notified by the admin-activity alert (§6.15.4). bootstrap.auto.tfvars."
  type        = list(string)
  default     = []
}

variable "policy_tags_enabled" {
  description = "Create ddaPolicyTagApplier (only when the policy_tags component is on, P6-36)."
  type        = bool
  default     = false
}

variable "control_plane_images" {
  description = "Images built by kc-control-plane-image: name => Dockerfile path in kc-control-plane (§6.10). Phase 1: the evaluator only."
  type        = map(string)
  default = {
    # VERIFY IN BUILD (estate): Dockerfile location agreed with the kc-control-plane draft (build/).
    evaluator = "build/evaluator/Dockerfile"
  }
}

variable "gate_ci_wait_minutes" {
  description = "Merge gate check 3: minutes to wait for ci-checks (§6.5.1)."
  type        = number
  default     = 20
}
