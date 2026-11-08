#!/usr/bin/env bash
# Offline tests of the data_domain_shim scripts (design section 2.3.2): a stub `curl` on PATH
# replays canned HTTP responses, so the 409-compare, 404-on-delete, operation polling, timeout,
# updateMask and etag paths run with no network and no credentials.
# Usage: scripts/test_shim.sh   (exit 1 on any failure)
set -uo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
dom="$repo/modules/data_domain_shim/domain/scripts"
bnd="$repo/modules/data_domain_shim/binding/scripts"
API="https://dataplex.googleapis.com/v1"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# Stub curl. Responses file: one per line, "METHOD<TAB>URL-substring<TAB>status<TAB>body"; the
# first matching line is used and removed, so repeated calls get successive responses.
cat > "$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
out="" method="GET" data="" url=""
while (( $# )); do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -X) method="$2"; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    -w|-H|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
if [[ "$url" == *metadata.google.internal* ]]; then
  printf '{"access_token":"stub-token"}'
  exit 0
fi
printf '%s\t%s\t%s\n' "$method" "$url" "$data" >> "$STUB_DIR/calls"
line_no=0 status=404 body='{"error":{"code":404}}' found=0
while IFS=$'\t' read -r m u s b; do
  line_no=$((line_no + 1))
  if [[ "$m" == "$method" && "$url" == *"$u"* ]]; then status="$s"; body="$b"; found=1; break; fi
done < "$STUB_DIR/responses"
if (( found )); then sed -i.bak "${line_no}d" "$STUB_DIR/responses"; fi
[[ -n "$out" ]] && printf '%s' "$body" > "$out"
printf '%s' "$status"
STUB
chmod +x "$work/bin/curl"

export PATH="$work/bin:$PATH" STUB_DIR="$work" POLL_INTERVAL_SECONDS=0 POLL_TIMEOUT_SECONDS=5
export PROJECT=hub LOCATION=australia-southeast1 DATA_DOMAIN_ID=customer-dev
DOMAIN_BODY='{"displayName":"Customer (dev)","description":"","contacts":[{"role":"owner","identity":"group:o@x"}],"labels":{"dda-env":"dev"}}'
export DOMAIN_BODY

pass=0 failed=0
# scenario NAME EXPECT(0|1) SCRIPT [responses...]
scenario() {
  local name="$1" expect="$2" script="$3"; shift 3
  : > "$work/calls"; : > "$work/responses"
  local r; for r in "$@"; do printf '%s\n' "$r" >> "$work/responses"; done
  bash "$script" >"$work/out" 2>&1
  local rc=$?; rc=$(( rc == 0 ? 0 : 1 ))
  if [[ "$rc" == "$expect" ]]; then
    echo "pass $name"; pass=$((pass + 1))
  else
    echo "FAIL $name (exit $rc, expected $expect)"; sed 's/^/     /' "$work/out"; failed=$((failed + 1))
  fi
}
T=$'\t'
OP="projects/hub/locations/australia-southeast1/operations/op-1"

scenario "create polls the operation to done" 0 "$dom/domain_create.sh" \
  "POST${T}dataDomains?dataDomainId=customer-dev${T}200${T}{\"name\":\"$OP\",\"done\":false}" \
  "GET${T}$OP${T}200${T}{\"name\":\"$OP\",\"done\":false}" \
  "GET${T}$OP${T}200${T}{\"name\":\"$OP\",\"done\":true,\"response\":{}}"

scenario "create fails on an operation error" 1 "$dom/domain_create.sh" \
  "POST${T}dataDomains?dataDomainId${T}200${T}{\"name\":\"$OP\",\"done\":false}" \
  "GET${T}$OP${T}200${T}{\"name\":\"$OP\",\"done\":true,\"error\":{\"code\":7}}"

POLL_TIMEOUT_SECONDS=0 scenario "create fails when the operation has no result in time" 1 "$dom/domain_create.sh" \
  "POST${T}dataDomains?dataDomainId${T}200${T}{\"name\":\"$OP\",\"done\":false}"

scenario "create 409 with a matching domain succeeds" 0 "$dom/domain_create.sh" \
  "POST${T}dataDomains?dataDomainId${T}409${T}{\"error\":{\"code\":409}}" \
  "GET${T}dataDomains/customer-dev${T}200${T}{\"name\":\"projects/123/locations/australia-southeast1/dataDomains/customer-dev\",\"displayName\":\"Customer (dev)\",\"contacts\":[{\"role\":\"owner\",\"identity\":\"group:o@x\"}],\"labels\":{\"dda-env\":\"dev\"},\"policyMember\":{}}"

scenario "create 409 with a different domain fails" 1 "$dom/domain_create.sh" \
  "POST${T}dataDomains?dataDomainId${T}409${T}{}" \
  "GET${T}dataDomains/customer-dev${T}200${T}{\"displayName\":\"Other\",\"contacts\":[],\"labels\":{}}"

scenario "create fails on 403" 1 "$dom/domain_create.sh" \
  "POST${T}dataDomains?dataDomainId${T}403${T}{\"error\":{\"code\":403}}"

scenario "delete 404 succeeds" 0 "$dom/domain_delete.sh" \
  "DELETE${T}dataDomains/customer-dev${T}404${T}{}"

scenario "delete polls the operation" 0 "$dom/domain_delete.sh" \
  "DELETE${T}dataDomains/customer-dev${T}200${T}{\"name\":\"$OP\",\"done\":true}"

scenario "update patches only the changed field" 0 "$dom/domain_update.sh" \
  "GET${T}dataDomains/customer-dev${T}200${T}{\"displayName\":\"Customer (dev)\",\"contacts\":[{\"role\":\"owner\",\"identity\":\"group:o@x\"}],\"labels\":{\"dda-env\":\"old\"}}" \
  "PATCH${T}updateMask=labels${T}200${T}{\"name\":\"$OP\",\"done\":true}"
if grep -q $'^PATCH\t.*updateMask=labels\t{"labels":{"dda-env":"dev"}}$' "$work/calls"; then
  echo "pass update body holds only labels"; pass=$((pass + 1))
else
  echo "FAIL update body"; cat "$work/calls"; failed=$((failed + 1))
fi

scenario "update with no change sends no PATCH" 0 "$dom/domain_update.sh" \
  "GET${T}dataDomains/customer-dev${T}200${T}{\"displayName\":\"Customer (dev)\",\"description\":\"\",\"contacts\":[{\"role\":\"owner\",\"identity\":\"group:o@x\"}],\"labels\":{\"dda-env\":\"dev\"}}"
if grep -q '^PATCH' "$work/calls"; then echo "FAIL no-change update sent a PATCH"; failed=$((failed + 1)); else echo "pass no PATCH sent"; pass=$((pass + 1)); fi

export IAM_BINDINGS='[{"role":"roles/dataplex.dataDomainViewer","members":["group:v@x"]}]'
scenario "IAM set with the etag" 0 "$dom/domain_iam.sh" \
  "POST${T}:getIamPolicy${T}200${T}{\"etag\":\"BwE=\",\"bindings\":[]}" \
  "POST${T}:setIamPolicy${T}200${T}{}"
if grep -q '"etag":"BwE="' "$work/calls"; then echo "pass setIamPolicy carries the etag"; pass=$((pass + 1)); else echo "FAIL etag"; failed=$((failed + 1)); fi

scenario "IAM retries an etag conflict" 0 "$dom/domain_iam.sh" \
  "POST${T}:getIamPolicy${T}200${T}{\"etag\":\"A\"}" \
  "POST${T}:setIamPolicy${T}409${T}{}" \
  "POST${T}:getIamPolicy${T}200${T}{\"etag\":\"B\"}" \
  "POST${T}:setIamPolicy${T}200${T}{}"

export DOMAIN_NAME="projects/hub/locations/australia-southeast1/dataDomains/customer-dev-curated"
export BINDING_ID=ds-customer-curated RESOURCE="//bigquery.googleapis.com/projects/core/datasets/customer_curated"
scenario "binding create polls" 0 "$bnd/binding_create.sh" \
  "POST${T}bindings?dataDomainBindingId=ds-customer-curated${T}200${T}{\"name\":\"$OP\",\"done\":true}"

scenario "binding 409 with the same resource succeeds" 0 "$bnd/binding_create.sh" \
  "POST${T}bindings?dataDomainBindingId${T}409${T}{}" \
  "GET${T}bindings/ds-customer-curated${T}200${T}{\"resource\":\"$RESOURCE\"}"

scenario "binding 409 with another resource fails" 1 "$bnd/binding_create.sh" \
  "POST${T}bindings?dataDomainBindingId${T}409${T}{}" \
  "GET${T}bindings/ds-customer-curated${T}200${T}{\"resource\":\"//bigquery.googleapis.com/projects/core/datasets/other\"}"

scenario "binding delete 404 succeeds" 0 "$bnd/binding_delete.sh" \
  "DELETE${T}bindings/ds-customer-curated${T}404${T}{}"

echo "$pass passed, $failed failed"
(( failed == 0 ))
