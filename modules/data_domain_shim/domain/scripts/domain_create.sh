#!/usr/bin/env bash
# Create a data domain (design sections 2.3, 2.3.2): terraform_data.domain create provisioner.
#   POST .../dataDomains?dataDomainId=<id>; on 409 ALREADY_EXISTS GET and compare with the
#   declared domain (succeed if equal, fail if not); poll the operation.
# Environment: PROJECT, LOCATION, DATA_DOMAIN_ID, DOMAIN_BODY (JSON: displayName, description,
#   contacts, labels and, for a subdomain, parentDataDomain).
source "$(dirname "$0")/lib.sh"

: "${PROJECT:?}" "${LOCATION:?}" "${DATA_DOMAIN_ID:?}" "${DOMAIN_BODY:?}"

parent_url="$DATAPLEX_API/projects/$PROJECT/locations/$LOCATION"
domain_url="$parent_url/dataDomains/$DATA_DOMAIN_ID"

# Normalise a domain for comparison: only the declared fields, missing values as defaults, and
# the parent as its path from "locations/" (the API may return a project number).
normalise='{
  displayName: (.displayName // ""),
  description: (.description // ""),
  contacts: ((.contacts // []) | map({role: (.role // ""), identity: (.identity // "")}) | sort_by(.role, .identity)),
  labels: (.labels // {}),
  parent: ((.parentDataDomain // "") | sub("^.*/(?<t>locations/.*)$"; "\(.t)"))
}'

log "creating data domain $DATA_DOMAIN_ID in projects/$PROJECT/locations/$LOCATION"
api POST "$parent_url/dataDomains?dataDomainId=$(urlencode "$DATA_DOMAIN_ID")" "$DOMAIN_BODY"

case "$HTTP_STATUS" in
  2*)
    wait_operation "$HTTP_BODY"
    ;;
  409)
    log "domain $DATA_DOMAIN_ID already exists; comparing with the declared domain"
    api GET "$domain_url"
    require_2xx "GET $domain_url"
    declared="$(jq -S "$normalise" <<<"$DOMAIN_BODY")"
    existing="$(jq -S "$normalise" <<<"$HTTP_BODY")"
    if [[ "$declared" != "$existing" ]]; then
      die "domain $DATA_DOMAIN_ID exists but differs from the declared domain:
declared: $declared
existing: $existing"
    fi
    log "existing domain matches the declaration"
    ;;
  *)
    die "create domain $DATA_DOMAIN_ID returned HTTP $HTTP_STATUS: $HTTP_BODY"
    ;;
esac
