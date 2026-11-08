#!/usr/bin/env bash
# Update a data domain in place (design section 2.3.2): terraform_data.update create provisioner,
# replaced when the SHA-256 of display_name, description, contacts and labels changes.
#   GET the domain, compare each mutable field with the declaration, then
#   PATCH .../dataDomains/<id>?updateMask=<changed fields>; poll. No change: no PATCH.
# VERIFY IN BUILD (VA-62): that patch changes contacts and labels in place.
# Environment: PROJECT, LOCATION, DATA_DOMAIN_ID, DOMAIN_BODY (JSON: displayName, description,
#   contacts, labels).
source "$(dirname "$0")/lib.sh"

: "${PROJECT:?}" "${LOCATION:?}" "${DATA_DOMAIN_ID:?}" "${DOMAIN_BODY:?}"

domain_url="$DATAPLEX_API/projects/$PROJECT/locations/$LOCATION/dataDomains/$DATA_DOMAIN_ID"

api GET "$domain_url"
require_2xx "GET $domain_url"
existing="$HTTP_BODY"

# Field name in the resource → field path in updateMask.
changed=()
for field in displayName description contacts labels; do
  case "$field" in
    contacts) filter='(.contacts // []) | map({role: (.role // ""), identity: (.identity // "")}) | sort_by(.role, .identity)' ;;
    labels) filter='(.labels // {})' ;;
    *) filter="(.${field} // \"\")" ;;
  esac
  d="$(jq -cS "$filter" <<<"$DOMAIN_BODY")"
  e="$(jq -cS "$filter" <<<"$existing")"
  if [[ "$d" != "$e" ]]; then changed+=("$field"); fi
done

if (( ${#changed[@]} == 0 )); then
  log "domain $DATA_DOMAIN_ID already matches the declaration; no update"
  exit 0
fi

mask="$(IFS=,; printf '%s' "${changed[*]}")"
body="$(jq -c --arg m "$mask" '($m | split(",")) as $f | with_entries(select(.key as $k | $f | index($k)))' <<<"$DOMAIN_BODY")"

log "patching domain $DATA_DOMAIN_ID: $mask"
api PATCH "$domain_url?updateMask=$(urlencode "$mask")" "$body"
require_2xx "PATCH $domain_url"
wait_operation "$HTTP_BODY"
