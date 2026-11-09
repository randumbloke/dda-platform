# Phase 1 bootstrap values (contracts README §1; change design "Estate parameters").
# Nothing sensitive: organisation ID, billing account, customer ID and the team membership
# lists are in bootstrap.auto.tfvars (git-ignored; see bootstrap.auto.tfvars.example).

stage = 2

prefix       = "kcdda"
environments = ["dev"]
tiers        = ["nonprod"]
regions      = ["australia-southeast1"]
group_domain = "mikegyoung.joonix.net"

hub_project_ids = {
  nonprod = "kcdda-dgov-hub-nonprod"
}
cicd_project_id = "pltfrm-ngnrng"
core_data_project_ids = {
  dev = "kcdda-core-dwh-dev"
}
domain_analytics_project_ids = {
  dev = {
    customer = "kcdda-customer-analytics-dev"
    accounts = "kcdda-accounts-analytics-dev"
  }
}

create_projects           = false
manage_project_services   = true
manage_service_identities = true
manage_org_policies       = false # OD-1

github_owner_type       = "user"
github_owner            = "randumbloke"
repository_visibility   = "public"
github_rulesets_enabled = true
single_deployer         = true

domains = ["customer", "accounts"]

# Change task 2.5 creates tf-deployer and tf-deployer-plan by hand; if it does, set this to
# false (or import them) so stage 1 reads them instead of creating them.
manage_deployer_service_accounts = true
groups_admin_service_account     = "sa-builder@pltfrm-ngnrng.iam.gserviceaccount.com" # OD-7 (P6-41)
machine_users = {
  gate_bot    = "" # PoC: local randumbloke token used for merge-gate-token; no separate dda-gate-bot account
  scangen_bot = "" # phase 3+ (scan_generator)
}

# Stage 2 (after stage 1, the token versions and the image builds; README "Runbook"):
merge_gate_image_digest    = "sha256:53b12070dc3975588ff0a83b27d7907e14a87144a3084c82e2b3834940e1cd7d"
runner_image_digest        = "sha256:70f87b67362bece2ae4b7bfffb12ebd4be87b63b8526f78abbcd37df430cc006"
github_app_installation_id = 9757498
