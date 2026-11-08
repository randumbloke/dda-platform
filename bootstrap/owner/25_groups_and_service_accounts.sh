#!/usr/bin/env bash
# Task 2.5: create the phase 1 Cloud Identity groups (§2.4.6, §1.5.1; names per contracts §2)
# and the phase 1 runtime service accounts (§6.17 asks table). Dry run by default.
#
#   bash owner/25_groups_and_service_accounts.sh                       # print what would change
#   bash owner/25_groups_and_service_accounts.sh --apply
#   bash owner/25_groups_and_service_accounts.sh --apply --with-deployers   # only if bootstrap does
#                                    # not create tf-deployer/-plan (manage_deployer_service_accounts = false)
#
# Service account placement follows dda-platform envs/dev (modules/id_gen, domain_service_accounts):
# ingest accounts in the core data project (§2.4.2), analytics accounts in each domain's analytics
# project, evaluator-dev in the hub. Their project-level grants (§2.4) are made by the stacks that
# own them, not here. Membership of the approval groups is set by bootstrap (§6.6.4).
# Verify: gcloud identity groups search --organization=mikegyoung.joonix.net --labels=... and
#         gcloud iam service-accounts list --project=<p>
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require gcloud
parse_mode "$@"

WITH_DEPLOYERS=false
for a in "$@"; do [ "$a" = "--with-deployers" ] && WITH_DEPLOYERS=true; done

ENV=dev
DDA_GROUPS=(
  # Platform and approval groups (§1.5.1, §6.6.4, §6.7)
  "dda-platform-engineers|DDA platform engineers"
  "dda-release-approvers|DDA release approvers"
  "dda-governance-admins|DDA governance admins"
  "dda-governance-engineers|DDA governance engineers"
  "dda-compliance-reviewers|DDA compliance reviewers"
  "dda-data-users|DDA data users (organisation-wide catalogue access)"
  # Domain groups (contracts §2)
  "dda-customer-${ENV}-owners|Customer ${ENV} domain owners"
  "dda-customer-${ENV}-stewards|Customer ${ENV} domain stewards"
  "dda-customer-producers|Customer domain producers"
  "dda-accounts-${ENV}-owners|Accounts ${ENV} domain owners"
  "dda-accounts-${ENV}-stewards|Accounts ${ENV} domain stewards"
  "dda-accounts-producers|Accounts domain producers"
  # Product owner and access groups (products/<id>.yaml: access group id "reader")
  "dda-dp-customer-profile-${ENV}-owners|Customer Profile ${ENV} product owners"
  "dda-dp-customer-profile-${ENV}-reader|Customer Profile ${ENV} readers (product access group)"
  "dda-dp-account-summary-${ENV}-owners|Account Summary ${ENV} product owners"
  "dda-dp-account-summary-${ENV}-reader|Account Summary ${ENV} readers (product access group)"
)

echo "== groups in ${GROUP_DOMAIN}"
for entry in "${DDA_GROUPS[@]}"; do
  name="${entry%%|*}"; display="${entry#*|}"
  email="${name}@${GROUP_DOMAIN}"
  if group_exists "$email"; then skip "$email"; else
    do_write gcloud identity groups create "$email" --organization="$ORG_DOMAIN" --display-name="$display"
  fi
done

SERVICE_ACCOUNTS=(
  "evaluator-${ENV}|${HUB_PROJECT}|DDA control evaluator (${ENV})"
  "customer-ingest-${ENV}|${CORE_PROJECT}|Customer ingest pipeline (${ENV})"
  "accounts-ingest-${ENV}|${CORE_PROJECT}|Accounts ingest pipeline (${ENV})"
  "customer-analytics-${ENV}|${CUSTOMER_ANALYTICS}|Customer analytics pipeline (${ENV})"
  "accounts-analytics-${ENV}|${ACCOUNTS_ANALYTICS}|Accounts analytics pipeline (${ENV})"
)
if [ "$WITH_DEPLOYERS" = true ]; then
  SERVICE_ACCOUNTS+=(
    "tf-deployer|${CICD_PROJECT}|DDA deployer: applies every repository (single_deployer)"
    "tf-deployer-plan|${CICD_PROJECT}|DDA deployer plan account: read only"
  )
  echo "!! --with-deployers: set manage_deployer_service_accounts = false in bootstrap.tfvars"
else
  echo "== tf-deployer and tf-deployer-plan: created by bootstrap stage 1 (manage_deployer_service_accounts = true)"
fi

echo "== service accounts"
for entry in "${SERVICE_ACCOUNTS[@]}"; do
  IFS='|' read -r id project display <<<"$entry"
  if sa_exists "$id" "$project"; then skip "${id}@${project}"; else
    do_write gcloud iam service-accounts create "$id" --project="$project" --display-name="$display"
  fi
done

echo "== done (${MODE})"
