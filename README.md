# dda-platform

Platform repository of the Decentralised Data Architecture (DDA) reference deployment on Google
Cloud: shared Terraform modules, the platform stacks (projects, APIs, service agents, event
plumbing, audit-log routing) and the human-applied bootstrap stack. It implements the technical
design `docs/design/dda_technical_design.md` in
[`randumbloke/cdmc_kc`](https://github.com/randumbloke/cdmc_kc) (sections 1.6, 2.2 to 2.5, 6.1 to
6.17), change `mvp-phase-1-build`, against the shared contracts in `deployment/contracts/` of that
repository.

This is the phase 1 draft (owner decision OD-3: code first, then deploy and check). Nothing here
has been applied yet. Every spot that depends on an unverified platform behaviour carries a
`VERIFY IN BUILD (VA-nn)` comment; the list is at the end of this file.

## Layout

```text
bootstrap/                 human-applied only (design section 6.6); owned and documented by bootstrap/README.md
modules/
  project_factory/         create or supplied mode; P1-7 label preconditions (sections 1.6, 2.2, 6.13.5)
  api_services/            section 2.2.1 API sets; enable (manage) or check and fail listing missing APIs (VA-100)
  service_identities/      Dataplex, SDP, Pub/Sub agents: generated (Beta) or computed (section 2.4.5; VA-93, VA-101)
  label_gen/               labels per role from envs/labels.json (section 1.6)
  id_gen/                  names and IDs (section 1.6; contracts section 2), including the scan ID hash rule
  data_domain_shim/
    domain/                data domain: create, update, IAM, policyMember read (sections 2.3, 2.3.2)
    binding/               ddaDomainDelegate grant, then binding (sections 2.3.1, 2.3.2)
tiers/nonprod/             the tier's hub project, its APIs and agents; publishes outputs/dda-platform/tiers/nonprod/outputs.json
envs/
  labels.json              label set per role (P1-7)
  dev/                     data projects, APIs, agents, agent grants, topics, feeds, queue, audit routing,
                           landing buckets, alerts; publishes outputs/dda-platform/dev/outputs.json
scripts/
  compare_roots.sh         root-module comparison across envs/ and tiers/ (section 6.3)
  policy_checks.sh         IAM ownership, dataset access, projectReaders, local execution, lock files, pins, workflows
  test_shim.sh             offline tests of the shim scripts (stub curl: 409 compare, 404 delete, polling, timeout, updateMask, etag)
  schemas/                 labels.json schema
.github/workflows/ci.yml   ci-checks (section 6.3)
.tflint.hcl                tflint with the Google ruleset
```

There is no `org/` stack: phase 1 has `create_projects = false`, so no folders (section 6.13.1).

Each root module has `backend.tf` (empty `gcs` block), `state.config`, `<env|tier>.tfvars`,
`providers.tf`, `variables.tf`, `outputs.tf`, `main.<concern>.tf` and a committed
`.terraform.lock.hcl` (linux_amd64 and darwin_arm64). Root modules of one stack differ between
environments or tiers only in `.tfvars` and `state.config`; CI enforces it.

## Values between stacks

Stacks read estate values from `gs://tfstate-pltfrm-ngnrng/bootstrap/estate.json` and other stacks'
values from `outputs/<repo>/.../outputs.json` with `google_storage_bucket_object_content`; a missing
file fails the plan (section 6.13.3). No `terraform_remote_state`.

| Stack | Reads | Writes (schema in `cdmc_kc/deployment/contracts/schemas/`) |
|---|---|---|
| `tiers/nonprod` | `bootstrap/estate.json` | `outputs/dda-platform/tiers/nonprod/outputs.json` (`outputs_platform_tier`) |
| `envs/dev` | `bootstrap/estate.json`, the tier outputs | `outputs/dda-platform/dev/outputs.json` (`outputs_platform_env`) |

## The data domain module (for other repositories)

Source: `git::https://github.com/randumbloke/dda-platform.git//modules/data_domain_shim/<domain|binding>?ref=main`
(section 6.13.4). Inputs and outputs follow the design section 2.3 tables exactly.

