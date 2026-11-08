#!/usr/bin/env bash
# Task 2.6: GitHub machine user token and Cloud Build connection token into Secret Manager
# (§6.4.1, §6.5.1, §6.6.3). Dry run by default. Tokens are read from files and never printed.
#
#   bash owner/26_tokens_and_secrets.sh                     # print the steps and current state
#   GATE_TOKEN_FILE=~/gate.txt CONNECTION_TOKEN_FILE=~/conn.txt \
#     bash owner/26_tokens_and_secrets.sh --apply
#
# Order: the secrets are created, with no version, by bootstrap stage 1 (§6.6.1); this script
# only adds versions (§6.6.2 step 2). If a secret is missing, apply stage 1 first.
# Verify: each secret has a version and no reader beyond the expected one (printed below).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require gcloud jq
parse_mode "$@"

cat <<'EOF'
== manual steps on GitHub (no API writes from this script)
 1. Create the GitHub account dda-gate-bot. Accept the collaborator invitations that bootstrap
    stage 1 sends (user mode, §6.6).
 2. As dda-gate-bot: Settings > Developer settings > Tokens (classic) > new token with NO scopes,
    expiry at most one year (§6.6.3; VERIFY IN BUILD (VA-103)). Save it to a local file.
 3. As randumbloke: a classic token with scopes repo and read:user for the Cloud Build host
    connection (§6.4.1). Save it to a local file.
 4. Install the Cloud Build GitHub App on randumbloke for the five repositories; note the
    installation ID (github_app_installation_id for bootstrap stage 2).
EOF

add_version() {
  local secret="$1" file="$2" expected_reader="$3"
  echo "== secret ${secret}"
  if ! gcloud secrets describe "$secret" --project="$CICD_PROJECT" --format='value(name)' >/dev/null 2>&1; then
    echo "!! ${secret} does not exist: apply bootstrap stage 1 first"
    return 0
  fi
  local versions
  versions="$(gcloud secrets versions list "$secret" --project="$CICD_PROJECT" --filter='state=ENABLED' --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$versions" -gt 0 ]; then
    skip "${secret} already has ${versions} enabled version(s); add a new one only to rotate"
  elif [ -z "$file" ]; then
    echo "!! no token file given for ${secret}"
    echo "+ gcloud secrets versions add ${secret} --project=${CICD_PROJECT} --data-file=<token file>"
  else
    [ -r "$file" ] || { echo "cannot read ${file}" >&2; exit 1; }
    do_write gcloud secrets versions add "$secret" --project="$CICD_PROJECT" --data-file="$file"
  fi
  echo "   expiry: set token_expiry_dates[\"${secret}\"] = \"YYYY-MM-DD\" in bootstrap.auto.tfvars and re-apply (label expire_time)"
  echo "   readers (expected: ${expected_reader}):"
  gcloud secrets get-iam-policy "$secret" --project="$CICD_PROJECT" --format=json 2>/dev/null \
    | jq -r '.bindings[]? | "     \(.role): \(.members | join(", "))"' || true
}

add_version merge-gate-token "${GATE_TOKEN_FILE:-}" "tf-deployer (secretAccessor)"
add_version github-connection-token "${CONNECTION_TOKEN_FILE:-}" "Cloud Build service agent (secretAccessor)"

echo "== project-wide Secret Manager readers on ${CICD_PROJECT} (should be none outside the DDA):"
gcloud projects get-iam-policy "$CICD_PROJECT" --format=json 2>/dev/null \
  | jq -r '.bindings[]? | select(.role | test("secretmanager\\.(admin|secretAccessor)|roles/owner|roles/editor")) | "   \(.role): \(.members | join(", "))"' || true
echo "== done (${MODE})"
