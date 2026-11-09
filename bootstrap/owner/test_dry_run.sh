#!/usr/bin/env bash
# Offline check of the owner scripts: a stub gcloud on PATH answers every read with "absent" and
# fails the test if a writing command runs in dry-run mode. No cloud call is made.
#
#   bash owner/test_dry_run.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud $*" >> "$STUB_LOG"
if [ -n "${STUB_SERVICE_DISABLED:-}" ] && [[ "$*" == identity* ]]; then
  echo "ERROR: PERMISSION_DENIED: Cloud Identity API has not been used in project x before or it is disabled. SERVICE_DISABLED" >&2; exit 1
fi
if [ -n "${STUB_POLICY_DENIED:-}" ] && [[ "$*" == *get-iam-policy* ]]; then
  echo "ERROR: PERMISSION_DENIED: The caller does not have permission" >&2; exit 1
fi
case "$*" in
  "config get-value account") echo "${STUB_ACCOUNT:-admin@mikegyoung.joonix.net}" ;;  # a tenant account unless set
  *" create "*|*" add "*|*"add-iam-policy-binding"*|*"versions add"*) echo "WRITE CALLED: $*" >> "$STUB_LOG"; exit 0 ;;
  *"get-iam-policy"*) echo '{"bindings":[{"role":"roles/storage.objectViewer","members":["user:someone@example.com"]},{"role":"roles/viewer","members":["serviceAccount:tf-deployer-plan@pltfrm-ngnrng.iam.gserviceaccount.com"]}]}' ;;
  *"projects describe"*"--format=json"*) echo '{"projectNumber":"123","labels":{"dda-domain":"shared"}}' ;;
  *"projects describe"*) echo "123" ;;
  *"services list"*) echo '[{"config":{"name":"storage.googleapis.com"}}]' ;;
  *"billing projects describe"*) echo '{"billingAccountName":"billingAccounts/X","billingEnabled":true}' ;;
  *) echo "ERROR: NOT_FOUND" >&2; exit 1 ;;  # describe of anything else: absent
esac
EOF
chmod +x "$TMP/gcloud"
export PATH="$TMP:$PATH" STUB_LOG="$TMP/log"
: > "$STUB_LOG"

cd "$TMP"
for s in 23_bootstrap_admins.sh 25_groups_and_service_accounts.sh 26_tokens_and_secrets.sh 27_groups_admin_sa.sh; do
  out="$(bash "$HERE/$s")"
  grep -q "mode: dry-run" <<<"$out" || { echo "FAIL $s: no dry-run banner"; exit 1; }
  echo "ok   $s prints $(grep -c '^+ ' <<<"$out" || true) planned command(s)"
done
sa_out="$(bash "$HERE/25_groups_and_service_accounts.sh")"
grep -q "customer-ingest-dev --project=kcdda-core-dwh-dev" <<<"$sa_out" \
  || { echo "FAIL: customer-ingest-dev must be in the core data project"; exit 1; }
bash "$HERE/21_estate_inventory.sh" "$TMP/inv.json" >/dev/null && jq -e '.projects | length == 5' "$TMP/inv.json" >/dev/null && echo "ok   21_estate_inventory.sh writes JSON"
bash "$HERE/22_cicd_iam_review.sh" "$TMP/iam.json" >/dev/null && jq -e '.findings | map(.member) == ["user:someone@example.com"]' "$TMP/iam.json" >/dev/null && echo "ok   22_cicd_iam_review.sh flags only the outside principal"

# MB-05: an error other than not-found (here a disabled API) must stop the script, not read as absent.
if STUB_SERVICE_DISABLED=1 bash "$HERE/23_bootstrap_admins.sh" >/dev/null 2>&1; then
  echo "FAIL: 23_bootstrap_admins.sh carried on after SERVICE_DISABLED"; exit 1
fi
echo "ok   a disabled API stops the script (MB-05)"

# MB-06: an account outside the tenant makes no group call (a lookup proves nothing for it), and
# the grants and service accounts are still planned; --groups-only stops after the groups; a
# refused policy read stops the script instead of reading as an empty policy.
out23="$(STUB_LOG="$TMP/log.outside" STUB_ACCOUNT=mikegyoung@google.com bash "$HERE/23_bootstrap_admins.sh")"
out25="$(STUB_LOG="$TMP/log.outside" STUB_ACCOUNT=mikegyoung@google.com bash "$HERE/25_groups_and_service_accounts.sh")"
if grep -q "gcloud identity" "$TMP/log.outside"; then echo "FAIL: a group call ran as an outside account"; exit 1; fi
grep -q "!! skipped: group create" <<<"$out23" && grep -q "add-iam-policy-binding" <<<"$out23" \
  || { echo "FAIL: 23 as an outside account must skip the group steps and still plan the grants"; exit 1; }
grep -q "!! skipped: the 16 groups" <<<"$out25" && grep -q "iam service-accounts create" <<<"$out25" \
  || { echo "FAIL: 25 as an outside account must skip the groups and still plan the service accounts"; exit 1; }
echo "ok   an outside caller skips the group steps and makes no group call (MB-06)"

# OD-7: with GROUPS_ADMIN_SA set, an outside account impersonates the Groups Admin SA and plans the groups.
out25_sa="$(STUB_LOG="$TMP/log.sa" STUB_ACCOUNT=mikegyoung@google.com GROUPS_ADMIN_SA=sa-builder@pltfrm-ngnrng.iam.gserviceaccount.com bash "$HERE/25_groups_and_service_accounts.sh")"
grep -q "gcloud identity groups create" <<<"$out25_sa" \
  || { echo "FAIL: 25 with GROUPS_ADMIN_SA must plan the groups"; exit 1; }
echo "ok   GROUPS_ADMIN_SA impersonates the Groups Admin SA and plans the groups (OD-7)"

STUB_LOG="$TMP/log.groups" bash "$HERE/25_groups_and_service_accounts.sh" --groups-only >/dev/null
if grep -q "iam service-accounts" "$TMP/log.groups"; then echo "FAIL: --groups-only touched service accounts"; exit 1; fi
echo "ok   --groups-only stops after the groups"

if STUB_LOG="$TMP/log.denied" STUB_POLICY_DENIED=1 bash "$HERE/23_bootstrap_admins.sh" >/dev/null 2>&1; then
  echo "FAIL: 23_bootstrap_admins.sh carried on after a refused policy read"; exit 1
fi
echo "ok   a refused policy read stops the script (MB-06)"

if grep -q "WRITE CALLED" "$TMP"/log*; then
  echo "FAIL: a writing command ran in dry-run mode:"; grep "WRITE CALLED" "$TMP"/log*; exit 1
fi
echo "PASS: no writing command ran"
