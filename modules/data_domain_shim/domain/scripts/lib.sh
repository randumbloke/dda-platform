#!/usr/bin/env bash
# Shared helpers for the data_domain_shim scripts (design section 2.3.2; ADR-008, P6-26).
# The same file is in modules/data_domain_shim/domain/scripts/ and .../binding/scripts/ (each
# submodule is fetched on its own by a git:: source); CI checks the two copies are identical.
#
# Needs: bash, curl, jq (the runner image dda-ci/terraform-runner, section 6.4.2).
# No token passes through Terraform: each call gets the build service account's access token
# from the metadata server. VERIFY IN BUILD (VA-95).

set -euo pipefail

DATAPLEX_API="${DATAPLEX_API:-https://dataplex.googleapis.com/v1}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-5}"   # VERIFY IN BUILD (VA-96)
POLL_TIMEOUT_SECONDS="${POLL_TIMEOUT_SECONDS:-600}"   # VERIFY IN BUILD (VA-96)
METADATA_TOKEN_URL="http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"

log() { printf '[data_domain_shim] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required (runner image dda-ci/terraform-runner)"
done

# access_token: metadata server first (Cloud Build, VA-95). On a workstation with no metadata
# server, a bootstrap administrator may run with gcloud credentials instead; the token is only
# held in this process's memory.
access_token() {
  local token
  if token="$(curl -sf --max-time 3 -H 'Metadata-Flavor: Google' "$METADATA_TOKEN_URL" 2>/dev/null | jq -r '.access_token // empty')" && [[ -n "$token" ]]; then
    printf '%s' "$token"
    return 0
  fi
  if command -v gcloud >/dev/null 2>&1; then
    token="$(gcloud auth print-access-token 2>/dev/null || true)"
    [[ -n "$token" ]] && { printf '%s' "$token"; return 0; }
  fi
  die "no access token: metadata server unreachable and no gcloud credentials"
}

# api METHOD URL [BODY]: sets HTTP_STATUS and HTTP_BODY; never exits on HTTP errors.
api() {
  local method="$1" url="$2" body="${3:-}" out status
  out="$(mktemp)"
  local args=(-sS -o "$out" -w '%{http_code}' -X "$method"
    -H "Authorization: Bearer $(access_token)"
    -H 'Content-Type: application/json')
  [[ -n "$body" ]] && args+=(--data "$body")
  status="$(curl "${args[@]}" "$url")" || status="000"
  HTTP_STATUS="$status"
  HTTP_BODY="$(cat "$out")"
  rm -f "$out"
}

# urlencode STRING
urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

# wait_operation OPERATION_JSON: polls a long-running operation every POLL_INTERVAL_SECONDS and
# fails after POLL_TIMEOUT_SECONDS or on an operation error. A response that is not an operation
# (no "name" starting "projects/.../operations/") is treated as already complete.
wait_operation() {
  local op="$1" name done_flag waited=0
  name="$(jq -r '.name // empty' <<<"$op")"
  if [[ "$name" != */operations/* ]]; then
    return 0
  fi
  while :; do
    done_flag="$(jq -r '.done // false' <<<"$op")"
    if [[ "$done_flag" == "true" ]]; then
      if jq -e '.error' >/dev/null <<<"$op"; then
        die "operation $name failed: $(jq -c '.error' <<<"$op")"
      fi
      log "operation $name done"
      return 0
    fi
    if (( waited >= POLL_TIMEOUT_SECONDS )); then
      die "operation $name has no result after ${POLL_TIMEOUT_SECONDS}s"
    fi
    sleep "$POLL_INTERVAL_SECONDS"
    waited=$(( waited + POLL_INTERVAL_SECONDS ))
    api GET "$DATAPLEX_API/$name"
    [[ "$HTTP_STATUS" == "200" ]] || die "polling $name returned HTTP $HTTP_STATUS: $HTTP_BODY"
    op="$HTTP_BODY"
  done
}

# require_2xx CONTEXT
require_2xx() {
  [[ "$HTTP_STATUS" =~ ^2 ]] || die "$1 returned HTTP $HTTP_STATUS: $HTTP_BODY"
}

# Path tail from "locations/" onwards, so names with a project ID and with a project number
# compare equal.
location_tail() { sed -E 's#^.*/(locations/.*)$#\1#' <<<"$1"; }
