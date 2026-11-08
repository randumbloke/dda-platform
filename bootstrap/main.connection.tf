/**
 Stage 2: Cloud Build 2nd-gen host connection and linked repositories (§6.4.1).

 The design lists these in stage 1 (§6.6.1), but a host connection cannot be created until the
 connection token secret has a version, which a bootstrap administrator adds after stage 1
 (§6.6.2 step 2). They are therefore created at stage 2 (contract difference, reported).
 */

locals {
  stage2 = var.stage >= 2
}

resource "google_cloudbuildv2_connection" "github" {
  count = local.stage2 ? 1 : 0

  project  = local.cicd
  location = local.home_region
  name     = "github-${var.github_owner}"

  github_config {
    app_installation_id = var.github_app_installation_id
    authorizer_credential {
      oauth_token_secret_version = "${google_secret_manager_secret.secret["github-connection-token"].id}/versions/latest"
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.accessor]
}

resource "google_cloudbuildv2_repository" "repo" {
  for_each = local.stage2 ? toset(local.repositories) : toset([])

  project           = local.cicd
  location          = local.home_region
  name              = each.value
  parent_connection = google_cloudbuildv2_connection.github[0].name
  remote_uri        = "https://github.com/${var.github_owner}/${github_repository.repo[each.value].name}.git"
}
