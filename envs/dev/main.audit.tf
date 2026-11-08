# Audit-log routing (design sections 2.5, 6.13.2): sinks, the dda-audit log bucket with Log
# Analytics and its linked dataset audit_logs, and writer grants. Both sinks are off in phase 1
# (components.access_request_sink, components.data_access_sink; section 6.17).
#
# The design places aggregated sinks on the shared/<env> and <business>/<env> folders. With
# create_projects = false there are no folders (section 6.13.1), so the sinks here are project
# sinks on each data project of the environment (access requests: the analytics projects, where
# data products live). VERIFY IN BUILD (VA-60): delivery to the linked dataset.

locals {
  data_access_projects    = local.flags.data_access_sink ? toset(local.data_project_ids) : toset([])
  access_request_projects = local.flags.access_request_sink ? toset(distinct([for b in local.businesses : local.analytics_project_ids[b]])) : toset([])

  data_access_filter    = "protoPayload.serviceName=\"bigquery.googleapis.com\" AND logName:\"cloudaudit.googleapis.com%2Fdata_access\""
  access_request_filter = "logName:\"cloudaudit.googleapis.com%2Factivity\" AND (protoPayload.methodName=\"google.cloud.dataplex.v1.ApprovalWorkflowService.ApproveChangeRequest\" OR protoPayload.methodName=\"google.cloud.dataplex.v1.ApprovalWorkflowService.RejectChangeRequest\")"
}

resource "google_logging_project_bucket_config" "audit" {
  count = local.flags.data_access_sink ? 1 : 0

  project          = local.hub_project_id
  location         = local.home_region
  bucket_id        = module.ids.audit_log_bucket
  retention_days   = var.audit_log_retention_days
  enable_analytics = true
  description      = "BigQuery data-access audit logs of the ${var.env} data projects (C3 direct consumption, C7 tracking)."
}

resource "google_logging_linked_dataset" "audit" {
  count = local.flags.data_access_sink ? 1 : 0

  link_id     = module.ids.audit_dataset
  bucket      = google_logging_project_bucket_config.audit[0].bucket_id
  parent      = "projects/${local.hub_project_id}"
  location    = local.home_region
  description = "Linked dataset of ${module.ids.audit_log_bucket}."
}

resource "google_logging_project_sink" "data_access" {
  for_each = local.data_access_projects

  project                = each.value
  name                   = module.ids.audit_sinks["bigquery-data-access"]
  destination            = "logging.googleapis.com/projects/${local.hub_project_id}/locations/${local.home_region}/buckets/${google_logging_project_bucket_config.audit[0].bucket_id}"
  filter                 = local.data_access_filter
  unique_writer_identity = true
}

resource "google_project_iam_member" "data_access_writer" {
  for_each = local.data_access_projects

  project = local.hub_project_id
  role    = "roles/logging.bucketWriter"
  member  = google_logging_project_sink.data_access[each.key].writer_identity

  condition {
    title      = "dda-audit-only"
    expression = "resource.name.endsWith(\"locations/${local.home_region}/buckets/${module.ids.audit_log_bucket}\")"
  }
}

# Evaluator read on the linked dataset (section 2.4.1; granted by tf-platform). Dataset access
# entry, never google_bigquery_dataset_iam_* (section 6.15.2). VERIFY IN BUILD (VA-60): that a
# linked dataset accepts an access entry.
resource "google_bigquery_dataset_access" "audit_evaluator" {
  count = local.flags.data_access_sink ? 1 : 0

  project       = local.hub_project_id
  dataset_id    = google_logging_linked_dataset.audit[0].link_id
  role          = "roles/bigquery.dataViewer"
  user_by_email = local.hub_sa["evaluator"]
}

resource "google_logging_project_sink" "access_requests" {
  for_each = local.access_request_projects

  project                = each.value
  name                   = module.ids.audit_sinks["access-requests"]
  destination            = "pubsub.googleapis.com/${google_pubsub_topic.topic["access-requests"].id}"
  filter                 = local.access_request_filter
  unique_writer_identity = true
}

resource "google_pubsub_topic_iam_member" "access_requests_writer" {
  for_each = local.access_request_projects

  project = local.hub_project_id
  topic   = google_pubsub_topic.topic["access-requests"].name
  role    = "roles/pubsub.publisher"
  member  = google_logging_project_sink.access_requests[each.key].writer_identity
}
