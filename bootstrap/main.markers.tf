/**
 Stage 2: first promotion markers and bootstrap/identities.json (§6.6.1, §6.6.2 step 3, §6.6.4).

 Each first marker records the current main commit of a repository, so merge gate check 2 has a
 starting point. Later markers are written by the builds (objectCreator, never overwritten);
 this stack ignores later changes to its own first marker so a re-apply never rewrites it.
 The repositories must have a main branch (pushed after stage 1, P6-38) before stage 2.
 */

data "github_branch" "main" {
  for_each = local.stage2 ? toset(local.repositories) : toset([])

  repository = github_repository.repo[each.value].name
  branch     = "main"
}

locals {
  first_markers = local.stage2 ? merge(
    { for pair in setproduct(local.terraform_repositories, local.nonprod_envs) : "${pair[0]}/${pair[1]}" => { repo = pair[0], env = pair[1] } },
    { "kc-control-plane/image" = { repo = "kc-control-plane", env = "image" } },
  ) : {}
}

resource "google_storage_bucket_object" "first_marker" {
  for_each = local.first_markers

  bucket       = google_storage_bucket.tfstate.name
  name         = "promotions/${each.value.repo}/${each.value.env}/${data.github_branch.main[each.value.repo].sha}"
  content_type = "application/json"
  content = jsonencode({
    repo     = each.value.repo
    env      = each.value.env
    sha      = data.github_branch.main[each.value.repo].sha
    build_id = "bootstrap-stage-2"
    # Marker time comes from the object's creation time; the content stays deterministic.
    writer = "bootstrap"
  })

  lifecycle {
    ignore_changes = [name, content]
  }

  depends_on = [google_storage_managed_folder.folder]
}

locals {
  identities = {
    groups = {
      for g, members in var.approval_groups : g => [
        for m in members : { github_login = m.github_login, google_account = lower(m.google_account) }
      ]
    }
    machine_users = [var.machine_users.scangen_bot, var.machine_users.gate_bot]
  }
}

resource "google_storage_bucket_object" "identities" {
  count = local.stage2 ? 1 : 0

  bucket       = google_storage_bucket.tfstate.name
  name         = "bootstrap/identities.json"
  content_type = "application/json"
  content      = jsonencode(merge({ generated_by = "bootstrap" }, local.identities))

  depends_on = [google_storage_managed_folder.folder]
}
