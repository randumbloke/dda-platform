#!/usr/bin/env bash
# Delete a data domain (design section 2.3.2): terraform_data.domain destroy provisioner.
#   DELETE .../dataDomains/<id>; 404 NOT_FOUND succeeds, so a destroy can be re-run; poll.
# Bindings are deleted first (binding submodule depends on this domain's name output) and
# subdomains before their parent (they depend on the parent's name), because a domain can be
# deleted only when it has no bindings (VA-15).
#
# Safety: a create that failed on 409 (an existing domain that differs from the declaration)
# leaves the resource tainted, and the next apply would run this destroy step. So, when
# DOMAIN_BODY is given, the domain is deleted only if its displayName and parent match the
# declaration; otherwise the step fails and the domain is left for a person to resolve.
# Environment: PROJECT, LOCATION, DATA_DOMAIN_ID, DOMAIN_BODY (values stored with the resource,
#   self.*).
source "$(dirname "$0")/lib.sh"

: "${PROJECT:?}" "${LOCATION:?}" "${DATA_DOMAIN_ID:?}"

domain_url="$DATAPLEX_API/projects/$PROJECT/locations/$LOCATION/dataDomains/$DATA_DOMAIN_ID"

if [[ -n "${DOMAIN_BODY:-}" ]]; then
  api GET "$domain_url"
  if [[ "$HTTP_STATUS" == "404" ]]; then
    log "domain $DATA_DOMAIN_ID not found; treating delete as done"
    exit 0
  fi
  require_2xx "GET $domain_url"
  identity='{displayName: (.displayName // ""), parent: ((.parentDataDomain // "") | sub("^.*/(?<t>locations/.*)$"; "\(.t)"))}'
  declared="$(jq -cS "$identity" <<<"$DOMAIN_BODY")"
  existing="$(jq -cS "$identity" <<<"$HTTP_BODY")"
  if [[ "$declared" != "$existing" ]]; then
    die "refusing to delete domain $DATA_DOMAIN_ID: it is not the declared domain (declared $declared, found $existing)"
  fi
fi

log "deleting data domain $DATA_DOMAIN_ID"
api DELETE "$domain_url"

case "$HTTP_STATUS" in
  2*) wait_operation "$HTTP_BODY" ;;
  404) log "domain $DATA_DOMAIN_ID not found; treating delete as done" ;;
  *) die "delete domain $DATA_DOMAIN_ID returned HTTP $HTTP_STATUS: $HTTP_BODY" ;;
esac
