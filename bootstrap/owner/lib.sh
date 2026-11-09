#!/usr/bin/env bash
# Shared helpers for the owner scripts (change mvp-phase-1-build, tasks 2.1-2.6).
# Writing scripts default to --dry-run: they print each command and run nothing that changes
# anything. Pass --apply to run the writes. Existence checks (describe/list) are read-only and
# always run, so a re-run skips what already exists (idempotent).
# Run them as mikegyoung@google.com (OD-2; owner 2026-11-09: as much as possible under that
# account). Group steps run only as an account of the mikegyoung.joonix.net tenant (Cloud Shell as
# the Cloud Identity admin) and are skipped for any other caller (MB-06).
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

# MB-04: do not inherit the caller's gcloud quota project (on the owner's machine it is outside
# the DDA, with Cloud Billing disabled), and never wait at a prompt: stderr is often discarded,
# so an "enable API?" prompt would hang the script. Values the caller has set are kept.
export CLOUDSDK_BILLING_QUOTA_PROJECT="${CLOUDSDK_BILLING_QUOTA_PROJECT:-$CICD_PROJECT}"
export CLOUDSDK_CORE_DISABLE_PROMPTS="${CLOUDSDK_CORE_DISABLE_PROMPTS:-1}"

# OD-7 (P6-41): when GROUPS_ADMIN_SA or BUILDER_SA is set (for example
# sa-builder@pltfrm-ngnrng.iam.gserviceaccount.com, holding Cloud Identity Groups Admin),
# impersonate it for gcloud calls so an outside bootstrap administrator can run group steps locally.
if [ -n "${GROUPS_ADMIN_SA:-${BUILDER_SA:-}}" ]; then
  export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="${GROUPS_ADMIN_SA:-${BUILDER_SA:-}}"
fi

# The account the gcloud calls run as (the impersonated service account, if one is set).
CALLER="${CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT:-$(gcloud config get-value account 2>/dev/null || true)}"

# MB-06 / OD-7: for an account outside the tenant without Groups Admin, Cloud Identity answers
# every group lookup with 403 "Permission denied ... (or it may not exist)", and gcloud reports 403
# and 404 alike as "There is no such a group" (googlecloudsdk command_lib/identity/groups/hooks.py).
# A group lookup is trusted only for a tenant account or the Groups Admin service account (VA-111).
in_tenant() {
  [[ "$CALLER" == *"@${ORG_DOMAIN}" ]] && return 0
  [[ -n "${GROUPS_ADMIN_SA:-${BUILDER_SA:-}}" && "$CALLER" == "${GROUPS_ADMIN_SA:-${BUILDER_SA:-}}" ]] && return 0
  return 1
}

# tenant_caller <what>: 0 = the caller can see tenant groups, go ahead; 1 = skip <what> with a note.
tenant_caller() {
  in_tenant && return 0
  echo "!! skipped: $1. Group steps need an account of ${ORG_DOMAIN} or GROUPS_ADMIN_SA=sa-builder@${CICD_PROJECT}.iam.gserviceaccount.com (OD-7); ${CALLER:-this caller} cannot see the tenant's groups (MB-06)"
  return 1
}

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

# exists_check <not-found-regex> <command...>: 0 = present, 1 = absent (the error matches the
# not-found text); any other error (disabled API, permission, network) stops the script (MB-05).
exists_check() {
  local nf="$1"; shift
  local err
  if err="$("$@" 2>&1 >/dev/null)"; then return 0; fi
  if grep -qiE "$nf" <<<"$err"; then return 1; fi
  echo "error: existence check failed: $*" >&2
  echo "$err" >&2
  exit 1
}

# Not-found texts seen live on 2026-11-09 (gcloud identity groups / iam service-accounts describe).
# The group text also covers a 403 (MB-06), so group_exists is trusted only for a tenant account.
group_exists() {
  in_tenant || { echo "error: group lookup as ${CALLER:-an unknown account}, outside ${ORG_DOMAIN}, proves nothing (MB-06)" >&2; exit 1; }
  exists_check 'no such a group|NOT_FOUND' gcloud identity groups describe "$1" --format='value(name)'
}

sa_exists() { exists_check 'NOT_FOUND' gcloud iam service-accounts describe "$1@$2.iam.gserviceaccount.com" --project="$2" --format='value(email)'; }

# read_policy <what> <gcloud ... get-iam-policy args...>: print the policy as JSON. A policy the
# caller cannot read stops the script: read as empty, it would plan grants that may exist (MB-06).
read_policy() {
  local what="$1"; shift
  "$@" --format=json || { echo "error: cannot read the IAM policy of ${what} as ${CALLER:-this caller}" >&2; exit 1; }
}

# has_binding <iam-policy-json> <role> <member>
has_binding() {
  jq -e --arg r "$2" --arg m "$3" '.bindings[]? | select(.role == $r and (.condition == null)) | .members[] | select(. == $m)' <<<"$1" >/dev/null
}
