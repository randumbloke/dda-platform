#!/usr/bin/env bash
# Task 2.3 (OD-2): create dda-bootstrap-admins, add mikegyoung@google.com, and grant the §6.15.4
# roles to the group (never to the user) at their scopes. Dry run by default.
#
#   bash owner/23_bootstrap_admins.sh            # print what would change
#   bash owner/23_bootstrap_admins.sh --apply    # as mikegyoung@google.com: the grants; the group
#                                                # steps are skipped for an outside caller (MB-06)
#   BILLING_ACCOUNT=XXXXXX-XXXXXX-XXXXXX bash owner/23_bootstrap_admins.sh --apply
#                                                # only as an account with billing.admin on it
#
# The group steps (create, membership) run only as an account of the tenant: in Cloud Shell as
# the Cloud Identity admin (MB-06).
# Manual step (no gcloud flag): in the Admin console, set the group to allow members outside the
# organisation, because the member is a google.com account (OD-2). Domain-restricted sharing
# checks IAM principals, not group members, so the grants survive the later policies.
# Verify: gcloud projects get-iam-policy <p> shows each grant on group:dda-bootstrap-admins.
# VERIFY IN BUILD (VA-99): each role name.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require gcloud jq
parse_mode "$@"

G="group:${BOOTSTRAP_GROUP}"

echo "== group ${BOOTSTRAP_GROUP}"
if tenant_caller "group create and the ${OWNER_ACCOUNT} membership"; then
  if group_exists "$BOOTSTRAP_GROUP"; then
    skip "group exists"
  else
    do_write gcloud identity groups create "$BOOTSTRAP_GROUP" --organization="$ORG_DOMAIN" \
      --display-name="DDA bootstrap admins" --description="Applies the DDA bootstrap stack (design 6.15.4)"
  fi

  if group_exists "$BOOTSTRAP_GROUP" && gcloud identity groups memberships check-transitive-membership \
       --group-email="$BOOTSTRAP_GROUP" --member-email="$OWNER_ACCOUNT" --format='value(hasMembership)' 2>/dev/null | grep -qi true; then
    skip "${OWNER_ACCOUNT} is a member"
  else
    do_write gcloud identity groups memberships add --group-email="$BOOTSTRAP_GROUP" --member-email="$OWNER_ACCOUNT"
  fi
  echo "!! manual: Admin console > Groups > ${BOOTSTRAP_GROUP} > allow external members = on"
fi

grant_org() {
  local policy; policy="$(read_policy "organisation ${ORG_ID}" gcloud organizations get-iam-policy "$ORG_ID")"
  for r in "$@"; do
    if has_binding "$policy" "$r" "$G"; then skip "org ${r}"; else
      do_write gcloud organizations add-iam-policy-binding "$ORG_ID" --member="$G" --role="$r" --condition=None --quiet
    fi
  done
}

grant_project() {
  local p="$1"; shift
  local policy; policy="$(read_policy "project ${p}" gcloud projects get-iam-policy "$p")"
  for r in "$@"; do
    if has_binding "$policy" "$r" "$G"; then skip "${p} ${r}"; else
      do_write gcloud projects add-iam-policy-binding "$p" --member="$G" --role="$r" --condition=None --quiet
    fi
  done
}

echo "== organisation ${ORG_ID}"
grant_org roles/resourcemanager.folderAdmin roles/resourcemanager.projectCreator roles/iam.securityAdmin \
  roles/iam.organizationRoleAdmin roles/orgpolicy.policyAdmin roles/logging.configWriter

echo "== billing account"
if [ -n "${BILLING_ACCOUNT:-}" ]; then
  policy="$(read_policy "billing account ${BILLING_ACCOUNT}" gcloud billing accounts get-iam-policy "$BILLING_ACCOUNT")"
  if has_binding "$policy" roles/billing.admin "$G"; then skip "billing.admin"; else
    do_write gcloud billing accounts add-iam-policy-binding "$BILLING_ACCOUNT" --member="$G" --role=roles/billing.admin
  fi
else
  echo "!! BILLING_ACCOUNT not set: billing grant skipped (VERIFY IN BUILD (estate); read it with: gcloud billing projects describe ${CICD_PROJECT})"
fi

echo "== CI/CD project ${CICD_PROJECT}"
grant_project "$CICD_PROJECT" roles/serviceusage.serviceUsageAdmin roles/storage.admin roles/artifactregistry.admin \
  roles/iam.serviceAccountAdmin roles/iam.serviceAccountUser roles/secretmanager.admin roles/cloudbuild.connectionAdmin \
  roles/cloudbuild.builds.editor roles/pubsub.admin roles/logging.admin roles/monitoring.editor

echo "== hub and data projects"
for p in "$HUB_PROJECT" "$CORE_PROJECT" "$CUSTOMER_ANALYTICS" "$ACCOUNTS_ANALYTICS"; do
  grant_project "$p" roles/iam.serviceAccountAdmin
done

echo "!! outside Cloud IAM: a Workspace / Cloud Identity administrator assigns Groups Admin to the administrator (§6.15.4)"
echo "== done (${MODE})"
