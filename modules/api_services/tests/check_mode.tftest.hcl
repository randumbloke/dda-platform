# terraform test for api_services (task 6.2): with manage_project_services = false, a supplied
# project missing a required API fails the plan, listing it, and nothing is enabled.

mock_provider "google" {
  mock_data "google_project_service" {
    defaults = {
      id = "kcdda-core-dwh-dev/enabled"
    }
  }
}

variables {
  project_id    = "kcdda-core-dwh-dev"
  project_types = ["core_data"]
  manage        = false
}

run "all_apis_present_passes" {
  command = plan

  assert {
    condition     = contains(output.services, "dataplex.googleapis.com") && contains(output.services, "bigquerystorage.googleapis.com")
    error_message = "Core data API set incomplete."
  }

  assert {
    condition     = length(google_project_service.this) == 0
    error_message = "Check mode must enable nothing."
  }
}

run "missing_api_fails" {
  command = plan

  override_data {
    target = data.google_project_service.check["dlp.googleapis.com"]
    values = {
      id = ""
    }
  }

  expect_failures = [output.services]
}

run "manage_mode_enables_union" {
  command = plan

  variables {
    project_id    = "kcdda-dgov-hub-nonprod"
    project_types = ["hub", "cicd"]
    manage        = true
  }

  assert {
    condition     = contains(keys(google_project_service.this), "cloudtasks.googleapis.com") && contains(keys(google_project_service.this), "cloudbuild.googleapis.com")
    error_message = "Union of hub and CI/CD APIs not enabled."
  }

  assert {
    condition     = alltrue([for s in google_project_service.this : s.disable_on_destroy == false])
    error_message = "disable_on_destroy must be false."
  }
}
