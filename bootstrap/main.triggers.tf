/**
 Stage 2: triggers with inline builds (§6.4.2, §6.4.3, §6.5, P6-15).

 No trigger sets `filename` or `git_file_source`: every build is declared here, so a
 cloudbuild.yaml added to a repository is never read. Every apply and image build starts with
 the merge gate (step 0) and runs the repository's ordered stack list (§6.13.1). Phase 1
 declares dev only, so there are no -plan-prod or -promote-* triggers (§6.9).

 VERIFY IN BUILD (VA-88): a 2nd-gen trigger with an inline build and no filename fetches the
 pushed commit as the build's source.
 VERIFY IN BUILD (VA-86): the result is posted back to the pull request / commit.
 VERIFY IN BUILD (VA-95): builds run as the user-specified service account with
 CLOUD_LOGGING_ONLY.
 VERIFY IN BUILD (VA-97): comment_control on pull request triggers.
 */

locals {
  ar_host       = "${local.home_region}-docker.pkg.dev"
  gate_image    = local.stage2 && var.merge_gate_image_digest != null ? "${local.ar_host}/${local.cicd}/dda-ci/merge-gate@${var.merge_gate_image_digest}" : ""
  runner_image  = local.stage2 && var.runner_image_digest != null ? "${local.ar_host}/${local.cicd}/dda-ci/terraform-runner@${var.runner_image_digest}" : ""
  cp_registry   = "${local.ar_host}/${local.cicd}/dda-control-plane"
  ignored_files = ["**/*.md", ".github/workflows/**"]

  # VERIFY IN BUILD (estate): pin the docker builder by digest once read from the registry.
  docker_builder = "gcr.io/cloud-builders/docker"

  gate_env = [
    "GITHUB_OWNER=${var.github_owner}",
    "GITHUB_OWNER_TYPE=${var.github_owner_type}",
    "STATE_BUCKET=${google_storage_bucket.tfstate.name}",
    "GATE_PROJECT=${local.cicd}",
    "GATE_REGION=${local.home_region}",
    "GATE_CI_WAIT_MINUTES=${var.gate_ci_wait_minutes}",
    "BUILD_ID=$BUILD_ID",
  ]

  gate_secret_version = "${google_secret_manager_secret.secret["merge-gate-token"].id}/versions/latest"

  # Steps of the generic apply build per repository: gate, stacks in order, promote per env.
  apply_steps = {
    for r in local.terraform_repositories : r => concat(
      [{
        id         = "0-merge-gate"
        name       = local.gate_image
        entrypoint = "python"
        args       = ["-m", "merge_gate", "check", "--mode", "apply", "--repo", r, "--sha", "$COMMIT_SHA", "--env", local.nonprod_envs[0]]
        env        = local.gate_env
        secret_env = ["GATE_TOKEN"]
      }],
      flatten([
        for e in concat([""], local.nonprod_envs) : concat(
          [
            for i, s in local.apply_stacks[r] : {
              id         = "apply-${replace(s.dir, "/", "-")}"
              name       = local.runner_image
              entrypoint = "bash"
              args = ["-c", templatefile("${path.module}/templates/stack_apply.sh.tftpl", {
                dir       = s.dir
                tfvars    = s.tfvars
                env_label = s.env == "" ? "shared scope" : s.env
              })]
              env        = []
              secret_env = []
            } if s.env == e
          ],
          e == "" ? [] : [{
            id         = "promote-${e}"
            name       = local.gate_image
            entrypoint = "python"
            # Phase 1 has no test environment, so no next topic is queued (§6.9).
            args = concat(
              ["-m", "merge_gate", "promote", "--repo", r, "--env", e, "--sha", "$COMMIT_SHA"],
              contains(local.prod_envs, "uat") && e == local.nonprod_envs[length(local.nonprod_envs) - 1] ? ["--next-topic", "projects/${local.cicd}/topics/promote-${r}-uat"] : [],
            )
            env        = local.gate_env
            secret_env = []
          }],
        )
      ]),
    )
  }

  plan_steps = {
    for r in local.terraform_repositories : r => [
      for s in local.plan_stacks[r] : {
        id         = "plan-${replace(s.dir, "/", "-")}"
        name       = local.runner_image
        entrypoint = "bash"
        args = ["-c", templatefile("${path.module}/templates/stack_plan.sh.tftpl", {
          dir       = s.dir
          tfvars    = s.tfvars
          env_label = s.env == "" ? "shared scope" : s.env
        })]
        env        = []
        secret_env = []
      }
    ]
  }

  image_steps = [
    {
      id         = "0-merge-gate"
      name       = local.gate_image
      entrypoint = "python"
      args       = ["-m", "merge_gate", "check", "--mode", "image", "--repo", "kc-control-plane", "--sha", "$COMMIT_SHA", "--env", "image"]
      env        = local.gate_env
      secret_env = ["GATE_TOKEN"]
    },
    {
      id         = "build-push"
      name       = local.docker_builder
      entrypoint = "bash"
      args = ["-c", templatefile("${path.module}/templates/image_build.sh.tftpl", {
        registry = local.cp_registry
        images   = var.control_plane_images
      })]
      env        = []
      secret_env = []
    },
    {
      id         = "publish"
      name       = local.runner_image
      entrypoint = "bash"
      args = ["-c", templatefile("${path.module}/templates/image_publish.sh.tftpl", {
        bucket = google_storage_bucket.tfstate.name
      })]
      env        = []
      secret_env = []
    },
    {
      id         = "promote-image"
      name       = local.gate_image
      entrypoint = "python"
      args       = ["-m", "merge_gate", "promote", "--repo", "kc-control-plane", "--env", "image", "--sha", "$COMMIT_SHA"]
      env        = local.gate_env
      secret_env = []
    },
  ]

  override_steps = {
    for r in local.repositories : r => [{
      id         = "0-gate-override"
      name       = local.gate_image
      entrypoint = "python"
      args       = ["-m", "merge_gate", "override", "--repo", r, "--range", "$_RANGE", "--revert-pr", "$_REVERT_PR", "--reason", "$_REASON"]
      env        = local.gate_env
      secret_env = ["GATE_TOKEN"]
    }]
  }

  # Every trigger: name => definition. service_account is required and validated below.
  triggers = local.stage2 ? merge(
    { for r in local.terraform_repositories : "${r}-plan" => {
      repo        = r, kind = "pull_request", steps = local.plan_steps[r], sa = local.plan_account[r], approval = false, secrets = false
      description = "Plan ${r} for dev on pull request (§6.4.4)."
    } },
    { for r in local.terraform_repositories : "${r}-apply" => {
      repo        = r, kind = "push", steps = local.apply_steps[r], sa = local.apply_account[r], approval = false, secrets = true
      description = "Merge gate, then apply ${r}: ${join(", ", [for s in local.apply_stacks[r] : s.dir])} (§6.4.5)."
    } },
    { "kc-control-plane-image" = {
      repo        = "kc-control-plane", kind = "push", steps = local.image_steps, sa = local.apply_account["kc-control-plane"], approval = false, secrets = true
      description = "Merge gate, then build and push control plane images (§6.10)."
    } },
    { for r in local.repositories : "${r}-gate-override" => {
      repo        = r, kind = "manual", steps = local.override_steps[r], sa = local.apply_account[r], approval = true, secrets = true
      description = "Gate override for an unreviewed commit on main (§6.5.3)."
    } },
  ) : {}

  pipeline_accounts = toset([local.deployer_email, local.deployer_plan_email])
}

