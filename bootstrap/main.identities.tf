/**
 Pipeline identities and their grants (§2.4.4, §6.7, §6.7.2: single_deployer = true).

 tf-deployer holds the union of the tf-platform, tf-governance and tf-<business> grants on the
 estate's projects; roles/dataplex.dataDomainAdmin covers binding, so ddaDomainBinder is not
 granted. tf-deployer-plan holds roles/viewer and roles/iam.securityReviewer only.
 State bucket grants are in main.state.tf; secret grants in main.secrets.tf.
 */

locals {
  deployer_accounts = {
    "tf-deployer"      = "DDA deployer: applies every repository (single_deployer, §6.7.2)"
    "tf-deployer-plan" = "DDA deployer plan account: read only (§6.7.2)"
  }
}

resource "google_service_account" "deployer" {
  for_each = var.manage_deployer_service_accounts ? local.deployer_accounts : {}

  project      = local.cicd
  account_id   = each.key
  display_name = each.key
  description  = each.value

  depends_on = [google_project_service.cicd]
}

data "google_service_account" "deployer" {
  for_each = var.manage_deployer_service_accounts ? {} : local.deployer_accounts

  project    = local.cicd
  account_id = each.key
}

locals {
  custom_role = { for k, r in google_organization_iam_custom_role.role : k => r.name }

  # Union of §2.4.4 grants for a one-tier estate with supplied projects.
  deployer_roles_hub = [
    # tf-platform (hub)
    "roles/pubsub.admin",
    "roles/cloudtasks.admin",
    "roles/logging.admin",
    "roles/monitoring.editor",
    # tf-governance (hub)
    "roles/dataplex.dataDomainAdmin",
    "roles/dataplex.catalogAdmin",
    "roles/dataplex.metadataFeedOwner",
    "roles/datacatalog.categoryAdmin",
    "roles/dlp.inspectTemplatesEditor",
    "roles/bigquery.admin",
    "roles/storage.admin",
    "roles/run.admin",
    "roles/cloudscheduler.admin",
    "roles/eventarc.admin",
    "roles/iam.serviceAccountUser",
  ]
  deployer_roles_core = [
    "roles/storage.admin",               # tf-platform: landing buckets
    "roles/bigquery.user",               # tf-<business>: create datasets (creator is owner)
    "roles/dataplex.dataScanAdmin",      # tf-<business>: scans
    "roles/dataplex.entryGroupExporter", # tf-governance: metadata feed scope.projects
    "roles/dlp.admin",                   # tf-governance: discovery configuration
    "roles/logging.configWriter",        # tf-platform: audit-log sinks (project scope; no folders)
  ]
  deployer_roles_analytics = [
    "roles/bigquery.admin",
    "roles/dataplex.dataProductsAdmin",
    "roles/dataplex.dataScanAdmin",
    "roles/dataplex.entryGroupExporter", # tf-governance: metadata feed scope.projects
    "roles/dlp.admin",
    "roles/logging.configWriter",
  ]
  # P6-39 reference pipelines (dda-<business>/envs/dev/core/main.pipeline.tf): the ingest job
  # runs in the core data project as <business>-ingest-<env>, the build job in the analytics
  # project as <business>-analytics-<env>, each with a Cloud Scheduler job. Not in the §2.4.4
  # table (contracts CD-16).
  deployer_roles_pipeline = [
    "roles/run.admin",
    "roles/cloudscheduler.admin",
    "roles/iam.serviceAccountUser",
  ]
  # Every estate project: APIs and agents (manage_project_services / manage_service_identities),
  # and the project-level agent grants of the dda-platform environment stack (§6.15.1).
  # roles/resourcemanager.projectIamAdmin is not in the §2.4.4 table; VERIFY IN BUILD (VA-99).
  deployer_roles_all = concat(
    var.manage_project_services || var.manage_service_identities ? ["roles/serviceusage.serviceUsageAdmin"] : [],
    ["roles/resourcemanager.projectIamAdmin"],
  )

  deployer_grants = merge(
    { for pair in setproduct(local.hub_projects, local.deployer_roles_hub) : "${pair[0]}|${pair[1]}" => { project = pair[0], role = pair[1] } },
    { for pair in setproduct(local.core_projects, local.deployer_roles_core) : "${pair[0]}|${pair[1]}" => { project = pair[0], role = pair[1] } },
    { for pair in setproduct(local.analytics_projects, local.deployer_roles_analytics) : "${pair[0]}|${pair[1]}" => { project = pair[0], role = pair[1] } },
    { for pair in setproduct(local.estate_projects, local.deployer_roles_all) : "${pair[0]}|${pair[1]}" => { project = pair[0], role = pair[1] } },
    { for pair in setproduct(local.data_projects, local.deployer_roles_pipeline) : "${pair[0]}|${pair[1]}" => { project = pair[0], role = pair[1] } },
  )

  # Custom roles granted at project scope (organisation custom roles, main.org.tf).
  deployer_custom_grants = merge(
    { for p in local.hub_projects : "${p}|ddaSubscriptionAdmin" => { project = p, role = "ddaSubscriptionAdmin" } },
    { for p in local.data_projects : "${p}|ddaPipelineCatalogWriter" => { project = p, role = "ddaPipelineCatalogWriter" } },
  )

  # VERIFY IN BUILD (VA-85): roles/viewer and roles/iam.securityReviewer let the plan account run
  # terraform plan, with refresh, for each stack. They hold no table data, object or secret value
  # read (VA-90).
  plan_grants = {
    for pair in setproduct(local.estate_projects, ["roles/viewer", "roles/iam.securityReviewer"]) :
    "${pair[0]}|${pair[1]}" => { project = pair[0], role = pair[1] }
  }
}

