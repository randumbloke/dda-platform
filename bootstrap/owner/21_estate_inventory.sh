#!/usr/bin/env bash
# Task 2.1: read-only estate inventory of the five DDA projects (projects, numbers, labels,
# billing link, enabled APIs, owners) as JSON. Changes nothing.
#
#   bash owner/21_estate_inventory.sh [output.json]
#
# Default output: ./estate-inventory-<YYYY-MM-DD>.json (keep it in cdmc_kc scratch/, task 2.1).
# Verify: every project shows its P1-7 labels (hub: dda-domain, dda-tier; CI/CD: dda-domain;
# data: dda-domain, dda-env); the script prints a label check per project.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require gcloud jq

OUT="${1:-estate-inventory-$(date +%F).json}"
echo "== read-only inventory of: ${DDA_PROJECTS[*]}"
echo "== output: ${OUT}"

required_labels() {
  case "$1" in
    "$HUB_PROJECT") echo "dda-domain dda-tier" ;;
    "$CICD_PROJECT") echo "dda-domain" ;;
    *) echo "dda-domain dda-env" ;;
  esac
}

items=()
for p in "${DDA_PROJECTS[@]}"; do
  echo "-- ${p}"
  project_json="$(gcloud projects describe "$p" --format=json 2>/dev/null || echo '{}')"
  billing_json="$(gcloud billing projects describe "$p" --format=json 2>/dev/null || echo '{}')"
  services_json="$(gcloud services list --enabled --project="$p" --format='json(config.name)' 2>/dev/null | jq '[.[].config.name] | sort' || echo '[]')"
  policy_json="$(gcloud projects get-iam-policy "$p" --format=json 2>/dev/null || echo '{}')"
  owners_json="$(jq '[.bindings[]? | select(.role == "roles/owner") | .members[]] | sort' <<<"$policy_json")"

  missing=()
  for l in $(required_labels "$p"); do
    jq -e --arg l "$l" '.labels[$l] // empty' <<<"$project_json" >/dev/null || missing+=("$l")
  done
  if [ ${#missing[@]} -eq 0 ]; then echo "   labels OK"; else echo "   MISSING labels: ${missing[*]}"; fi

  items+=("$(jq -n \
    --arg id "$p" \
    --argjson project "$project_json" \
    --argjson billing "$billing_json" \
    --argjson services "$services_json" \
    --argjson owners "$owners_json" \
    --arg missing "${missing[*]:-}" \
    '{project_id: $id, project_number: $project.projectNumber, lifecycle_state: $project.lifecycleState,
      parent: $project.parent, labels: ($project.labels // {}),
      billing_account: $billing.billingAccountName, billing_enabled: $billing.billingEnabled,
      enabled_services: $services, owners: $owners,
      missing_labels: ($missing | split(" ") | map(select(. != "")))}')")
done

printf '%s\n' "${items[@]}" | jq -s --arg at "$(date -u +%FT%TZ)" --arg org "$ORG_ID" \
  '{generated_at: $at, organization_id: $org, projects: .}' > "$OUT"
echo "== wrote ${OUT}"
