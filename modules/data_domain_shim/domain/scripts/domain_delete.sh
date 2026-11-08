#!/usr/bin/env bash
# Delete a data domain (design section 2.3.2): terraform_data.domain destroy provisioner.
#   DELETE .../dataDomains/<id>; 404 NOT_FOUND succeeds, so a destroy can be re-run; poll.
# Bindings are deleted first (binding submodule depends on this domain's name output) and
# subdomains before their parent (they depend on the parent's name), because a domain can be
# deleted only when it has no bindings (VA-15).
# Environment: PROJECT, LOCATION, DATA_DOMAIN_ID (values stored with the resource, self.*).
source "$(dirname "$0")/lib.sh"

: "${PROJECT:?}" "${LOCATION:?}" "${DATA_DOMAIN_ID:?}"

domain_url="$DATAPLEX_API/projects/$PROJECT/locations/$LOCATION/dataDomains/$DATA_DOMAIN_ID"

log "deleting data domain $DATA_DOMAIN_ID"
api DELETE "$domain_url"

case "$HTTP_STATUS" in
  2*) wait_operation "$HTTP_BODY" ;;
  404) log "domain $DATA_DOMAIN_ID not found; treating delete as done" ;;
  *) die "delete domain $DATA_DOMAIN_ID returned HTTP $HTTP_STATUS: $HTTP_BODY" ;;
esac
