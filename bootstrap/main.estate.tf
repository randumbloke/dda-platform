/**
 Estate locals, guards and bootstrap/estate.json (design §6.13.3, §6.13.5, §6.16.1).
 */

locals {
  home_region = var.regions[0]
  cicd        = var.cicd_project_id

  # Repositories (§6.1). dda-platform exists and is adopted by import (main.github.tf).
  terraform_repositories = concat(["dda-platform", "cdmc-governance"], [for d in var.domains : "dda-${d}"])
  repositories           = concat(local.terraform_repositories, ["kc-control-plane"])
  domain_repositories    = { for d in var.domains : "dda-${d}" => d }

  nonprod_envs = [for e in var.environments : e if contains(["dev", "test"], e)]
  prod_envs    = [for e in var.environments : e if contains(["uat", "prod"], e)]

  # Ordered stack lists per repository (§6.13.1, §6.13.2). No org/ stack when
  # create_projects = false.
  repo_tier_stacks = {
    "dda-platform"    = ["tiers/nonprod"]
    "cdmc-governance" = ["tiers/nonprod"]
  }
  repo_env_stacks = merge(
    {
      "dda-platform"    = [""]
      "cdmc-governance" = [""]
    },
    { for r in keys(local.domain_repositories) : r => ["core", "contract"] },
  )

  # Non-production apply build: [org/], tiers/nonprod/, then each stack of dev, then test.
  apply_stacks = {
    for r in local.terraform_repositories : r => concat(
      r == "dda-platform" && var.create_projects ? [{ dir = "org", env = "", tfvars = "org.tfvars" }] : [],
      [for t in lookup(local.repo_tier_stacks, r, []) : { dir = t, env = "", tfvars = "${basename(t)}.tfvars" }],
      flatten([
        for e in local.nonprod_envs : [
          for s in local.repo_env_stacks[r] : {
            dir    = s == "" ? "envs/${e}" : "envs/${e}/${s}"
            env    = e
            tfvars = "${e}.tfvars"
          }
        ]
      ]),
    )
  }

  # Plan on pull request: the same stacks for dev only (§6.4.3 `_ENV=dev`).
  plan_stacks = {
    for r, stacks in local.apply_stacks : r => [for s in stacks : s if s.env == "" || s.env == "dev"]
  }

  # Pipeline identities (§6.7, §6.7.2).
  deployer_email      = var.manage_deployer_service_accounts ? google_service_account.deployer["tf-deployer"].email : data.google_service_account.deployer["tf-deployer"].email
  deployer_plan_email = var.manage_deployer_service_accounts ? google_service_account.deployer["tf-deployer-plan"].email : data.google_service_account.deployer["tf-deployer-plan"].email

  # Apply / plan account per repository. Split accounts (single_deployer = false) are not
  # drafted in phase 1; the guard below refuses that configuration.
  apply_account = { for r in local.repositories : r => local.deployer_email }
  plan_account  = { for r in local.repositories : r => local.deployer_plan_email }

  # Estate projects (supplied, create_projects = false).
  hub_projects       = values(var.hub_project_ids)
  core_projects      = values(var.core_data_project_ids)
  analytics_projects = distinct(flatten([for e, m in var.domain_analytics_project_ids : values(m)]))
  data_projects      = distinct(concat(local.core_projects, local.analytics_projects))
  estate_projects    = distinct(concat(local.hub_projects, local.data_projects))

  group = { for g in ["dda-bootstrap-admins", "dda-release-approvers", "dda-platform-engineers"] : g => "${g}@${var.group_domain}" }

  estate = {
    organization_id              = var.organization_id
    customer_id                  = var.customer_id
    billing_account              = var.billing_account
    prefix                       = var.prefix
    environments                 = var.environments
    tiers                        = var.tiers
    regions                      = var.regions
    group_domain                 = var.group_domain
    hub_project_ids              = var.hub_project_ids
    cicd_project_id              = var.cicd_project_id
    core_data_project_ids        = var.core_data_project_ids
    domain_analytics_project_ids = var.domain_analytics_project_ids
    create_projects              = var.create_projects
    manage_project_services      = var.manage_project_services
    manage_service_identities    = var.manage_service_identities
    manage_org_policies          = var.manage_org_policies
    github_owner_type            = var.github_owner_type
    github_owner                 = var.github_owner
    single_deployer              = var.single_deployer
    tf_state_bucket              = google_storage_bucket.tfstate.name
    deployer_service_accounts = {
      apply = local.deployer_email
      plan  = local.deployer_plan_email
    }
  }
}

# Cross-variable guards: fail the plan before anything changes.
resource "terraform_data" "guards" {
  input = var.stage

  lifecycle {
    precondition {
      condition     = !var.single_deployer || length(var.tiers) == 1
      error_message = "single_deployer = true is allowed for a one-tier estate only (§6.7.2)."
    }
    precondition {
      condition     = var.single_deployer
      error_message = "This draft implements single_deployer = true only (phase 1, §6.17). Split accounts arrive with test/uat/prod."
    }
    precondition {
      condition     = !var.create_projects
      error_message = "This draft implements supplied projects only (create_projects = false, §6.13.5)."
    }
    precondition {
      condition     = var.stage < 2 || (var.merge_gate_image_digest != null && var.runner_image_digest != null && var.github_app_installation_id != null)
      error_message = "Stage 2 needs merge_gate_image_digest, runner_image_digest and github_app_installation_id (§6.6.2 step 3)."
    }
    precondition {
      condition     = alltrue([for e in keys(var.core_data_project_ids) : contains(var.environments, e)])
      error_message = "core_data_project_ids keys must be declared environments."
    }
    precondition {
      condition     = alltrue([for t in keys(var.hub_project_ids) : contains(var.tiers, t)])
      error_message = "hub_project_ids keys must be declared tiers."
    }
  }
}

# bootstrap/estate.json (schemas/estate.schema.json). Writer: bootstrap only.
resource "google_storage_bucket_object" "estate" {
  bucket       = google_storage_bucket.tfstate.name
  name         = "bootstrap/estate.json"
  content_type = "application/json"
  content      = jsonencode(local.estate)

  depends_on = [google_storage_managed_folder.folder]
}
