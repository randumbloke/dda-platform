# terraform test for data_domain_shim/domain: the allowed-role validation (section 2.3; VA-48,
# VA-87). Plans only; no provisioner runs and no API is called.

mock_provider "google" {}
mock_provider "http" {}

variables {
  project        = "kcdda-dgov-hub-nonprod"
  location       = "australia-southeast1"
  data_domain_id = "customer-dev"
  display_name   = "Customer (dev)"
  contacts = [
    { role = "owner", identity = "group:dda-customer-dev-owners@mikegyoung.joonix.net" },
    { role = "steward", identity = "group:dda-customer-dev-stewards@mikegyoung.joonix.net" },
  ]
  labels = { "dda-env" = "dev" }
}

run "allowed_roles_pass" {
  command = plan

  variables {
    iam_members = {
      "organizations/1059663003036/roles/ddaMetadataSteward" = ["group:dda-customer-dev-stewards@mikegyoung.joonix.net"]
      "roles/dataplex.dataDomainViewer"                      = ["serviceAccount:evaluator-dev@kcdda-dgov-hub-nonprod.iam.gserviceaccount.com"]
      "organizations/1059663003036/roles/ddaDomainBinder"    = ["serviceAccount:tf-deployer@pltfrm-ngnrng.iam.gserviceaccount.com"]
    }
  }

  assert {
    condition     = terraform_data.domain.triggers_replace.data_domain_id == "customer-dev"
    error_message = "Domain resource not planned."
  }
}

run "data_role_rejected" {
  command = plan

  variables {
    iam_members = {
      "roles/bigquery.dataViewer" = ["group:dda-customer-dev-stewards@mikegyoung.joonix.net"]
    }
  }

  expect_failures = [var.iam_members]
}

run "binder_for_other_domain_rejected" {
  command = plan

  variables {
    iam_members = {
      "organizations/1059663003036/roles/ddaDomainBinder" = ["serviceAccount:tf-accounts-nonprod@pltfrm-ngnrng.iam.gserviceaccount.com"]
    }
  }

  expect_failures = [var.iam_members]
}

run "own_binder_passes" {
  command = plan

  variables {
    iam_members = {
      "organizations/1059663003036/roles/ddaDomainBinder" = ["serviceAccount:tf-customer-nonprod@pltfrm-ngnrng.iam.gserviceaccount.com"]
    }
  }
}
