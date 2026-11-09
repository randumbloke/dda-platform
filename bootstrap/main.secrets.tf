/**
 Secrets, created with no version (§6.6.1). A bootstrap administrator adds each token as a
 version after stage 1 (§6.6.2 step 2). Expiry is tracked by the label expire_time, never by
 the secret's own expiry field, which would delete the secret (§6.6.3).
 */

locals {
  secrets = {
    # Cloud Build host connection token: classic, scopes repo + read:user in user mode (§6.4.1).
    "github-connection-token" = {
      description = "Cloud Build 2nd-gen host connection token (classic; repo, read:user)."
      accessors   = { cloudbuild_agent = "serviceAccount:${local.cloudbuild_agent}" }
    }
    # dda-gate-bot: classic token with no scopes in user mode (§6.6.3; VERIFY IN BUILD (VA-103)).
    "merge-gate-token" = {
      description = "dda-gate-bot read-only GitHub token for the merge gate."
      accessors   = { deployer = "serviceAccount:${local.deployer_email}" }
    }
  }

  secret_accessors = merge([
    for s, v in local.secrets : { for k, m in v.accessors : "${s}|${k}" => { secret = s, member = m } }
  ]...)
}

resource "google_secret_manager_secret" "secret" {
  for_each = local.secrets

  project   = local.cicd
  secret_id = each.key

  replication {
    user_managed {
      dynamic "replicas" {
        for_each = var.regions
        content {
          location = replicas.value
        }
      }
    }
  }

  labels = merge(
    { dda-domain = "shared" },
    contains(keys(var.token_expiry_dates), each.key) ? { expire_time = var.token_expiry_dates[each.key] } : {},
  )

  annotations = {
    description = each.value.description
  }

  depends_on = [google_project_service.cicd]
}

resource "google_secret_manager_secret_iam_member" "accessor" {
  for_each = local.secret_accessors

  project   = local.cicd
  secret_id = google_secret_manager_secret.secret[each.value.secret].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = each.value.member

  depends_on = [google_project_service_identity.cloudbuild]
}

# The scan generator token secret lives in the production hub (scangen-prod, §2.4.1). Phase 1
# has no production hub, so it is declared behind count = 0 until hub_project_ids has "prod".
resource "google_secret_manager_secret" "scangen_token" {
  count = contains(keys(var.hub_project_ids), "prod") ? 1 : 0

  project   = var.hub_project_ids["prod"]
  secret_id = "scangen-github-token"

  replication {
    user_managed {
      replicas {
        location = local.home_region
      }
    }
  }

  labels = merge(
    { dda-domain = "shared" },
    contains(keys(var.token_expiry_dates), "scangen-github-token") ? { expire_time = var.token_expiry_dates["scangen-github-token"] } : {},
  )
}
