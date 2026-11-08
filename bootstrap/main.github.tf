/**
 GitHub configuration as code (§6.1, §6.5.4, §6.6, §6.6.4).

 dda-platform was created by hand before bootstrap and is adopted by the import block; the other
 repositories are created here. Visibility from repository_visibility; rebase merging off (the
 merge gate supports merge commits and squash merges); head branches deleted on merge.
 `user` mode (P6-34): repository collaborators replace teams.
 */

import {
  to = github_repository.repo["dda-platform"]
  id = "dda-platform"
}

locals {
  repo_descriptions = merge(
    {
      "dda-platform"     = "DDA platform: human-applied bootstrap, shared modules and platform stacks."
      "cdmc-governance"  = "DDA governance hub configuration: domains, aspect types, glossary, control plane services."
      "kc-control-plane" = "DDA control plane code (evaluator and later components), tests, images and JSON Schemas."
    },
    { for r, d in local.domain_repositories : r => "DDA ${d} domain: datasets, products, data quality and pipelines." },
  )
}

resource "github_repository" "repo" {
  for_each = toset(local.repositories)

  name        = each.value
  description = local.repo_descriptions[each.value]
  visibility  = var.repository_visibility

  has_issues   = true
  has_projects = false
  has_wiki     = false

  allow_merge_commit     = true
  allow_squash_merge     = true
  allow_rebase_merge     = false
  allow_auto_merge       = false
  delete_branch_on_merge = true

  archive_on_destroy = true

  # The local repositories are pushed after stage 1 (P6-38), so no initial commit here.
  auto_init = false

  lifecycle {
    # Adopted repository: keep anything set before adoption that this stack does not manage.
    ignore_changes = [auto_init, topics, homepage_url]
  }
}

# --------------------------------------------------------------------------------------------
# Approval groups and collaborators
# --------------------------------------------------------------------------------------------

locals {
  # Repositories each group needs. dda-<d>-producers -> dda-<d> (§6.6.4).
  group_repos = merge(
    var.group_repositories,
    { for r, d in local.domain_repositories : "dda-${d}-producers" => [r] },
  )

  # Machine users (§6.6.3): dda-gate-bot reads every repository; dda-scangen-bot writes domain
  # repositories only. In user mode both are collaborators (classic tokens, VA-103).
  machine_collaborators = merge(
    { for r in local.repositories : "${r}|${var.machine_users.gate_bot}" => { repo = r, login = var.machine_users.gate_bot } },
    { for r in keys(local.domain_repositories) : "${r}|${var.machine_users.scangen_bot}" => { repo = r, login = var.machine_users.scangen_bot } },
  )

  person_collaborators = merge([
    for g, members in var.approval_groups : {
      for pair in setproduct(lookup(local.group_repos, g, []), [for m in members : m.github_login]) :
      "${pair[0]}|${pair[1]}" => { repo = pair[0], login = pair[1] }
      # The account owner already administers every repository and cannot be a collaborator.
      if lower(pair[1]) != lower(var.github_owner)
    }
  ]...)

  collaborators = var.github_owner_type == "user" ? merge(local.person_collaborators, local.machine_collaborators) : {}
}

resource "github_repository_collaborator" "collaborator" {
  for_each = local.collaborators

  repository = github_repository.repo[each.value.repo].name
  username   = each.value.login
  # Personal repositories have one collaborator level (write); the value is ignored there.
  permission = "push"
}

# Teams (organization mode) are not drafted in phase 1 (github_owner_type = user). They would be
# github_team, github_team_repository and github_team_membership from the same lists.
resource "terraform_data" "organization_mode_guard" {
  lifecycle {
    precondition {
      condition     = var.github_owner_type == "user"
      error_message = "organization mode (teams) is not drafted in this phase; use github_owner_type = user."
    }
  }
}

# --------------------------------------------------------------------------------------------
# Rulesets (option 2, §6.5.4). VERIFY IN BUILD (VA-102): rulesets on public repositories of a
# personal account on GitHub Free. VERIFY IN BUILD (VA-84): ruleset features as documented.
# --------------------------------------------------------------------------------------------

resource "github_repository_ruleset" "main" {
  for_each = var.github_rulesets_enabled ? toset(local.repositories) : toset([])

  name        = "main-protection"
  repository  = github_repository.repo[each.value].name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["refs/heads/main"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    # Zero approvals so self-merge works (P6-6).
    pull_request {
      required_approving_review_count   = 0
      dismiss_stale_reviews_on_push     = false
      require_code_owner_review         = false
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }

    required_status_checks {
      strict_required_status_checks_policy = true

      required_check {
        context        = "ci-checks"
        integration_id = 15368 # GitHub Actions app
      }
    }
  }
}

# --------------------------------------------------------------------------------------------
# Google group membership from the same lists (§6.6.4, §6.15.1). The groups must exist
# (§2.4.6; change task 2.5). dda-bootstrap-admins is managed by hand (OD-2), not here.
# --------------------------------------------------------------------------------------------

locals {
  group_members = var.manage_group_memberships ? merge([
    for g, members in var.approval_groups : {
      for m in members : "${g}|${lower(m.google_account)}" => { group = g, account = lower(m.google_account) }
    } if g != "dda-bootstrap-admins"
  ]...) : {}
}

data "google_cloud_identity_group_lookup" "group" {
  for_each = var.manage_group_memberships ? { for g in keys(var.approval_groups) : g => g if g != "dda-bootstrap-admins" } : {}

  group_key {
    id = "${each.key}@${var.group_domain}"
  }
}

resource "google_cloud_identity_group_membership" "member" {
  for_each = local.group_members

  group = data.google_cloud_identity_group_lookup.group[each.value.group].name

  preferred_member_key {
    id = each.value.account
  }

  roles {
    name = "MEMBER"
  }

  # An account outside the organisation (for example the owner's google.com account) needs the
  # group to allow outside members (OD-2).
}
