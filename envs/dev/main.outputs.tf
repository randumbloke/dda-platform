# Published values (design section 6.13.3; schema outputs_platform_env.schema.json).
locals {
  project_entry = {
    for p in local.data_project_ids : p => {
      project_id     = module.data_projects[p].project_id
      number         = module.data_projects[p].number
      service_agents = module.data_project_agents[p].emails
    }
  }

  published = {
    env = var.env
    # No folders when create_projects = false (section 6.13.1).
    folders = {}
    # Key: core | <business> (analytics project of that business).
    projects = merge(
      { core = local.project_entry[local.core_data_project_id] },
      { for b in local.businesses : b => local.project_entry[local.analytics_project_ids[b]] },
    )
    landing_buckets = { for b, bkt in google_storage_bucket.landing : b => bkt.name }
    topics = merge(
      { for t, r in google_pubsub_topic.topic : t => r.id },
      { for t, r in google_pubsub_topic.dead_letter : "${t}-dlq" => r.id },
    )
    metadata_feeds = { for f, _ in local.feeds : f => "projects/${local.hub_project_id}/locations/${local.feed_location}/metadataFeeds/${module.ids.metadata_feeds[f]}" }
    # Created by the platform team (section 2.4; task 2.5), not by this stack.
    domain_service_accounts = module.ids.domain_service_accounts
  }
}

resource "google_storage_bucket_object" "outputs" {
  bucket       = var.tf_state_bucket
  name         = "outputs/dda-platform/${var.env}/outputs.json"
  content_type = "application/json"
  content      = jsonencode(local.published)

  depends_on = [google_dataplex_metadata_feed.feed]
}
