# Owner checklist: change `mvp-phase-1-build`, tasks 2.1 to 2.6

Scripts for the owner's pre-checks and one-off actions. The read-only scripts (2.1, 2.2) change
nothing. The writing scripts (2.3, 2.5, 2.6) default to `--dry-run`: they print each command
they would run and skip what already exists, so a re-run is safe. Nothing runs a write until you
pass `--apply`. None of them has been run.

Run from `bootstrap/`, signed in as the bootstrap administrator (`gcloud auth login
mikegyoung@google.com`). Tools: `gcloud`, `jq`, bash.

Offline check of the scripts (stub `gcloud`, no cloud call): `bash owner/test_dry_run.sh`.

| Task | Script | Writes? | Done when |
|---|---|---|---|
| 2.1 Estate inventory | `owner/21_estate_inventory.sh [out.json]` | No | JSON saved in `cdmc_kc/scratch/`; every project shows its P1-7 labels (the script prints `labels OK` or the missing ones) |
| 2.2 CI/CD IAM review | `owner/22_cicd_iam_review.sh [out.json]` | No | Each `findings` entry (a principal outside the DDA with project-wide Cloud Storage or Artifact Registry read on `pltfrm-ngnrng`) is logged in the defect register as a residual risk, or a note says none exist |
| 2.3 OD-2 bootstrap group | `BILLING_ACCOUNT=... owner/23_bootstrap_admins.sh [--apply]` | Yes | Group exists with `mikegyoung@google.com`; **manual**: allow external members in the Admin console; each §6.15.4 role shows on `group:dda-bootstrap-admins@…` in `get-iam-policy`; Groups Admin assigned outside IAM |
| 2.4 Organisation policies (deferred, OD-1) | none (before task 12.1) | | Set at project scope by the owner; not scripted here |
| 2.5 Groups and service accounts | `owner/25_groups_and_service_accounts.sh [--apply]` | Yes | Groups of §1.5.1 and §2.4.6 exist; `evaluator-dev` (hub), `customer-ingest-dev` and `accounts-ingest-dev` (core data project, §2.4.2), `customer-analytics-dev` and `accounts-analytics-dev` (their analytics projects) exist |
| 2.6 Tokens and secrets | `GATE_TOKEN_FILE=... CONNECTION_TOKEN_FILE=... owner/26_tokens_and_secrets.sh [--apply]` | Yes | `merge-gate-token` and `github-connection-token` in `pltfrm-ngnrng` each have a version; readers are only `tf-deployer` and the Cloud Build service agent; Cloud Build GitHub App installed on `randumbloke` |

Order with bootstrap (README "Runbook"): 2.1, 2.2, 2.3, 2.5, then bootstrap stage 1 (it
creates the secrets with no version and sends the collaborator invitations), then 2.6, the image
builds and stage 2.

Notes:

- `tf-deployer` and `tf-deployer-plan` are created by bootstrap stage 1
  (`manage_deployer_service_accounts = true`; owner decision OD-5, 2026-11-09). Do not create them
  in 2.5. The script's `--with-deployers` option is kept only for the hand-made alternative.
- Product access groups (`dda-dp-<product>-dev-reader`) are created here because the domain
  pipeline's Groups Admin alternative (§2.4.6) is not used in phase 1.
- Approval group membership is set by bootstrap from `approval_groups` (§6.6.4); the scripts
  create the groups only.
- The service accounts' project-level grants (§2.4) are made by the stacks that own them.
