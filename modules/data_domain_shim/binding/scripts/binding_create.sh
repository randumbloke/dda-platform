#!/usr/bin/env bash
# Create a data domain binding (design sections 2.3.1, 2.3.2): terraform_data.binding create
# provisioner. Runs after the ddaDomainDelegate grant on the resource (VA-15, VA-49).
#   POST <domain_name>/bindings?dataDomainBindingId=<key>; on 409 GET and compare the resource;
#   poll. The ID derived from the key means a retried stack finds the one binding (P6-27). A
#   grant made in the same apply can take a short time to propagate, so a refused first create is
#   left to the stack retry (section 6.14.3).
# Environment: DOMAIN_NAME, BINDING_ID, RESOURCE.
source "$(dirname "$0")/lib.sh"

: "${DOMAIN_NAME:?}" "${BINDING_ID:?}" "${RESOURCE:?}"

binding_url="$DATAPLEX_API/$DOMAIN_NAME/bindings/$BINDING_ID"
body="$(jq -cn --arg r "$RESOURCE" '{resource: $r}')"

log "binding $RESOURCE to $DOMAIN_NAME as $BINDING_ID"
api POST "$DATAPLEX_API/$DOMAIN_NAME/bindings?dataDomainBindingId=$(urlencode "$BINDING_ID")" "$body"

case "$HTTP_STATUS" in
  2*)
    wait_operation "$HTTP_BODY"
    ;;
  409)
    log "binding $BINDING_ID already exists; comparing its resource"
    api GET "$binding_url"
    require_2xx "GET $binding_url"
    existing="$(jq -r '.resource // empty' <<<"$HTTP_BODY")"
    if [[ "$existing" != "$RESOURCE" ]]; then
      die "binding $BINDING_ID exists for $existing, not the declared $RESOURCE (bindings are immutable; delete it first)"
    fi
    log "existing binding matches the declaration"
    ;;
  *)
    die "create binding $BINDING_ID returned HTTP $HTTP_STATUS: $HTTP_BODY"
    ;;
esac
