# terraform test for data_domain_shim/binding: key and resource validation, and the grant per
# resource type. Plans only; no provisioner runs.

mock_provider "google" {}

variables {
  domain_name     = "projects/kcdda-dgov-hub-nonprod/locations/australia-southeast1/dataDomains/customer-dev-curated"
  policy_member   = "principal://dataplex.googleapis.com/projects/210987654321/locations/australia-southeast1/dataDomains/customer-dev-curated"
  organization_id = "1059663003036"
}

run "dataset_and_product_bindings" {
  command = plan

  variables {
    bindings = {
      "ds-customer-curated" = "//bigquery.googleapis.com/projects/kcdda-core-dwh-dev/datasets/customer_curated"
      "dp-customer-profile" = "//dataplex.googleapis.com/projects/kcdda-customer-analytics-dev/locations/australia-southeast1/dataProducts/customer-profile"
    }
  }

  assert {
    condition     = google_bigquery_dataset_access.delegate["ds-customer-curated"].role == "organizations/1059663003036/roles/ddaDomainDelegate"
    error_message = "Dataset grant must use ddaDomainDelegate."
  }

  assert {
    condition     = google_dataplex_data_product_iam_member.delegate["dp-customer-profile"].data_product_id == "customer-profile"
    error_message = "Product grant must target the product."
  }

  assert {
    condition     = output.binding_names["ds-customer-curated"] == "${var.domain_name}/bindings/ds-customer-curated"
    error_message = "Binding name derives from the key."
  }
}

run "bad_key_rejected" {
  command = plan

  variables {
    bindings = {
      "customer_curated" = "//bigquery.googleapis.com/projects/kcdda-core-dwh-dev/datasets/customer_curated"
    }
  }

  expect_failures = [var.bindings]
}

run "unsupported_resource_rejected" {
  command = plan

  variables {
    bindings = {
      "ds-customer-curated" = "//storage.googleapis.com/projects/_/buckets/x"
    }
  }

  expect_failures = [var.bindings]
}
