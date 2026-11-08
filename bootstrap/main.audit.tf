/**
 Admin-activity sink, log bucket and alert (§6.15.4).

 manage_org_policies = false (OD-1): the sink is on the CI/CD project, not the organisation, so
 it sees changes in that project only. With manage_org_policies = true it is an aggregated
 organisation sink instead. The alert fires on any IAM policy, organisation policy, custom role
 or Cloud Build trigger change made by a principal that is not a service account.
 */

locals {
  admin_log_bucket_id = "dda-admin-activity"
  admin_log_filter    = "logName:\"cloudaudit.googleapis.com%2Factivity\""

  # Changes that a person (not a service account) should rarely make.
  admin_alert_filter = join(" AND ", [
    "logName:\"cloudaudit.googleapis.com%2Factivity\"",
    "(protoPayload.methodName:\"SetIamPolicy\" OR protoPayload.methodName:\"orgpolicy\" OR protoPayload.methodName:\"CreateRole\" OR protoPayload.methodName:\"UpdateRole\" OR protoPayload.methodName:\"DeleteRole\" OR protoPayload.methodName:\"BuildTrigger\")",
    "NOT protoPayload.authenticationInfo.principalEmail:\"gserviceaccount.com\"",
  ])
}

resource "google_logging_project_bucket_config" "admin_activity" {
  project        = local.cicd
  location       = local.home_region
  bucket_id      = local.admin_log_bucket_id
  retention_days = 400 # audit_log_retention_days (§6.16.3)
  description    = "DDA admin activity audit logs (bootstrap safeguard, §6.15.4)."

  depends_on = [google_project_service.cicd]
}

locals {
  admin_log_destination = "logging.googleapis.com/${google_logging_project_bucket_config.admin_activity.id}"
}

resource "google_logging_project_sink" "admin_activity" {
  count = var.manage_org_policies ? 0 : 1

  project                = local.cicd
  name                   = "dda-admin-activity"
  destination            = local.admin_log_destination
  filter                 = local.admin_log_filter
  unique_writer_identity = true
}

resource "google_logging_organization_sink" "admin_activity" {
  count = var.manage_org_policies ? 1 : 0

  org_id           = var.organization_id
  name             = "dda-admin-activity"
  destination      = local.admin_log_destination
  filter           = local.admin_log_filter
  include_children = true
}

# A sink into a log bucket of another project needs its writer identity granted; the project
# sink writes into its own project. VERIFY IN BUILD (estate): bucketWriter needed for the
# same-project sink; granted to be safe.
resource "google_project_iam_member" "admin_sink_writer" {
  project = local.cicd
  role    = "roles/logging.bucketWriter"
  member = (var.manage_org_policies
    ? google_logging_organization_sink.admin_activity[0].writer_identity
  : google_logging_project_sink.admin_activity[0].writer_identity)
}

resource "google_monitoring_notification_channel" "admin_alert" {
  for_each = toset(var.alert_notification_emails)

  project      = local.cicd
  display_name = "DDA admin activity: ${each.value}"
  type         = "email"
  labels = {
    email_address = each.value
  }

  depends_on = [google_project_service.cicd]
}

resource "google_monitoring_alert_policy" "admin_activity" {
  project      = local.cicd
  display_name = "DDA admin activity by a person"
  combiner     = "OR"

  conditions {
    display_name = "IAM, organisation policy, custom role or trigger change by a non-service-account principal"
    condition_matched_log {
      filter = local.admin_alert_filter
      label_extractors = {
        principal = "EXTRACT(protoPayload.authenticationInfo.principalEmail)"
        method    = "EXTRACT(protoPayload.methodName)"
      }
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "1800s"
  }

  notification_channels = [for c in google_monitoring_notification_channel.admin_alert : c.id]

  documentation {
    mime_type = "text/markdown"
    content   = "A person changed IAM, an organisation policy, a custom role or a Cloud Build trigger in the DDA CI/CD scope. Confirm it was a bootstrap apply (design §6.15.4)."
  }

  depends_on = [google_project_service.cicd]
}
