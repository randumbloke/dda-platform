# Product rollup debounce queue (design section 2.5.2), home region of the hub. Tasks are named
# from the product ID and a five-minute bucket, so Cloud Tasks drops duplicates.

resource "google_cloud_tasks_queue" "rollups" {
  project  = local.hub_project_id
  location = local.home_region
  name     = module.ids.rollup_queue

  retry_config {
    max_attempts       = 10
    min_backoff        = "10s"
    max_backoff        = "600s"
    max_doublings      = 5
    max_retry_duration = "0s"
  }

  stackdriver_logging_config {
    sampling_ratio = 1.0
  }
}

locals {
  rollup_enqueuers = compact([
    "serviceAccount:${local.hub_sa["evaluator"]}",
    local.flags.classifier ? "serviceAccount:${local.hub_sa["classifier"]}" : "",
  ])
}

resource "google_cloud_tasks_queue_iam_member" "enqueuer" {
  for_each = toset(local.rollup_enqueuers)

  project  = local.hub_project_id
  location = local.home_region
  name     = google_cloud_tasks_queue.rollups.name
  role     = "roles/cloudtasks.enqueuer"
  member   = each.value
}
