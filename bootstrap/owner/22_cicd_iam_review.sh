#!/usr/bin/env bash
# Task 2.2: read-only IAM review of the CI/CD project. Flags every principal outside the DDA
# that holds a project-wide role with Cloud Storage object read (the state bucket) or Artifact
# Registry read (dda-ci, dda-control-plane, dda-pipelines). Changes nothing.
#
#   bash owner/22_cicd_iam_review.sh [output.json]
#
# Each finding is a residual risk to log in docs/registers/defect_register.md (task 2.2), or a
# note that none exist. Custom roles are listed for manual review.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require gcloud jq

OUT="${1:-cicd-iam-review-$(date +%F).json}"
echo "== read-only IAM review of ${CICD_PROJECT}; output ${OUT}"

# Predefined roles that include storage.objects.get or Artifact Registry download project-wide.
STORAGE_READ='["roles/owner","roles/editor","roles/storage.admin","roles/storage.objectAdmin","roles/storage.objectViewer","roles/storage.objectUser","roles/storage.legacyObjectReader","roles/storage.legacyObjectOwner","roles/storage.legacyBucketOwner","roles/storage.folderAdmin"]'
AR_READ='["roles/owner","roles/editor","roles/viewer","roles/artifactregistry.admin","roles/artifactregistry.repoAdmin","roles/artifactregistry.writer","roles/artifactregistry.reader","roles/artifactregistry.createOnPushWriter","roles/artifactregistry.createOnPushRepoAdmin"]'

# Principals that belong to the DDA (expected).
DDA_PRINCIPALS="$(jq -n --arg p "$CICD_PROJECT" --arg g "$BOOTSTRAP_GROUP" '[
  "serviceAccount:tf-deployer@\($p).iam.gserviceaccount.com",
  "serviceAccount:tf-deployer-plan@\($p).iam.gserviceaccount.com",
  "group:\($g)"]')"

policy="$(gcloud projects get-iam-policy "$CICD_PROJECT" --format=json)"
number="$(gcloud projects describe "$CICD_PROJECT" --format='value(projectNumber)')"

jq --argjson storage "$STORAGE_READ" --argjson ar "$AR_READ" --argjson dda "$DDA_PRINCIPALS" \
   --arg number "$number" --arg at "$(date -u +%FT%TZ)" --arg project "$CICD_PROJECT" '
  # Google-managed service agents of this project (service-<number>@..., <number>@cloudservices...).
  def agent: test("^serviceAccount:(service-)?" + $number + "@");
  [ .bindings[]? as $b | $b.members[] as $m
    | select(($dda | index($m)) | not)
    | {member: $m, role: $b.role, conditional: ($b.condition != null),
       storage_read: ($storage | index($b.role) != null),
       artifact_registry_read: ($ar | index($b.role) != null),
       custom_role: ($b.role | startswith("projects/") or startswith("organizations/")),
       google_service_agent: ($m | agent)} ]
  | {generated_at: $at, project: $project,
     findings: [ .[] | select((.storage_read or .artifact_registry_read) and (.google_service_agent | not)) ],
     custom_roles_to_review: [ .[] | select(.custom_role) ],
     service_agents_with_read: [ .[] | select((.storage_read or .artifact_registry_read) and .google_service_agent) ]}
' <<<"$policy" > "$OUT"

echo "== findings (principals outside the DDA with project-wide storage or Artifact Registry read):"
jq -r '.findings[] | "   \(.member)  \(.role)\(if .conditional then " (conditional)" else "" end)"' "$OUT"
echo "== custom roles to review: $(jq '.custom_roles_to_review | length' "$OUT")"
echo "== wrote ${OUT}"
