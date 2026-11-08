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
case "$*" in
  *" create "*|*" add "*|*"add-iam-policy-binding"*|*"versions add"*) echo "WRITE CALLED: $*" >> "$STUB_LOG"; exit 0 ;;
  *"get-iam-policy"*) echo '{"bindings":[{"role":"roles/storage.objectViewer","members":["user:someone@example.com"]},{"role":"roles/viewer","members":["serviceAccount:tf-deployer-plan@pltfrm-ngnrng.iam.gserviceaccount.com"]}]}' ;;
  *"projects describe"*"--format=json"*) echo '{"projectNumber":"123","labels":{"dda-domain":"shared"}}' ;;
  *"projects describe"*) echo "123" ;;
  *"services list"*) echo '[{"config":{"name":"storage.googleapis.com"}}]' ;;
  *"billing projects describe"*) echo '{"billingAccountName":"billingAccounts/X","billingEnabled":true}' ;;
  *) exit 1 ;;  # describe of anything else: absent
esac
EOF
chmod +x "$TMP/gcloud"
export PATH="$TMP:$PATH" STUB_LOG="$TMP/log"
: > "$STUB_LOG"

cd "$TMP"
for s in 23_bootstrap_admins.sh 25_groups_and_service_accounts.sh 26_tokens_and_secrets.sh; do
  out="$(bash "$HERE/$s")"
  grep -q "mode: dry-run" <<<"$out" || { echo "FAIL $s: no dry-run banner"; exit 1; }
  echo "ok   $s prints $(grep -c '^+ ' <<<"$out" || true) planned command(s)"
done
sa_out="$(bash "$HERE/25_groups_and_service_accounts.sh")"
grep -q "customer-ingest-dev --project=kcdda-core-dwh-dev" <<<"$sa_out" \
  || { echo "FAIL: customer-ingest-dev must be in the core data project"; exit 1; }
bash "$HERE/21_estate_inventory.sh" "$TMP/inv.json" >/dev/null && jq -e '.projects | length == 5' "$TMP/inv.json" >/dev/null && echo "ok   21_estate_inventory.sh writes JSON"
bash "$HERE/22_cicd_iam_review.sh" "$TMP/iam.json" >/dev/null && jq -e '.findings | map(.member) == ["user:someone@example.com"]' "$TMP/iam.json" >/dev/null && echo "ok   22_cicd_iam_review.sh flags only the outside principal"

if grep -q "WRITE CALLED" "$STUB_LOG"; then
  echo "FAIL: a writing command ran in dry-run mode:"; grep "WRITE CALLED" "$STUB_LOG"; exit 1
fi
echo "PASS: no writing command ran"