resource "google_project_iam_member" "deployer" {
  for_each = local.deployer_grants

  project = each.value.project
  role    = each.value.role
  member  = "serviceAccount:${local.deployer_email}"
}

resource "google_project_iam_member" "deployer_custom" {
  for_each = local.deployer_custom_grants

  project = each.value.project
  role    = local.custom_role[each.value.role]
  member  = "serviceAccount:${local.deployer_email}"
}

resource "google_project_iam_member" "deployer_plan" {
  for_each = local.plan_grants

  project = each.value.project
  role    = each.value.role
  member  = "serviceAccount:${local.deployer_plan_email}"
}

# CI/CD project (§6.7): build logs for every pipeline and plan account; builds.viewer for apply
# accounts so the gate can read its build's approval. No account holds cloudbuild.builds.create,
# which would also let it edit triggers (VA-83).
resource "google_project_iam_member" "cicd_log_writer" {
  for_each = { apply = local.deployer_email, plan = local.deployer_plan_email }

  project = local.cicd
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${each.value}"
}

resource "google_project_iam_member" "cicd_builds_viewer" {
  project = local.cicd
  role    = "roles/cloudbuild.builds.viewer"
  member  = "serviceAccount:${local.deployer_email}"
}

# Human principals in the CI/CD project (§6.7, §1.5.1). The bootstrap administrators' own roles
# (§6.15.4) are granted by hand before the first apply (OD-2; README.md), not here: a stack
# cannot grant the roles it needs to apply itself.
resource "google_project_iam_member" "release_approvers" {
  project = local.cicd
  role    = "roles/cloudbuild.builds.approver"
  member  = "group:${local.group["dda-release-approvers"]}"
}

resource "google_project_iam_member" "platform_engineers" {
  for_each = toset(["roles/viewer", "roles/dataplex.catalogViewer"])

  project = local.cicd
  role    = each.value
  member  = "group:${local.group["dda-platform-engineers"]}"
}

