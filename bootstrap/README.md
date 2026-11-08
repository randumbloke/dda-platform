# bootstrap

The human-applied stack of the Decentralised Data Architecture (DDA) reference deployment
(design §6.6). It creates what the pipelines need before they can run, and the controls that
constrain them once they do. No trigger applies it: the `dda-platform-apply` trigger ignores
`bootstrap/**`, and only a bootstrap administrator can change a trigger.

Phase 1 values (change `mvp-phase-1-build`): one tier (`nonprod`), one environment (`dev`),
supplied projects (`create_projects = false`), `manage_org_policies = false` (OD-1),
`github_owner_type = "user"` (`randumbloke`), public repositories with rulesets, and
`single_deployer = true` (every trigger applies as `tf-deployer` and plans as
`tf-deployer-plan`).

## Layout

```text
bootstrap/
  backend.tf  state.config  bootstrap.tfvars  providers.tf  variables.tf  outputs.tf
  bootstrap.auto.tfvars.example   # copy to bootstrap.auto.tfvars (git-ignored): org, billing, customer, people
  main.estate.tf       # locals, ordered stack lists (§6.13.1), guards, bootstrap/estate.json
  main.services.tf     # CI/CD APIs (§2.2.1), Cloud Build service agent
  main.org.tf          # organisation custom roles (§1.5.2, §2.3.1, §2.4.7); org policies at count = 0 (OD-1)
  main.audit.tf        # admin-activity sink (CI/CD project), log bucket, alert (§6.15.4)
  main.state.tf        # tfstate-pltfrm-ngnrng, managed folders, one writer per folder (§6.8, §6.7.2)
  main.registry.tf     # Artifact Registry dda-ci, dda-control-plane (§6.10), dda-pipelines (CD-12)
  main.identities.tf   # tf-deployer, tf-deployer-plan and their grants (§2.4.4, §6.7.2)
  main.secrets.tf      # connection token and merge gate token secrets, no versions (§6.6.1)
  main.github.tf       # repositories (dda-platform imported), collaborators, rulesets, group memberships
  main.connection.tf   # stage 2: Cloud Build host connection and linked repositories (§6.4.1)
  main.triggers.tf     # stage 2: triggers with inline builds (§6.4.2, §6.4.3, §6.5)
  main.markers.tf      # stage 2: first promotion markers, bootstrap/identities.json
  templates/           # bash run by the inline build steps (rendered here, never read from a repository)
  tests/               # terraform test with mocked providers (offline)
  merge-gate/          # merge gate code, golden-fixture tests, image build (§6.5)
  runner/              # Terraform runner image and its build (§6.4.2)
  owner/               # owner tasks 2.1-2.6: read-only inventory and IAM review, dry-run setup scripts
```

### Stages

One variable, `stage`, splits the two stages of §6.6.1. Stage 2 contains every stage 1
resource plus the connection, linked repositories, triggers, first markers and
`identities.json`, so a stage 2 apply never removes stage 1 resources.

| Stage | Set | Creates |
|---|---|---|
| 1 | `stage = 1` (default) | Custom roles; admin-activity sink, bucket and alert; state bucket and managed folders; `bootstrap/estate.json`; `dda-ci`, `dda-control-plane`; `tf-deployer`, `tf-deployer-plan` and grants; secrets (no versions) and accessor grants; the five GitHub repositories, collaborators and rulesets; Google group memberships |
| 2 | `stage = 2`, `merge_gate_image_digest`, `runner_image_digest`, `github_app_installation_id` | Host connection and linked repositories; 14 triggers (plan and apply for `dda-platform`, `cdmc-governance`, `dda-customer`, `dda-accounts`; `kc-control-plane-image`; a gate override per repository); first markers; `bootstrap/identities.json` |

Phase 1 declares `dev` only, so there are no `-plan-prod` or `-promote-*` triggers and no
promotion topics (§6.9).

Apply build order per repository (§6.13.1):

| Repository | Steps |
|---|---|
| `dda-platform` | merge gate, `tiers/nonprod`, `envs/dev`, promote `dev` |
| `cdmc-governance` | merge gate, `tiers/nonprod`, `envs/dev`, promote `dev` |
| `dda-customer`, `dda-accounts` | merge gate, `envs/dev/core`, `envs/dev/contract`, promote `dev` |
| `kc-control-plane` (image) | merge gate, docker build and push, publish `outputs/kc-control-plane/images.json`, image marker |

