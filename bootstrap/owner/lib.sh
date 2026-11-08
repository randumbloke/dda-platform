#!/usr/bin/env bash
# Shared helpers for the owner scripts (change mvp-phase-1-build, tasks 2.1-2.6).
# Writing scripts default to --dry-run: they print each command and run nothing that changes
# anything. Pass --apply to run the writes. Existence checks (describe/list) are read-only and
# always run, so a re-run skips what already exists (idempotent).
set -euo pipefail

# Estate values (contracts README §1, §2).
ORG_ID="1059663003036"
ORG_DOMAIN="mikegyoung.joonix.net"
GROUP_DOMAIN="mikegyoung.joonix.net"
CICD_PROJECT="pltfrm-ngnrng"
HUB_PROJECT="kcdda-dgov-hub-nonprod"
CORE_PROJECT="kcdda-core-dwh-dev"
CUSTOMER_ANALYTICS="kcdda-customer-analytics-dev"
ACCOUNTS_ANALYTICS="kcdda-accounts-analytics-dev"
DDA_PROJECTS=("$HUB_PROJECT" "$CICD_PROJECT" "$CORE_PROJECT" "$CUSTOMER_ANALYTICS" "$ACCOUNTS_ANALYTICS")
REGION="australia-southeast1"
BOOTSTRAP_GROUP="dda-bootstrap-admins@${GROUP_DOMAIN}"
OWNER_ACCOUNT="mikegyoung@google.com"

MODE="dry-run"

parse_mode() {
  for arg in "$@"; do
    case "$arg" in
      --apply) MODE="apply" ;;
      --dry-run) MODE="dry-run" ;;
    esac
  done
  echo "== mode: ${MODE}$([ "$MODE" = dry-run ] && echo ' (nothing will be changed; pass --apply to run the writes)')"
}

# do_write <command...>: print the command; execute it in apply mode.
do_write() {
  local line=""
  for a in "$@"; do line+=" $(printf '%q' "$a")"; done
  echo "+${line}"
  if [ "$MODE" = "apply" ]; then
    "$@"
  fi
}

skip() { echo "= skip: $*"; }

require() {
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 1; }
  done
}

group_exists() { gcloud identity groups describe "$1" --format='value(name)' >/dev/null 2>&1; }

sa_exists() { gcloud iam service-accounts describe "$1@$2.iam.gserviceaccount.com" --project="$2" --format='value(email)' >/dev/null 2>&1; }

# has_binding <iam-policy-json> <role> <member>
has_binding() {
  jq -e --arg r "$2" --arg m "$3" '.bindings[]? | select(.role == $r and (.condition == null)) | .members[] | select(. == $m)' <<<"$1" >/dev/null
}