# Workload service account grants owned by the platform team / bootstrap (§2.4.1–2.4.3, §6.15.1).
locals {
  evaluator_hub_roles = [
    "roles/bigquery.jobUser",
    "roles/dataplex.catalogViewer",
    "roles/dataplex.dataDomainViewer",
    "roles/eventarc.eventReceiver",
  ]
  evaluator_data_roles = [
    "roles/dataplex.catalogViewer",
    "roles/bigquery.metadataViewer",
    "roles/dataplex.dataScanViewer",
    "roles/datalineage.viewer",
    "roles/iam.securityReviewer",
  ]
  workload_project_grants = merge(
    # evaluator-<env> on its tier's hub project
    merge([
      for e in local.nonprod_envs : {
        for r in local.evaluator_hub_roles :
        "eval-hub|${e}|${r}" => {
          project = var.hub_project_ids["nonprod"]
          role    = r
          member  = "serviceAccount:evaluator-${e}@${var.hub_project_ids["nonprod"]}.iam.gserviceaccount.com"
        }
      }
    ]...),
    # evaluator-<env> on all data projects of <env>
    merge([
      for e in local.nonprod_envs : {
        for pair in setproduct(
          distinct(concat([var.core_data_project_ids[e]], values(var.domain_analytics_project_ids[e]))),
          local.evaluator_data_roles,
        ) :
        "eval-data|${e}|${pair[0]}|${pair[1]}" => {
          project = pair[0]
          role    = pair[1]
          member  = "serviceAccount:evaluator-${e}@${var.hub_project_ids["nonprod"]}.iam.gserviceaccount.com"
        }
      }
    ]...),
    # evaluator-<env> roles/dataplex.dataProductsViewer on analytics projects of <env>
    merge([
      for e in local.nonprod_envs : {
        for p in distinct(values(var.domain_analytics_project_ids[e])) :
        "eval-dp|${e}|${p}" => {
          project = p
          role    = "roles/dataplex.dataProductsViewer"
          member  = "serviceAccount:evaluator-${e}@${var.hub_project_ids["nonprod"]}.iam.gserviceaccount.com"
        }
      }
    ]...),
    # <business>-ingest-<env> roles/bigquery.jobUser on the core data project (§2.4.2)
    merge([
      for e in local.nonprod_envs : {
        for d in var.domains :
        "ingest-job|${e}|${d}" => {
          project = var.core_data_project_ids[e]
          role    = "roles/bigquery.jobUser"
          member  = "serviceAccount:${d}-ingest-${e}@${var.core_data_project_ids[e]}.iam.gserviceaccount.com"
        }
      }
    ]...),
    # <business>-analytics-<env> roles/bigquery.jobUser on the domain's analytics project (§2.4.3)
    merge([
      for e in local.nonprod_envs : {
        for d in var.domains :
        "analytics-job|${e}|${d}" => {
          project = var.domain_analytics_project_ids[e][d]
          role    = "roles/bigquery.jobUser"
          member  = "serviceAccount:${d}-analytics-${e}@${var.domain_analytics_project_ids[e][d]}.iam.gserviceaccount.com"
        }
      }
    ]...),
  )

  workload_custom_grants = merge([
    for e in local.nonprod_envs : {
      for p in distinct(concat([var.core_data_project_ids[e]], values(var.domain_analytics_project_ids[e]))) :
      "eval-aspect|${e}|${p}" => {
        project = p
        role    = "ddaAspectWriter"
        member  = "serviceAccount:evaluator-${e}@${var.hub_project_ids["nonprod"]}.iam.gserviceaccount.com"
      }
    }
  ]...)
}

resource "google_project_iam_member" "workload" {
  for_each = local.workload_project_grants

  project = each.value.project
  role    = each.value.role
  member  = each.value.member
}

resource "google_project_iam_member" "workload_custom" {
  for_each = local.workload_custom_grants

  project = each.value.project
  role    = local.custom_role[each.value.role]
  member  = each.value.member
}

resource "google_service_account_iam_member" "evaluator_self_user" {
  for_each = toset(local.nonprod_envs)

  service_account_id = "projects/${var.hub_project_ids["nonprod"]}/serviceAccounts/evaluator-${each.value}@${var.hub_project_ids["nonprod"]}.iam.gserviceaccount.com"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:evaluator-${each.value}@${var.hub_project_ids["nonprod"]}.iam.gserviceaccount.com"
}
