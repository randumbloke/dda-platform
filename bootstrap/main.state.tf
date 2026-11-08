/**
 Terraform state bucket and managed folders (§6.8, §6.7.2).

 One writer per folder. With single_deployer = true, tf-deployer writes every state, output,
 marker and accepted-range folder; bootstrap/ and the bootstrap state stay with
 dda-bootstrap-admins (who hold roles/storage.admin on the CI/CD project, §6.15.4);
 tf-deployer-plan reads.
 */

resource "google_storage_bucket" "tfstate" {
  project  = local.cicd
  name     = "tfstate-${local.cicd}"
  location = local.home_region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  # Delete a non-current version once 20 newer versions exist and it has been non-current for
  # 30 days (§6.8, §6.16.3).
  lifecycle_rule {
    condition {
      num_newer_versions         = 20
      days_since_noncurrent_time = 30
      with_state                 = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    dda-domain = "shared"
  }

  depends_on = [google_project_service.cicd]
}

locals {
  # Parent folders for readers; each is a managed folder in its own right.
  reader_roots = ["outputs/", "promotions/", "gate/accepted/", "bootstrap/"]

  tier_pairs = flatten([for r, ts in local.repo_tier_stacks : [for t in ts : { repo = r, dir = t }]])

  state_env_folders = {
    for pair in setproduct(local.terraform_repositories, local.nonprod_envs) :
    "terraform/state/${pair[0]}/${pair[1]}/" => { kind = "state", repo = pair[0] }
  }
  state_tier_folders = {
    for p in local.tier_pairs : "terraform/state/${p.repo}/${p.dir}/" => { kind = "state", repo = p.repo }
  }
  output_folders = merge(
    { for pair in setproduct(local.terraform_repositories, local.nonprod_envs) : "outputs/${pair[0]}/${pair[1]}/" => { kind = "output", repo = pair[0] } },
    { for p in local.tier_pairs : "outputs/${p.repo}/${p.dir}/" => { kind = "output", repo = p.repo } },
    { "outputs/kc-control-plane/" = { kind = "output", repo = "kc-control-plane" } },
  )
  marker_folders = merge(
    { for pair in setproduct(local.terraform_repositories, local.nonprod_envs) : "promotions/${pair[0]}/${pair[1]}/" => { kind = "marker", repo = pair[0] } },
    { "promotions/kc-control-plane/image/" = { kind = "marker", repo = "kc-control-plane" } },
  )

  managed_folders = merge(
    { for f in local.reader_roots : f => { kind = "root", repo = "" } },
    { "terraform/state/dda-platform/bootstrap/" = { kind = "bootstrap", repo = "dda-platform" } },
    local.state_env_folders,
    local.state_tier_folders,
    local.output_folders,
    local.marker_folders,
  )

  folder_grants = merge(
    # State: apply account objectAdmin, plan account objectViewer.
    { for f, v in merge(local.state_env_folders, local.state_tier_folders) : "${f}|apply" => { folder = f, role = "roles/storage.objectAdmin", member = "serviceAccount:${local.apply_account[v.repo]}" } },
    { for f, v in merge(local.state_env_folders, local.state_tier_folders) : "${f}|plan" => { folder = f, role = "roles/storage.objectViewer", member = "serviceAccount:${local.plan_account[v.repo]}" } },
    # Outputs: apply account objectAdmin on its own folder.
    { for f, v in local.output_folders : "${f}|apply" => { folder = f, role = "roles/storage.objectAdmin", member = "serviceAccount:${local.apply_account[v.repo]}" } },
    # Markers: objectCreator, so a marker cannot be overwritten.
    { for f, v in local.marker_folders : "${f}|apply" => { folder = f, role = "roles/storage.objectCreator", member = "serviceAccount:${local.apply_account[v.repo]}" } },
    {
      # Every apply and plan account reads outputs/ and bootstrap/.
      "outputs/|apply"   = { folder = "outputs/", role = "roles/storage.objectViewer", member = "serviceAccount:${local.deployer_email}" }
      "outputs/|plan"    = { folder = "outputs/", role = "roles/storage.objectViewer", member = "serviceAccount:${local.deployer_plan_email}" }
      "bootstrap/|apply" = { folder = "bootstrap/", role = "roles/storage.objectViewer", member = "serviceAccount:${local.deployer_email}" }
      "bootstrap/|plan"  = { folder = "bootstrap/", role = "roles/storage.objectViewer", member = "serviceAccount:${local.deployer_plan_email}" }
      # Every apply account reads markers and accepted ranges.
      "promotions/|apply"     = { folder = "promotions/", role = "roles/storage.objectViewer", member = "serviceAccount:${local.deployer_email}" }
      "gate/accepted/|apply"  = { folder = "gate/accepted/", role = "roles/storage.objectViewer", member = "serviceAccount:${local.deployer_email}" }
      "gate/accepted/|writer" = { folder = "gate/accepted/", role = "roles/storage.objectCreator", member = "serviceAccount:${local.deployer_email}" }
      # Bootstrap state: the administrators' group only.
      "terraform/state/dda-platform/bootstrap/|admins" = { folder = "terraform/state/dda-platform/bootstrap/", role = "roles/storage.objectAdmin", member = "group:${local.group["dda-bootstrap-admins"]}" }
    },
  )
}

resource "google_storage_managed_folder" "folder" {
  for_each = local.managed_folders

  bucket        = google_storage_bucket.tfstate.name
  name          = each.key
  force_destroy = false
}

resource "google_storage_managed_folder_iam_member" "grant" {
  for_each = local.folder_grants

  bucket         = google_storage_bucket.tfstate.name
  managed_folder = google_storage_managed_folder.folder[each.value.folder].name
  role           = each.value.role
  member         = each.value.member
}
