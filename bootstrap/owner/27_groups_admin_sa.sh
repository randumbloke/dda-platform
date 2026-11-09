#!/usr/bin/env bash
# Task 2.7 / 2.8 (OD-7, P6-41): grant dda-bootstrap-admins roles/iam.serviceAccountTokenCreator on
# the groups administrator service account (sa-builder@pltfrm-ngnrng.iam.gserviceaccount.com), print
# the one-time Admin console step that assigns it the Cloud Identity Groups Admin role, and verify
# VA-111 when --verify is passed. Dry run by default.
#
#   bash owner/27_groups_admin_sa.sh            # print what would change
#   bash owner/27_groups_admin_sa.sh --apply    # grant tokenCreator to the bootstrap group
#   bash owner/27_groups_admin_sa.sh --verify   # verify VA-111 (describe + memberships list via SA)
set -euo pipefail
# Read policy and grant as the bootstrap administrator (before impersonating the SA).
unset CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT GROUPS_ADMIN_SA BUILDER_SA
source "$(dirname "$0")/lib.sh"
require gcloud jq
parse_mode "$@"

VERIFY_ONLY=false
for a in "$@"; do
  case "$a" in
    --verify) VERIFY_ONLY=true ;;
  esac
done

SA_ID="sa-builder"
SA_EMAIL="${SA_ID}@${CICD_PROJECT}.iam.gserviceaccount.com"
GROUP_MEMBER="group:${BOOTSTRAP_GROUP}"
ROLE="roles/iam.serviceAccountTokenCreator"

if [ "$VERIFY_ONLY" = true ]; then
  echo "== verifying VA-111 via ${SA_EMAIL}"
  gcloud identity groups describe "$BOOTSTRAP_GROUP" \
    --impersonate-service-account="$SA_EMAIL" \
    --format='value(name)'
  gcloud identity groups memberships list \
    --group-email="$BOOTSTRAP_GROUP" \
    --impersonate-service-account="$SA_EMAIL" \
    --format='value(preferredMemberKey.id,roles.name)'
  exit 0
fi

echo "== 1. ${ROLE} on ${SA_EMAIL} for ${GROUP_MEMBER} (never the user)"
sa_pol="$(read_policy "serviceAccount/${SA_EMAIL}" gcloud iam service-accounts get-iam-policy "$SA_EMAIL" --project="$CICD_PROJECT")"
if has_binding "$sa_pol" "$ROLE" "$GROUP_MEMBER"; then
  skip "${SA_EMAIL} ${ROLE}"
else
  do_write gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --project="$CICD_PROJECT" \
    --member="$GROUP_MEMBER" \
    --role="$ROLE" \
    --condition=None >/dev/null
fi

cat <<EOF
== 2. One-time Admin console step (as a Cloud Identity super administrator of ${ORG_DOMAIN}):
   https://admin.google.com -> Account -> Admin roles -> Groups Admin -> Admins
   -> Assign service accounts -> ${SA_EMAIL}
== 3. Then verify VA-111:
   bash owner/27_groups_admin_sa.sh --verify
EOF
echo "== done (${MODE})"
