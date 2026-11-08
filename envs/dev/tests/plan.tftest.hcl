# Plan-level test of the dev stack with mocked providers: reads a phase 1 estate.json and tier
# outputs, and checks the phase 1 resource set (section 6.17) and the published file's shape.
# No credentials and no API calls.

mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
      labels = { "dda-domain" = "shared", "dda-env" = "dev" }
    }
  }
}

mock_provider "google-beta" {}

variables {
  env             = "dev"
  tier            = "nonprod"
  region          = "australia-southeast1"
  tf_state_bucket = "tfstate-pltfrm-ngnrng"
  components = {
    classifier          = false
    steward_inbox       = false
    access_request_gate = false
    reconciler          = false
    explainer           = false
    scan_generator      = false
    sdp_notifications   = false
    access_request_sink = false
    data_access_sink    = false
    policy_tags         = false
    evaluator_modules   = ["c12", "c14"]
  }
}

override_data {
  target = data.google_storage_bucket_object_content.estate
  values = {
    content = "{\"organization_id\":\"1059663003036\",\"customer_id\":\"C00000000\",\"billing_account\":\"000000-000000-000000\",\"prefix\":\"kcdda\",\"environments\":[\"dev\"],\"tiers\":[\"nonprod\"],\"regions\":[\"australia-southeast1\"],\"group_domain\":\"mikegyoung.joonix.net\",\"hub_project_ids\":{\"nonprod\":\"kcdda-dgov-hub-nonprod\"},\"cicd_project_id\":\"pltfrm-ngnrng\",\"core_data_project_ids\":{\"dev\":\"kcdda-core-dwh-dev\"},\"domain_analytics_project_ids\":{\"dev\":{\"customer\":\"kcdda-customer-analytics-dev\",\"accounts\":\"kcdda-accounts-analytics-dev\"}},\"create_projects\":false,\"manage_project_services\":true,\"manage_service_identities\":true,\"manage_org_policies\":false,\"github_owner_type\":\"user\",\"github_owner\":\"randumbloke\",\"single_deployer\":true,\"tf_state_bucket\":\"tfstate-pltfrm-ngnrng\",\"deployer_service_accounts\":{\"apply\":\"tf-deployer@pltfrm-ngnrng.iam.gserviceaccount.com\",\"plan\":\"tf-deployer-plan@pltfrm-ngnrng.iam.gserviceaccount.com\"}}"
  }
}

override_data {
  target = data.google_storage_bucket_object_content.tier_outputs
  values = {
    content = "{\"tier\":\"nonprod\",\"hub_project_id\":\"kcdda-dgov-hub-nonprod\",\"hub_project_number\":\"210987654321\",\"service_agents\":{\"dataplex\":\"service-210987654321@gcp-sa-dataplex.iam.gserviceaccount.com\",\"dlp\":\"service-210987654321@dlp-api.iam.gserviceaccount.com\",\"pubsub\":\"service-210987654321@gcp-sa-pubsub.iam.gserviceaccount.com\"}}"
  }
}

run "phase1_plan" {
  command = plan

  assert {
    condition     = toset(keys(google_pubsub_topic.topic)) == toset(["kc-evaluator", "findings", "notifications"])
    error_message = "Phase 1 topics must be kc-evaluator, findings, notifications."
  }

  assert {
    condition     = google_pubsub_topic.topic["kc-evaluator"].name == "kc-evaluator-dev" && google_pubsub_topic.dead_letter["kc-evaluator"].name == "kc-evaluator-dev-dlq"
    error_message = "Topic names must carry the environment suffix and -dlq."
  }

  assert {
    condition     = toset(keys(google_dataplex_metadata_feed.feed)) == toset(["feed-evaluator"])
    error_message = "Phase 1 has feed-evaluator only."
  }

  assert {
    condition     = google_cloud_tasks_queue.rollups.name == "product-rollups-dev"
    error_message = "Rollup queue name."
  }

  assert {
    condition     = length(google_logging_project_sink.data_access) == 0 && length(google_logging_project_bucket_config.audit) == 0 && length(google_logging_project_sink.access_requests) == 0
    error_message = "Audit sinks are off in phase 1."
  }

  assert {
    condition     = google_storage_bucket.landing["customer"].name == "kcdda-core-dwh-dev-customer-landing"
    error_message = "Landing bucket name per contracts."
  }

  assert {
    condition     = toset(keys(local.published.projects)) == toset(["core", "customer", "accounts"])
    error_message = "Published projects keyed core | <business>."
  }

  assert {
    condition     = local.published.domain_service_accounts["accounts"].ingest == "accounts-ingest-dev@kcdda-core-dwh-dev.iam.gserviceaccount.com"
    error_message = "Ingest service account lives in the core data project (design section 2.4.2)."
  }

  assert {
    condition     = local.published.folders == {}
    error_message = "No folders with create_projects = false."
  }
}

run "policy_tags_needs_gate_and_reconciler" {
  command = plan

  variables {
    components = {
      classifier          = false
      steward_inbox       = false
      access_request_gate = false
      reconciler          = false
      explainer           = false
      scan_generator      = false
      sdp_notifications   = false
      access_request_sink = false
      data_access_sink    = false
      policy_tags         = true
      evaluator_modules   = ["c12", "c14"]
    }
  }

  expect_failures = [var.components]
}

run "later_phase_flags_plan" {
  command = plan

  variables {
    components = {
      classifier          = true
      steward_inbox       = true
      access_request_gate = true
      reconciler          = true
      explainer           = true
      scan_generator      = false
      sdp_notifications   = true
      access_request_sink = true
      data_access_sink    = true
      policy_tags         = true
      evaluator_modules   = ["c12", "c14", "c6"]
    }
  }

  assert {
    condition     = length(google_pubsub_topic.topic) == 8 && length(google_dataplex_metadata_feed.feed) == 2
    error_message = "All topics and both feeds when every flag is on."
  }

  assert {
    condition     = length(google_logging_project_sink.data_access) == 3 && length(google_logging_project_sink.access_requests) == 2
    error_message = "Data-access sinks on every data project; access-request sinks on analytics projects."
  }
}
