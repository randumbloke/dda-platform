# Metadata feeds, one per subscriber, filtered to the aspect types it consumes (design section
# 2.5; RV-A4). Scope: this environment's data projects, listed (not organizationLevel), so each
# environment's feeds see only its own projects; a new analytics project joins the scope in the
# same stack (section 6.14.2).
#
# VERIFY IN BUILD (VA-59): the feed location (default: home region).
# VERIFY IN BUILD (VA-09): event payload shape; the aspect type and project name forms below;
#   whether a feed can name cdmc-classification before the cdmc-governance tier stack (applied
#   after this stack, section 6.14.1) has created it.

locals {
  system_aspect = "projects/dataplex-types/locations/global/aspectTypes"
  custom_aspect = "projects/${local.hub_project_id}/locations/global/aspectTypes"

  feed_scope_projects = [for p in local.data_project_ids : "projects/${module.data_projects[p].number}"]

  feeds = merge(
    {
      "feed-evaluator" = {
        topic = "kc-evaluator"
        aspect_types = [
          "${local.custom_aspect}/cdmc-classification",
          "${local.system_aspect}/data-quality-scorecard",
          "${local.system_aspect}/contacts",
          "${local.system_aspect}/data-product",
          "${local.system_aspect}/refresh-cadence",
        ]
      }
    },
    local.flags.classifier ? {
      "feed-classifier" = {
        topic = "kc-classifier"
        aspect_types = [
          "${local.system_aspect}/sensitive-data-protection-profile",
          "${local.system_aspect}/schema",
        ]
      }
    } : {},
  )
}

resource "google_dataplex_metadata_feed" "feed" {
  for_each = local.feeds

  project          = local.hub_project_id
  location         = local.feed_location
  metadata_feed_id = module.ids.metadata_feeds[each.key]
  labels           = module.platform_labels.labels
  pubsub_topic     = google_pubsub_topic.topic[each.value.topic].id

  scope {
    projects = local.feed_scope_projects
  }

  filters {
    aspect_types = each.value.aspect_types
  }

  # The hub Dataplex agent must be able to publish before the feed is created.
  depends_on = [google_pubsub_topic_iam_member.publisher]
}
