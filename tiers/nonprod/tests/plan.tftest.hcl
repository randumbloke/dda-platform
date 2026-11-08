# Plan-level test of the tier stack with mocked providers.

mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      project_id = "kcdda-dgov-hub-nonprod"
      number     = "210987654321"
      labels     = { "dda-domain" = "shared", "dda-tier" = "nonprod" }
    }
  }
}

mock_provider "google-beta" {}

variables {
  tier            = "nonprod"
  region          = "australia-southeast1"
  tf_state_bucket = "tfstate-pltfrm-ngnrng"
}

override_data {
  target = data.google_storage_bucket_object_content.estate
  values = {
    content = "{\"organization_id\":\"1059663003036\",\"customer_id\":\"C00000000\",\"billing_account\":\"000000-000000-000000\",\"prefix\":\"kcdda\",\"environments\":[\"dev\"],\"tiers\":[\"nonprod\"],\"regions\":[\"australia-southeast1\"],\"group_domain\":\"mikegyoung.joonix.net\",\"hub_project_ids\":{\"nonprod\":\"kcdda-dgov-hub-nonprod\"},\"cicd_project_id\":\"pltfrm-ngnrng\",\"core_data_project_ids\":{\"dev\":\"kcdda-core-dwh-dev\"},\"domain_analytics_project_ids\":{\"dev\":{\"customer\":\"kcdda-customer-analytics-dev\",\"accounts\":\"kcdda-accounts-analytics-dev\"}},\"create_projects\":false,\"manage_project_services\":true,\"manage_service_identities\":true,\"manage_org_policies\":false,\"github_owner_type\":\"user\",\"github_owner\":\"randumbloke\",\"single_deployer\":true,\"tf_state_bucket\":\"tfstate-pltfrm-ngnrng\",\"deployer_service_accounts\":{\"apply\":\"tf-deployer@pltfrm-ngnrng.iam.gserviceaccount.com\",\"plan\":\"tf-deployer-plan@pltfrm-ngnrng.iam.gserviceaccount.com\"}}"
  }
}

run "hub_plan" {
  command = plan

  assert {
    condition     = local.published.hub_project_id == "kcdda-dgov-hub-nonprod" && local.published.hub_project_number == "210987654321"
    error_message = "Hub project read from the supplied project."
  }

  assert {
    condition     = local.published.service_agents["dataplex"] == "service-210987654321@gcp-sa-dataplex.iam.gserviceaccount.com"
    error_message = "Hub Dataplex agent email."
  }

  assert {
    condition     = google_storage_bucket_object.outputs.name == "outputs/dda-platform/tiers/nonprod/outputs.json"
    error_message = "Published file path per contracts."
  }
}

# The missing-label failure is tested in modules/project_factory/tests (expect_failures cannot
# name a data source inside a module).