| Submodule | Inputs | Outputs |
|---|---|---|
| `domain` | `project`, `location`, `data_domain_id`, `parent_data_domain` (optional), `display_name`, `description` (optional), `contacts` (list of `{role, identity}`), `labels`, `iam_members` (map of role to members) | `name`, `policy_member` |
| `binding` | `domain_name`, `policy_member`, `bindings` (map of key to full resource name), `organization_id` (optional, not in the design table) | `binding_names` |

- `policy_member` is the string `policyMember.iamPolicyNamePrincipal` (`principal://...`);
  `policyMember` itself is an object. VA-12 confirms the form IAM accepts.
- Subdomain IDs are flat: `<domain>-<stage>`, for example `customer-dev-raw`, with
  `parent_data_domain` set to the parent's `name`.
- `iam_members` accepts only `organizations/<org>/roles/ddaMetadataSteward`,
  `roles/dataplex.dataDomainViewer`, `roles/dataplex.dataDomainEntryReader` and
  `organizations/<org>/roles/ddaDomainBinder`; the binder only for `tf-<business>-<tier>` of the
  same domain or `tf-deployer` (VA-48, VA-87).
- Binding keys: `ds-<dataset with _ as ->` or `dp-<product-id>`. Resources: BigQuery datasets and
  data products. The grant is a `google_bigquery_dataset_access` entry (datasets) or a
  `google_dataplex_data_product_iam_member` (products).
- The scripts need `bash`, `curl` and `jq` (the runner image `dda-ci/terraform-runner`), take the
  build account's token from the metadata server (falling back to `gcloud auth print-access-token`
  on a workstation), poll operations every 5 s for up to 10 minutes, treat 409 on create as
  compare-and-accept and 404 on delete as done. Destroy order: bindings, then grants, then
  subdomains, then domains.

## Running the checks

Requirements: Terraform 1.16.x, bash, jq, `uv` (for `uvx`). From the repository root:

```bash
terraform fmt -check -recursive
for d in tiers/nonprod envs/dev; do (cd $d && terraform init -backend=false -lockfile=readonly && terraform validate); done
for d in modules/*/ modules/data_domain_shim/*/; do (cd $d && terraform init -backend=false && terraform validate); done
# terraform test with mock providers (no credentials)
for d in modules/project_factory modules/api_services modules/data_domain_shim/domain modules/data_domain_shim/binding tiers/nonprod envs/dev; do (cd $d && terraform test); done
bash scripts/compare_roots.sh
bash scripts/policy_checks.sh
bash scripts/test_shim.sh
uvx --from check-jsonschema==0.33.0 check-jsonschema --schemafile scripts/schemas/labels.schema.json envs/labels.json
```

`ci-checks` (GitHub Actions) runs the same plus `tflint` (Google ruleset), a Trivy Terraform
misconfiguration scan (HIGH and above) and a `gitleaks` secret scan over the change's commits. It
holds no Google Cloud credential and pins actions by commit SHA.

## Deployment

Not by hand, except `bootstrap/`. After bootstrap stages 1 and 2, the Cloud Build push trigger on
`main` applies, as `tf-deployer` (`single_deployer = true`, section 6.7.2), `tiers/nonprod/` then
`envs/dev/` (section 6.13.1), each with
`terraform init -backend-config=state.config -lockfile=readonly` and
`terraform apply -var-file=<env|tier>.tfvars`. Pull requests get a read-only plan as
`tf-deployer-plan`. Apply order across repositories: `dda-platform` before `cdmc-governance`
before the domain repositories (section 6.14).

## Phase 1 scope

`dev` only, `create_projects = false`, `manage_project_services = true`,
`manage_service_identities = true`. The `components` flags in `envs/dev/dev.tfvars` are the phase 1
values of section 6.17: on are `kc-evaluator`, `findings` and `notifications` topics with
dead-letter topics, `feed-evaluator`, the `product-rollups` queue, landing buckets and dead-letter
alerts; off (declared behind `count`/`for_each`) are the classifier topics and feed,
`sdp-profiles`, `narratives`, the access-request and data-access sinks, and the `dda-audit` log
bucket with its linked dataset.

