#!/usr/bin/env bash
# Set a data domain's IAM policy (design sections 2.3, 2.3.2): terraform_data.iam create
# provisioner, replaced when the SHA-256 of iam_members changes.
#   POST .../dataDomains/<id>:getIamPolicy, then :setIamPolicy with the declared bindings and the
#   returned etag. The module is the only writer of domain IAM (section 6.15.1), so it sets the
#   whole policy. On an etag conflict (409/ABORTED) it re-reads and retries, up to 3 times.
# The allowed-role list is enforced by the module's variable validation before this runs
# (VA-48, VA-87). VERIFY IN BUILD (VA-62): setIamPolicy on a domain accepts the allowed roles.
# Environment: PROJECT, LOCATION, DATA_DOMAIN_ID, IAM_BINDINGS (JSON list of {role, members}).
source "$(dirname "$0")/lib.sh"

: "${PROJECT:?}" "${LOCATION:?}" "${DATA_DOMAIN_ID:?}" "${IAM_BINDINGS:?}"

domain_url="$DATAPLEX_API/projects/$PROJECT/locations/$LOCATION/dataDomains/$DATA_DOMAIN_ID"

for attempt in 1 2 3; do
  api POST "$domain_url:getIamPolicy" '{}'
  require_2xx "getIamPolicy $DATA_DOMAIN_ID"
  etag="$(jq -r '.etag // empty' <<<"$HTTP_BODY")"

  body="$(jq -cn --argjson b "$IAM_BINDINGS" --arg etag "$etag" \
    '{policy: ({bindings: ($b | map(select((.members | length) > 0)))} + (if $etag == "" then {} else {etag: $etag} end))}')"

  log "setting IAM policy on domain $DATA_DOMAIN_ID (attempt $attempt)"
  api POST "$domain_url:setIamPolicy" "$body"
  case "$HTTP_STATUS" in
    2*) log "IAM policy set"; exit 0 ;;
    409) log "etag conflict; re-reading the policy" ;;
    *) die "setIamPolicy $DATA_DOMAIN_ID returned HTTP $HTTP_STATUS: $HTTP_BODY" ;;
  esac
done

die "setIamPolicy $DATA_DOMAIN_ID failed after 3 etag conflicts"
