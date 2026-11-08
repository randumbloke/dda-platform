# Alerts on the plumbing this stack owns (design sections 2.5.1, 5.8): a message on any
# dead-letter topic raises an alert to the governance engineers. Alerts on Cloud Run, the sweep
# and subscription backlog are created by cdmc-governance with the control plane (section 5.8).

resource "google_monitoring_alert_policy" "dead_letter" {
  for_each = local.topics

  project               = local.hub_project_id
  display_name          = "DDA ${var.env}: message dead-lettered on ${module.ids.dead_letter_topics[each.key]}"
  combiner              = "OR"
  notification_channels = var.notification_channels
  user_labels           = module.platform_labels.labels
  severity              = "WARNING"

  conditions {
    display_name = "Messages published to ${module.ids.dead_letter_topics[each.key]}"

    condition_threshold {
      filter          = "resource.type = \"pubsub_topic\" AND resource.labels.topic_id = \"${google_pubsub_topic.dead_letter[each.key].name}\" AND metric.type = \"pubsub.googleapis.com/topic/send_message_operation_count\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }

      trigger {
        count = 1
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "A message on `${module.ids.dead_letter_topics[each.key]}` failed 10 deliveries (design section 2.5.1). The next daily sweep re-evaluates every asset; inspect the subscriber's logs for the cause."
  }
}
