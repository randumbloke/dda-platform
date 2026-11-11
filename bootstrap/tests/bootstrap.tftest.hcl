# Offline tests of the bootstrap stack with mocked providers (no credentials, no cloud calls):
#   terraform init -backend=false && terraform test
# `command = apply` here applies to mock providers only.

mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }
  mock_resource "google_logging_project_sink" {
    defaults = {
      writer_identity = "serviceAccount:service-123456789012@gcp-sa-logging.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_logging_organization_sink" {
    defaults = {
      writer_identity = "serviceAccount:o123-456@gcp-sa-logging.iam.gserviceaccount.com"
    }
  }
}

mock_provider "google" {
  alias = "groups_admin"
}

mock_provider "google-beta" {
  mock_resource "google_project_service_identity" {
    defaults = {
      email = "service-123456789012@gcp-sa-cloudbuild.iam.gserviceaccount.com"
    }
  }
}

mock_provider "github" {
  mock_data "github_branch" {
    defaults = {
      sha = "b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1"
    }
  }
}

override_resource {
  target = google_service_account.deployer["tf-deployer"]
  values = {
    email = "tf-deployer@pltfrm-ngnrng.iam.gserviceaccount.com"
  }
}

override_resource {
  target = google_service_account.deployer["tf-deployer-plan"]
  values = {
    email = "tf-deployer-plan@pltfrm-ngnrng.iam.gserviceaccount.com"
  }
}

# Mock providers cannot import: the adopted dda-platform repository is overridden instead.
override_resource {
  target = github_repository.repo["dda-platform"]
  values = {
    name                   = "dda-platform"
    visibility             = "public"
    allow_rebase_merge     = false
    delete_branch_on_merge = true
  }
}

variables {
  # bootstrap.tfvars (phase 1)
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
  manage_org_policies       = false
  github_owner_type         = "user"
  github_owner              = "randumbloke"
  repository_visibility     = "public"
  github_rulesets_enabled   = true
  single_deployer           = true
  domains                   = ["customer", "accounts"]

  # bootstrap.auto.tfvars stand-ins (not real values)
  organization_id = "1059663003036"
  customer_id     = "C0test00"
  billing_account = "000000-000000-000000"
  approval_groups = {
    "dda-platform-engineers" = [{ github_login = "person-a", google_account = "a@example.com" }]
    "dda-customer-producers" = [{ github_login = "person-b", google_account = "b@example.com" }]
  }
}

run "stage_1" {
  command = apply

  variables {
    stage = 1
  }

  assert {
    condition = sort(keys(jsondecode(google_storage_bucket_object.estate.content))) == sort([
      "organization_id", "customer_id", "billing_account", "prefix", "environments", "tiers", "regions",
      "group_domain", "hub_project_ids", "cicd_project_id", "core_data_project_ids",
      "domain_analytics_project_ids", "create_projects", "manage_project_services",
      "manage_service_identities", "manage_org_policies", "github_owner_type", "github_owner",
      "single_deployer", "tf_state_bucket", "deployer_service_accounts",
    ])
    error_message = "estate.json keys differ from schemas/estate.schema.json required properties."
  }

  assert {
    condition = (
      jsondecode(google_storage_bucket_object.estate.content).single_deployer == true &&
      jsondecode(google_storage_bucket_object.estate.content).tf_state_bucket == "tfstate-pltfrm-ngnrng" &&
      jsondecode(google_storage_bucket_object.estate.content).deployer_service_accounts.apply == "tf-deployer@pltfrm-ngnrng.iam.gserviceaccount.com" &&
      jsondecode(google_storage_bucket_object.estate.content).deployer_service_accounts.plan == "tf-deployer-plan@pltfrm-ngnrng.iam.gserviceaccount.com" &&
      can(regex("^[a-z][a-z0-9]{1,9}$", jsondecode(google_storage_bucket_object.estate.content).prefix))
    )
    error_message = "estate.json values wrong."
  }

  assert {
    condition     = google_storage_bucket.tfstate.name == "tfstate-pltfrm-ngnrng" && google_storage_bucket.tfstate.versioning[0].enabled
    error_message = "State bucket must be tfstate-pltfrm-ngnrng with versioning."
  }

  assert {
    condition = alltrue([for f in [
      "terraform/state/dda-platform/dev/", "terraform/state/dda-platform/tiers/nonprod/",
      "terraform/state/cdmc-governance/dev/", "terraform/state/cdmc-governance/tiers/nonprod/",
      "terraform/state/dda-customer/dev/", "terraform/state/dda-accounts/dev/",
      "terraform/state/dda-platform/bootstrap/", "outputs/", "outputs/kc-control-plane/",
      "outputs/dda-customer/dev/", "promotions/dda-customer/dev/", "promotions/kc-control-plane/image/",
      "gate/accepted/", "bootstrap/",
    ] : contains(keys(google_storage_managed_folder.folder), f)])
    error_message = "Managed folders missing."
  }

  assert {
    condition     = google_storage_managed_folder_iam_member.grant["promotions/dda-customer/dev/|apply"].role == "roles/storage.objectCreator"
    error_message = "Markers must be objectCreator (no overwrite)."
  }

  assert {
    condition = alltrue([for r in ["ddaMetadataSteward", "ddaDomainDelegate", "ddaDomainBinder", "ddaProductApprover", "ddaSubscriptionAdmin", "ddaPipelineCatalogWriter"] :
    contains(keys(google_organization_iam_custom_role.role), r)])
    error_message = "Custom roles missing."
  }

  assert {
    condition     = length(google_org_policy_policy.resource_locations) == 0 && length(google_org_policy_policy.enforced) == 0 && length(google_org_policy_policy.run_allowed_ingress) == 0
    error_message = "manage_org_policies = false: no organisation policy may be set."
  }

  assert {
    condition     = length(google_logging_project_sink.admin_activity) == 1 && length(google_logging_organization_sink.admin_activity) == 0
    error_message = "Admin-activity sink must be on the CI/CD project."
  }

  assert {
    condition     = sort(keys(github_repository.repo)) == sort(["dda-platform", "cdmc-governance", "kc-control-plane", "dda-customer", "dda-accounts"])
    error_message = "Repositories wrong."
  }

  assert {
    condition     = alltrue([for r in github_repository.repo : r.visibility == "public" && !r.allow_rebase_merge && r.delete_branch_on_merge])
    error_message = "Repository options wrong."
  }

  assert {
    condition     = length(github_repository_ruleset.main) == 5
    error_message = "Every repository needs a ruleset."
  }

  assert {
    condition = (
      contains(keys(github_repository_collaborator.collaborator), "dda-customer|person-b") &&
      contains(keys(github_repository_collaborator.collaborator), "dda-platform|person-a") &&
      contains(keys(github_repository_collaborator.collaborator), "dda-customer|dda-scangen-bot") &&
      !contains(keys(github_repository_collaborator.collaborator), "dda-platform|dda-scangen-bot")
    )
    error_message = "Collaborators wrong."
  }

  assert {
    condition     = google_artifact_registry_repository.dda_pipelines.repository_id == "dda-pipelines" && length(google_artifact_registry_repository_iam_member.pipelines_run_agent) == 3 && contains(keys(google_project_iam_member.deployer), "kcdda-core-dwh-dev|roles/run.admin")
    error_message = "dda-pipelines with a reader grant per data project (CD-12); pipeline roles on the core project."
  }

  assert {
    condition     = length(google_secret_manager_secret.secret) == 2 && length(google_cloudbuild_trigger.trigger) == 0
    error_message = "Stage 1: two secrets, no triggers."
  }

  assert {
    condition = output.apply_stack_order == {
      "dda-platform"    = ["tiers/nonprod", "envs/dev"]
      "cdmc-governance" = ["tiers/nonprod", "envs/dev"]
      "dda-customer"    = ["envs/dev/core", "envs/dev/contract"]
      "dda-accounts"    = ["envs/dev/core", "envs/dev/contract"]
    }
    error_message = "Stack order differs from §6.13.1."
  }
}

run "stage_2" {
  command = apply

  variables {
    stage                      = 2
    merge_gate_image_digest    = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    runner_image_digest        = "sha256:2222222222222222222222222222222222222222222222222222222222222222"
    github_app_installation_id = 12345678
    access_group_managers      = { "dda-dp-customer-profile-dev-reader" = ["Owner@example.com"] }
  }

  assert {
    condition = (
      tolist(keys(google_cloud_identity_group_membership.access_group_manager)) == tolist(["dda-dp-customer-profile-dev-reader|owner@example.com"]) &&
      sort([for r in google_cloud_identity_group_membership.access_group_manager["dda-dp-customer-profile-dev-reader|owner@example.com"].roles : r.name]) == tolist(["MANAGER", "MEMBER"])
    )
    error_message = "OD-11: each listed approver is MEMBER and MANAGER of the access group."
  }

  assert {
    condition = sort(keys(google_cloudbuild_trigger.trigger)) == sort([
      "dda-platform-plan", "dda-platform-apply", "cdmc-governance-plan", "cdmc-governance-apply",
      "dda-customer-plan", "dda-customer-apply", "dda-accounts-plan", "dda-accounts-apply",
      "kc-control-plane-image", "dda-customer-image", "dda-accounts-image",
      "dda-platform-gate-override", "cdmc-governance-gate-override", "dda-customer-gate-override",
      "dda-accounts-gate-override", "kc-control-plane-gate-override",
    ])
    error_message = "Trigger set differs from §6.4.3 for a dev-only estate."
  }

  assert {
    condition = alltrue([for k, t in google_cloudbuild_trigger.trigger :
      t.service_account == (endswith(k, "-plan")
        ? "projects/pltfrm-ngnrng/serviceAccounts/tf-deployer-plan@pltfrm-ngnrng.iam.gserviceaccount.com"
    : "projects/pltfrm-ngnrng/serviceAccounts/tf-deployer@pltfrm-ngnrng.iam.gserviceaccount.com")])
    error_message = "single_deployer: apply as tf-deployer, plan as tf-deployer-plan."
  }

  assert {
    condition = alltrue([for k, t in google_cloudbuild_trigger.trigger :
      t.build[0].step[0].id == "0-merge-gate" if endswith(k, "-apply") || endswith(k, "-image")
    ])
    error_message = "Every apply and image build starts with the merge gate."
  }

  assert {
    condition     = [for s in google_cloudbuild_trigger.trigger["dda-customer-apply"].build[0].step : s.id] == ["0-merge-gate", "apply-envs-dev-core", "apply-envs-dev-contract", "promote-dev"]
    error_message = "dda-customer apply build order wrong."
  }

  assert {
    condition = (
      tolist(google_cloudbuild_trigger.trigger["dda-customer-image"].included_files) == tolist(["pipelines/**"]) &&
      [for s in google_cloudbuild_trigger.trigger["dda-customer-image"].build[0].step : s.id] == ["0-merge-gate", "build-push", "publish", "promote-image"] &&
      strcontains(google_cloudbuild_trigger.trigger["dda-customer-image"].build[0].step[1].args[1], "pltfrm-ngnrng/dda-pipelines") &&
      strcontains(google_cloudbuild_trigger.trigger["dda-customer-image"].build[0].step[1].args[1], "customer-pipeline:$COMMIT_SHA") &&
      strcontains(google_cloudbuild_trigger.trigger["dda-customer-image"].build[0].step[2].args[1], "outputs%2Fdda-customer%2Fimages.json")
    )
    error_message = "OD-12: domain image trigger fires on pipelines/** and builds, publishes and marks the pipeline image."
  }

  assert {
    condition     = [for s in google_cloudbuild_trigger.trigger["dda-platform-apply"].build[0].step : s.id] == ["0-merge-gate", "apply-tiers-nonprod", "apply-envs-dev", "promote-dev"]
    error_message = "dda-platform apply build order wrong."
  }

  assert {
    condition     = contains(google_cloudbuild_trigger.trigger["dda-platform-apply"].ignored_files, "bootstrap/**") && !contains(google_cloudbuild_trigger.trigger["dda-customer-apply"].ignored_files, "bootstrap/**")
    error_message = "Only dda-platform's apply trigger ignores bootstrap/**."
  }

  assert {
    condition     = alltrue([for t in google_cloudbuild_trigger.trigger : t.filename == null && t.build[0].options[0].logging == "CLOUD_LOGGING_ONLY"])
    error_message = "Inline builds only, CLOUD_LOGGING_ONLY."
  }

  assert {
    condition     = google_cloudbuild_trigger.trigger["dda-customer-plan"].repository_event_config[0].pull_request[0].comment_control == "COMMENTS_ENABLED_FOR_EXTERNAL_CONTRIBUTORS_ONLY"
    error_message = "Pull request triggers need comment control."
  }

  assert {
    condition     = google_cloudbuild_trigger.trigger["dda-customer-gate-override"].approval_config[0].approval_required
    error_message = "Gate override needs approval."
  }

  assert {
    condition     = length(google_storage_bucket_object.first_marker) == 7 && length(google_storage_bucket_object.identities) == 1
    error_message = "Stage 2 writes first markers and identities.json."
  }

  assert {
    condition     = contains(jsondecode(google_storage_bucket_object.identities[0].content).machine_users, "dda-gate-bot")
    error_message = "identities.json must list machine users."
  }
}

run "stage_2_without_digests_fails" {
  command = plan

  variables {
    stage = 2
  }

  expect_failures = [terraform_data.guards]
}
