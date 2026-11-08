# terraform test for project_factory (task 6.2): a supplied project missing a role label fails
# the plan; a correctly labelled one passes.

mock_provider "google" {}

variables {
  project_id          = "kcdda-core-dwh-dev"
  project_type        = "core_data"
  create_project      = false
  labels              = { "dda-domain" = "shared", "dda-env" = "dev" }
  required_label_keys = ["dda-domain", "dda-env"]
}

run "supplied_project_with_labels_passes" {
  command = plan

  override_data {
    target = data.google_project.supplied[0]
    values = {
      project_id = "kcdda-core-dwh-dev"
      number     = "123456789012"
      labels     = { "dda-domain" = "shared", "dda-env" = "dev" }
    }
  }

  assert {
    condition     = output.number == "123456789012"
    error_message = "Project number not read from the supplied project."
  }
}

run "supplied_project_missing_label_fails" {
  command = plan

  override_data {
    target = data.google_project.supplied[0]
    values = {
      project_id = "kcdda-core-dwh-dev"
      number     = "123456789012"
      labels     = { "dda-domain" = "shared" }
    }
  }

  expect_failures = [data.google_project.supplied[0]]
}

run "supplied_project_wrong_env_fails" {
  command = plan

  override_data {
    target = data.google_project.supplied[0]
    values = {
      project_id = "kcdda-core-dwh-dev"
      number     = "123456789012"
      labels     = { "dda-domain" = "shared", "dda-env" = "prod" }
    }
  }

  expect_failures = [data.google_project.supplied[0]]
}

run "hub_missing_tier_label_fails" {
  command = plan

  variables {
    project_id          = "kcdda-dgov-hub-nonprod"
    project_type        = "hub"
    labels              = { "dda-domain" = "shared", "dda-tier" = "nonprod" }
    required_label_keys = ["dda-domain", "dda-tier"]
  }

  override_data {
    target = data.google_project.supplied[0]
    values = {
      project_id = "kcdda-dgov-hub-nonprod"
      number     = "210987654321"
      labels     = { "dda-domain" = "shared", "dda-env" = "nonprod" }
    }
  }

  expect_failures = [data.google_project.supplied[0]]
}

run "two_tiers_need_separate_cicd_project" {
  command = plan

  variables {
    project_id          = "kcdda-dgov-hub-nonprod"
    project_type        = "hub"
    labels              = { "dda-domain" = "shared", "dda-tier" = "nonprod" }
    required_label_keys = ["dda-domain", "dda-tier"]
    tiers               = ["nonprod", "prod"]
    cicd_project_id     = null
  }

  override_data {
    target = data.google_project.supplied[0]
    values = {
      project_id = "kcdda-dgov-hub-nonprod"
      number     = "210987654321"
      labels     = { "dda-domain" = "shared", "dda-tier" = "nonprod" }
    }
  }

  expect_failures = [output.project_id]
}
