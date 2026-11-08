# Landing buckets, one per domain, in the core data project (design sections 2.4.2, 6.13.2;
# contracts: `<core_data_project_id>-<business>-landing`).

resource "google_storage_bucket" "landing" {
  for_each = toset(local.businesses)

  project                     = local.core_data_project_id
  name                        = module.ids.landing_buckets[each.key]
  location                    = local.home_region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = merge(module.platform_labels.labels, { "dda-domain" = "${each.key}-${var.env}" })

  versioning {
    enabled = true
  }

  depends_on = [module.data_project_apis]
}

# The domain's ingest account reads the files it lands (section 2.4.2).
resource "google_storage_bucket_iam_member" "landing_ingest_reader" {
  for_each = toset(local.businesses)

  bucket = google_storage_bucket.landing[each.key].name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${module.ids.domain_service_accounts[each.key].ingest}"
}
