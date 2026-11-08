# The environment's hub topics and dead-letter topics, with their publisher grants (design
# sections 2.5, 2.5.1, 6.13.2). Subscriptions belong to cdmc-governance (section 6.14.2).
# Topics are global; the message storage policy keeps messages in the estate's regions.

locals {
  flags = var.components

  # Which logical topics this phase needs (section 6.17). Phase 1: kc-evaluator (feed-evaluator),
  # findings and notifications (evaluator output).
  topic_enabled = {
    "kc-evaluator"           = true
    "findings"               = true
    "notifications"          = true
    "kc-classifier"          = local.flags.classifier
    "product-classification" = local.flags.classifier
    "sdp-profiles"           = local.flags.sdp_notifications
    "access-requests"        = local.flags.access_request_sink
    "narratives"             = local.flags.explainer
  }
  topics = { for t, on in local.topic_enabled : t => module.ids.topics[t] if on }

  hub_sa = module.ids.hub_service_accounts

  # Publishers per logical topic (sections 2.4.1, 2.4.5). Component accounts are listed only
  # when their component is on. The access-requests sink's writer identity is granted in
  # main.audit.tf, because it exists only after the sink.
  # Map keys are static names, so for_each keys are known at plan even when an email is not.
  evaluator_family = merge(
    { evaluator = "serviceAccount:${local.hub_sa["evaluator"]}" },
    local.flags.access_request_gate ? { gate = "serviceAccount:${local.hub_sa["gate"]}" } : {},
    local.flags.reconciler ? { reconciler = "serviceAccount:${local.hub_sa["reconciler"]}" } : {},
  )
  topic_publishers = {
    "kc-evaluator"           = { hub-dataplex-agent = "serviceAccount:${local.hub_agents["dataplex"]}" }
    "kc-classifier"          = { hub-dataplex-agent = "serviceAccount:${local.hub_agents["dataplex"]}" }
    "findings"               = local.evaluator_family
    "notifications"          = local.evaluator_family
    "product-classification" = { classifier = "serviceAccount:${local.hub_sa["classifier"]}" }
    "sdp-profiles"           = { for p in local.data_project_ids : "dlp-agent-${p}" => "serviceAccount:${module.data_project_agents[p].emails["dlp"]}" }
    "narratives"             = { explainer = "serviceAccount:${local.hub_sa["explainer"]}" }
    "access-requests"        = {}
  }

  publisher_grants = merge([
    for t, _ in local.topics : { for k, m in local.topic_publishers[t] : "${t}|${k}" => { topic = t, member = m } }
  ]...)
}

resource "google_pubsub_topic" "topic" {
  for_each = local.topics

  project = local.hub_project_id
  name    = each.value
  labels  = module.platform_labels.labels

  message_storage_policy {
    allowed_persistence_regions = local.regions
  }
}

# One dead-letter topic per subscription (`<topic>-dlq`, section 2.5.1); each topic here has one
# subscription, created by cdmc-governance.
resource "google_pubsub_topic" "dead_letter" {
  for_each = local.topics

  project = local.hub_project_id
  name    = module.ids.dead_letter_topics[each.key]
  labels  = module.platform_labels.labels

  message_storage_policy {
    allowed_persistence_regions = local.regions
  }
}

resource "google_pubsub_topic_iam_member" "publisher" {
  for_each = local.publisher_grants

  project = local.hub_project_id
  topic   = google_pubsub_topic.topic[each.value.topic].name
  role    = "roles/pubsub.publisher"
  member  = each.value.member
}

# The hub Pub/Sub service agent forwards undeliverable messages to the dead-letter topic.
# (Its subscriber grant on each subscription is cdmc-governance's.)
resource "google_pubsub_topic_iam_member" "dead_letter_publisher" {
  for_each = local.topics

  project = local.hub_project_id
  topic   = google_pubsub_topic.dead_letter[each.key].name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${local.hub_agents["pubsub"]}"
}
