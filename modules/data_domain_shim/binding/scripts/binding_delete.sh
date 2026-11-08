#!/usr/bin/env bash
# Delete a data domain binding (design sections 2.3.1, 2.3.2): terraform_data.binding destroy
# provisioner. Runs before the grant is removed (the grant resources are its dependencies, so
# Terraform destroys them after it), and before the domain is deleted.
#   DELETE <domain_name>/bindings/<key>; 404 NOT_FOUND succeeds; poll.
# Environment: DOMAIN_NAME, BINDING_ID (values stored with the resource, self.*).
source "$(dirname "$0")/lib.sh"

: "${DOMAIN_NAME:?}" "${BINDING_ID:?}"

binding_url="$DATAPLEX_API/$DOMAIN_NAME/bindings/$BINDING_ID"

log "deleting binding $BINDING_ID of $DOMAIN_NAME"
api DELETE "$binding_url"

case "$HTTP_STATUS" in
  2*) wait_operation "$HTTP_BODY" ;;
  404) log "binding $BINDING_ID not found; treating delete as done" ;;
  *) die "delete binding $BINDING_ID returned HTTP $HTTP_STATUS: $HTTP_BODY" ;;
esac