Service accounts (`evaluator-dev`, `<business>-ingest-dev` in the core data project,
`<business>-analytics-dev` in each analytics project) are created by the platform team, not here
(section 2.4); this stack references them and publishes their emails.

## `VERIFY IN BUILD` markers

| ID | Where | What |
|---|---|---|
| VA-09 | `envs/dev/main.feeds.tf` | Feed payload; aspect type and scope name forms; a feed naming `cdmc-classification` before the governance tier creates it |
| VA-12 | `data_domain_shim/domain` (outputs, postcondition), `binding` | `policyMember.iamPolicyNamePrincipal` is grantable like any principal |
| VA-17 | `data_domain_shim/domain/variables.tf` | Domain location (regional or global) |
| VA-48 | `data_domain_shim/domain/variables.tf` | No data role reaches bound resources through domain IAM |
| VA-49 | `data_domain_shim/binding` | `ddaDomainDelegate` suffices to create a binding |
| VA-58 | `envs/dev/main.projects.tf` | `roles/dlp.projectdriver` is the discovery role for the SDP agent |
| VA-59 | `envs/dev/main.feeds.tf` | Metadata feed location |
| VA-60 | `envs/dev/main.audit.tf` | Sink delivery to the linked dataset; access entry on a linked dataset |
| VA-62 | `domain_update.sh`, `domain_iam.sh` | PATCH of `contacts`/`labels` in place; `setIamPolicy` accepts the allowed roles |
| VA-85 | `data_domain_shim/domain/main.tf` | Plan accounts (`roles/viewer`) can `dataplex.dataDomains.get` |
| VA-87 | `data_domain_shim/domain/variables.tf` | A binder grant on one domain covers that domain and its subdomains only |
| VA-93 | `modules/service_identities` | `google_project_service_identity` creates the agents on supplied projects |
| VA-94 | `data_domain_shim/binding` | Dataset access entry with the custom role survives re-applies |
| VA-95 | `scripts/lib.sh` (shim) | Metadata-server token in Cloud Build |
| VA-96 | `scripts/lib.sh` (shim) | Operation polling, 5 s / 10 min |
| VA-100 | `modules/api_services` | How `data.google_project_service` reports a disabled API |
| VA-101 | `modules/service_identities` | Computed agent email forms |
| estate | `tiers/nonprod/main.project.tf` | Create-mode folder for the hub (unused in phase 1) |

## Differences from the contracts and design, to settle in build

- Module path: design section 2.3 says `modules/data-domain-shim`; the contracts and section 6.13.4
  say `modules/data_domain_shim`, which is used.
- Ingest service accounts: the contracts (section 2) put `<business>-ingest-dev` in the analytics
  projects; design sections 2.2 and 2.4.2 put them in the core data project, which is used and
  published in `domain_service_accounts`.
- Versions: design section 6.11 says `>= 1.17` and `~> 8.10`; the phase 1 brief and contracts say
  `~> 1.16` and exactly `8.10.0`, which are used.
- `policy_member` is the `iamPolicyNamePrincipal` string of the `policyMember` object (orchestrator
  decision); `binding` has one optional input, `organization_id`, beyond the design table.
- `terraform_data.iam` is also re-run when the domain is recreated (a new domain has an empty
  policy), and the destroy steps refuse to delete a domain or binding that differs from the
  declaration (a create that failed on 409 leaves the resource tainted).
- With no folders, the audit sinks are project sinks on the data projects, not aggregated folder
  sinks (section 2.5).
- Alerts: section 6.13.2 places alerts in this stack and section 5.8 in `cdmc-governance`; this
  stack has the dead-letter alerts only.
- Landing buckets: the ingest account has `roles/storage.objectViewer` only (section 2.4.2); the
  P6-39 generator that writes CSV files needs a writer identity that the design does not name.
- `data.http` uses the `google_client_config` token (section 2.3.2), so that token is held in the
  plan and state of the calling stack.

## Incomplete in this draft

- Create mode: environment folders (`shared/<env>`, `<business>/<env>`) and the `org/` stack are not
  drafted; with folders the audit sinks would be aggregated folder sinks instead of project sinks.
- `ci-checks`: every check runs on every change (no path filtering by changed inputs, section 6.3).