resource "terraform_data" "trigger_service_accounts" {
  for_each = local.triggers

  input = each.value.sa

  lifecycle {
    # §6.4.3: every trigger names a pipeline service account in the CI/CD project.
    precondition {
      condition     = each.value.sa != null && contains(local.pipeline_accounts, each.value.sa) && endswith(each.value.sa, "@${local.cicd}.iam.gserviceaccount.com")
      error_message = "Trigger ${each.key} must run as a pipeline service account in ${local.cicd}."
    }
  }
}

resource "google_cloudbuild_trigger" "trigger" {
  for_each = local.triggers

  project         = local.cicd
  location        = local.home_region
  name            = each.key
  description     = each.value.description
  service_account = "projects/${local.cicd}/serviceAccounts/${each.value.sa}"

  ignored_files = each.value.kind == "manual" ? null : (
    each.value.repo == "dda-platform" && each.value.kind == "push"
    ? concat(local.ignored_files, ["bootstrap/**"])
    : local.ignored_files
  )

  dynamic "repository_event_config" {
    for_each = each.value.kind == "manual" ? [] : [1]
    content {
      repository = google_cloudbuildv2_repository.repo[each.value.repo].id

      dynamic "push" {
        for_each = each.value.kind == "push" ? [1] : []
        content {
          branch = "^main$"
        }
      }

      dynamic "pull_request" {
        for_each = each.value.kind == "pull_request" ? [1] : []
        content {
          branch          = "^main$"
          comment_control = "COMMENTS_ENABLED_FOR_EXTERNAL_CONTRIBUTORS_ONLY"
        }
      }
    }
  }

  dynamic "source_to_build" {
    for_each = each.value.kind == "manual" ? [1] : []
    content {
      repository = google_cloudbuildv2_repository.repo[each.value.repo].id
      ref        = "refs/heads/main"
      repo_type  = "GITHUB"
    }
  }

  dynamic "approval_config" {
    for_each = each.value.approval ? [1] : []
    content {
      approval_required = true
    }
  }

  substitutions = each.value.kind == "manual" ? {
    _RANGE     = ""
    _REVERT_PR = ""
    _REASON    = ""
  } : null

  build {
    timeout = "7200s"

    dynamic "step" {
      for_each = each.value.steps
      content {
        id         = step.value.id
        name       = step.value.name
        entrypoint = step.value.entrypoint
        args       = step.value.args
        env        = step.value.env
        secret_env = step.value.secret_env
      }
    }

    dynamic "available_secrets" {
      for_each = each.value.secrets ? [1] : []
      content {
        secret_manager {
          env          = "GATE_TOKEN"
          version_name = local.gate_secret_version
        }
      }
    }

    options {
      logging = "CLOUD_LOGGING_ONLY"
    }
  }

  depends_on = [terraform_data.trigger_service_accounts]
}