Each stack step runs `init`, `plan` and `apply`, and retries `plan` and `apply` once on failure
(P6-27). A failure stops the build before any later stack and before the marker.

## Checks

```bash
cd bootstrap
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
terraform test                       # mocked providers: stage 1, stage 2, stage 2 guard

cd merge-gate
uv sync
uv run pytest                        # golden fixtures, no network
uv run ruff check .

bash runner/check-terraform-version.sh 1.16.3   # on a workstation with Terraform 1.16.3
```

## Runbook (human apply)

Who: a bootstrap administrator, a member of `dda-bootstrap-admins@mikegyoung.joonix.net` who is
also the owner of the GitHub account `randumbloke` (§6.6). For phase 1 that is one person,
`mikegyoung@google.com` (OD-2; a residual risk, below §6.15.4's two or three).

### 0. Before the first apply (owner, once; change tasks 2.3, 2.5, 2.6)

The scripts in [`owner/`](owner/README.md) do steps 1 to 3 idempotently, with `--dry-run` by
default; the commands below show what they run.

1. Create the group and add the administrator. The group must allow members outside the
   organisation (Admin console, group settings), because the member is a `google.com` account:

   ```bash
   gcloud identity groups create dda-bootstrap-admins@mikegyoung.joonix.net \
     --organization=mikegyoung.joonix.net --display-name="DDA bootstrap admins"
   gcloud identity groups memberships add \
     --group-email=dda-bootstrap-admins@mikegyoung.joonix.net --member-email=mikegyoung@google.com
   ```

2. Grant the §6.15.4 roles to the group, never to the user. A stack cannot grant the roles it
   needs to apply itself, so these are outside Terraform. `VERIFY IN BUILD (VA-99)`: each role.

   ```bash
   G=group:dda-bootstrap-admins@mikegyoung.joonix.net
   ORG=1059663003036
   for r in resourcemanager.folderAdmin resourcemanager.projectCreator iam.securityAdmin \
            iam.organizationRoleAdmin orgpolicy.policyAdmin logging.configWriter; do
     gcloud organizations add-iam-policy-binding $ORG --member=$G --role=roles/$r --condition=None
   done
   gcloud billing accounts add-iam-policy-binding "$BILLING_ACCOUNT" --member=$G --role=roles/billing.admin
   for r in serviceusage.serviceUsageAdmin storage.admin artifactregistry.admin iam.serviceAccountAdmin \
            iam.serviceAccountUser secretmanager.admin cloudbuild.connectionAdmin cloudbuild.builds.editor \
            pubsub.admin logging.admin monitoring.editor; do
     gcloud projects add-iam-policy-binding pltfrm-ngnrng --member=$G --role=roles/$r --condition=None
   done
   for p in kcdda-dgov-hub-nonprod kcdda-core-dwh-dev kcdda-customer-analytics-dev kcdda-accounts-analytics-dev; do
     gcloud projects add-iam-policy-binding $p --member=$G --role=roles/iam.serviceAccountAdmin --condition=None
   done
   ```

   The administrator also needs Cloud Identity Groups Admin (a Google Workspace or Cloud
   Identity administrator assigns it) for the group memberships in `main.github.tf`.

3. Create the other Cloud Identity groups (§2.4.6): `dda-platform-engineers`,
   `dda-release-approvers`, `dda-governance-admins`, `dda-governance-engineers`,
   `dda-customer-producers`, `dda-accounts-producers` (and the domain and product groups the
   other repositories use). Bootstrap sets their membership; it does not create them.
4. Create the GitHub machine user `dda-gate-bot` with a classic token with no scopes, and the
   Cloud Build connection token (classic; `repo`, `read:user`). Keep both locally until step 3
   below. Install the Cloud Build GitHub App on `randumbloke` and note its installation ID.
5. If change task 2.5 created `tf-deployer` and `tf-deployer-plan` by hand, set
   `manage_deployer_service_accounts = false` (or import them).

### 1. Credentials

```bash
gcloud auth login mikegyoung@google.com
gcloud auth application-default login
gcloud auth application-default set-quota-project pltfrm-ngnrng
export GITHUB_TOKEN=...   # the account owner's own token: repo, admin:org not needed in user mode
cp bootstrap.auto.tfvars.example bootstrap.auto.tfvars   # fill in customer ID, billing, people
```

### 2. Stage 1, first apply (local state, then migrate)

The state bucket does not exist before the first apply, so the first run uses local state:

```bash
cd bootstrap
cat > backend_override.tf <<'EOF'
terraform {
  backend "local" {}
}
EOF
terraform init
# Rulesets block the first push of the local repositories, so the very first apply leaves them off.
terraform plan  -var-file=bootstrap.tfvars -var github_rulesets_enabled=false -out=tfplan
terraform apply tfplan
rm backend_override.tf
terraform init -migrate-state -backend-config=state.config
gcloud storage cp bootstrap.auto.tfvars gs://tfstate-pltfrm-ngnrng/terraform/state/dda-platform/bootstrap/
```

Then push each local repository (P6-38): `git remote add origin https://github.com/randumbloke/<repo>.git && git push -u origin main`
for `cdmc-governance`, `kc-control-plane`, `dda-customer`, `dda-accounts` (and `dda-platform`).
In `user` mode each collaborator, including `dda-gate-bot` and `dda-scangen-bot`, gets an
invitation and must accept it before it has access. Re-apply stage 1 with rulesets on:

```bash
terraform plan -var-file=bootstrap.tfvars -out=tfplan && terraform apply tfplan
```

### 3. Tokens and images (§6.6.2 step 2)

```bash
printf '%s' "$GATE_BOT_TOKEN"   | gcloud secrets versions add merge-gate-token        --project=pltfrm-ngnrng --data-file=-
printf '%s' "$CONNECTION_TOKEN" | gcloud secrets versions add github-connection-token --project=pltfrm-ngnrng --data-file=-
SHA=$(git rev-parse HEAD)   # the reviewed dda-platform commit, clean checkout
gcloud builds submit merge-gate --project=pltfrm-ngnrng --region=australia-southeast1 \
  --config=merge-gate/cloudbuild.yaml --substitutions=_TAG=$SHA
gcloud builds submit runner --project=pltfrm-ngnrng --region=australia-southeast1 \
  --config=runner/cloudbuild.yaml --substitutions=_TAG=$SHA
```

Each build prints the image digest in its last step. Set the expiry label at the same time,
through `token_expiry_dates` in `bootstrap.auto.tfvars` (§6.6.3).

### 4. Stage 2

```bash
terraform plan -var-file=bootstrap.tfvars -var stage=2 \
  -var merge_gate_image_digest=sha256:... -var runner_image_digest=sha256:... \
  -var github_app_installation_id=NNNNNNNN -out=tfplan
terraform apply tfplan
```

Keep `stage = 2` and the digests in `bootstrap.tfvars` after the first stage 2 apply, so later
applies do not remove the triggers. Changing the merge gate is a `dda-platform` pull request,
a new image, and a stage 2 apply with the new digest (§6.6.2).

### 5. Later

- Domain pipeline images (P6-39) go to `dda-pipelines`. Submit the domain repository's
  `pipelines/cloudbuild.yaml` as `tf-deployer`, the repository's only writer:
  `gcloud builds submit --config pipelines/cloudbuild.yaml --service-account=projects/pltfrm-ngnrng/serviceAccounts/tf-deployer@pltfrm-ngnrng.iam.gserviceaccount.com ...`.
  Tags are immutable, so deploy by digest, not `:latest`.

- After the first `dda-platform` merge build, re-apply (§6.6.2 step 5) for hub-dependent items.
- Domain onboarding (§6.6.5): add the domain to `domains` and its producers group to
  `approval_groups`, then apply.
- Unreviewed commit on `main` (§6.5.3): start `<repo>-gate-override` with `_RANGE=<first>..<last>`,
  `_REVERT_PR`, `_REASON`; a platform engineer who did not push the commit approves it.

## Contract and design differences

- Terraform `1.16.3` and `required_version = "~> 1.16"`, `google`/`google-beta` exactly `8.10.0`
  (contracts), where design §6.4.2 and §6.11 say 1.17.1, `>= 1.17` and `~> 8.10`.
- The host connection and linked repositories are created at stage 2, not stage 1 (§6.6.1): a
  connection cannot be created before its token secret has a version (§6.6.2 step 2).
- Each stack runs `init`, `plan` and `apply` (design steps 1 to 3) in one build step, so the
  retry of P6-27 can re-run `plan` and `apply` in place.
- `tf-deployer` also gets `roles/resourcemanager.projectIamAdmin` on the estate projects (the
  project-level agent grants of §6.15.1 need it) and, on the core data and analytics projects,
  `roles/run.admin`, `roles/cloudscheduler.admin` and `roles/iam.serviceAccountUser` for the
  P6-39 Cloud Run jobs (ingest job in the core data project, build job in the analytics project). Neither is in the §2.4.4 table.
- The image build records digests in `outputs/kc-control-plane/images.json` and the build log,
  not in the build's `results.images`.
- `identities.json` carries `generated_by` instead of `generated_at`, so that re-applies do not
  rewrite it.
- Change task 2.5 has the owner create `tf-deployer` and `tf-deployer-plan`; §6.6.1 has stage 1
  create them. `manage_deployer_service_accounts` supports both.
- `tf-deployer` and `tf-deployer-plan` get `roles/storage.bucketViewer` on the state bucket
  (bucket metadata for the gcs backend and `gcloud storage`); §6.8 lists managed-folder grants
  only.
- Artifact Registry `dda-pipelines` (domain pipeline images, contracts CD-12) is not in §6.10.
- `cicd_project_id` must be set (the contracts allow `null`, the hub-as-CI/CD layout); phase 1
  uses the dedicated `pltfrm-ngnrng`.
- Only `single_deployer = true`, `create_projects = false` and `github_owner_type = "user"` are
  drafted; guards fail the plan otherwise.

## Not drafted here

Hub workload service accounts (`evaluator-dev`) and the domains' ingest and analytics service
accounts: in phase 1 the owner creates them by hand (change task 2.5, §6.17 asks table; see
`owner/`), so they stay out of bootstrap. Their grants (§2.4.1); `evaluator-prod` grants;
teams for `organization` mode; promotion topics and triggers (no `test`, `uat` or `prod`).

## VERIFY IN BUILD markers

| ID | Where | What |
|---|---|---|
| VA-48 | `main.org.tf` | `dataDomains.lookupEntry` / `modifyEntry` in `ddaMetadataSteward` |
| VA-49 | `main.org.tf` | `ddaDomainDelegate` is enough to create a binding |
| VA-50 | `main.org.tf` | `ddaPolicyTagApplier` permissions (role off in phase 1) |
| VA-52 | `main.org.tf` | `run.allowedIngress = internal` (count 0 in phase 1) |
| VA-76 | `main.org.tf` | `ddaAspectWriter` without `entryGroups.use<Aspect>` |
| VA-84, VA-102 | `main.github.tf` | rulesets on public repositories of a personal account |
| VA-85 | `main.identities.tf` | plan account with `viewer` and `securityReviewer` can plan |
| VA-86, VA-88, VA-95, VA-97 | `main.triggers.tf` | inline 2nd-gen triggers: source fetch, PR report, SA and logging, comment control |
| VA-87 | `main.org.tf` | Beta binding permissions in `ddaDomainBinder` |
| VA-89, VA-103 | `merge-gate/src/merge_gate/github.py`, `main.secrets.tf` | gate endpoints with a no-scope classic token |
| VA-92 | `merge-gate/src/merge_gate/cli.py` | Pub/Sub publish queues the promotion build |
| VA-99 | `main.identities.tf`, `main.org.tf`, this README | role and permission names |
| VA-101 | `main.services.tf` | Cloud Build agent email when identities are not generated |
| estate | `main.registry.tf` | `dda-pipelines` repository, not in §6.10 (CD-12) |
| estate | `bootstrap.auto.tfvars.example`, `main.audit.tf`, `main.triggers.tf`, `runner/`, `merge-gate/` | customer ID, billing account, base image digests, sink writer grant, Dockerfile path |
