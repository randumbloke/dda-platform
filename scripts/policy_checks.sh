#!/usr/bin/env bash
# Static policy checks of design sections 6.3 and 6.15.3, run by ci-checks.
#   - IAM ownership: no *_iam_policy / *_iam_binding, no google_bigquery_{dataset,table}_iam_*,
#     no google_cloud_identity_group_membership outside bootstrap/.
#   - Dataset access: every google_bigquery_dataset has an access block and ignores access.
#   - projectReaders: no special_group = "projectReaders" (VA-90).
#   - Local execution: no local-exec, external or http data source outside
#     modules/data_domain_shim/.
#   - Lock files: every root module has a committed .terraform.lock.hcl; provider pins match
#     section 6.11 / contracts (google, google-beta exactly 8.10.0; http ~> 3.6).
#   - Workflows: no id-token: write, no Google Cloud authentication action.
#   - The two copies of the shim's lib.sh are identical.
# Usage: scripts/policy_checks.sh [repo-root]
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$root"
fail=0
report() { echo "FAIL $*"; fail=1; }

# All Terraform files except working directories.
tf_files=()
while IFS= read -r f; do tf_files+=("$f"); done < <(find . -name '*.tf' -not -path '*/.terraform/*' | LC_ALL=C sort)

# IAM ownership (section 6.15.3).
for f in "${tf_files[@]}"; do
  if grep -nE '^\s*resource\s+"google_[a-z0-9_]+_iam_(policy|binding)"' "$f" >/dev/null; then
    report "$f: authoritative *_iam_policy or *_iam_binding resource (section 6.15.3)"
  fi
  if grep -nE '^\s*resource\s+"google_bigquery_(dataset|table)_iam_' "$f" >/dev/null; then
    report "$f: google_bigquery_dataset_iam_* / google_bigquery_table_iam_* (section 6.15.2)"
  fi
  if [[ "$f" != ./bootstrap/* ]] && grep -nE '^\s*resource\s+"google_cloud_identity_group_membership"' "$f" >/dev/null; then
    report "$f: google_cloud_identity_group_membership outside bootstrap/ (section 6.15.1)"
  fi
  if grep -nE 'special_group\s*=\s*"projectReaders"' "$f" >/dev/null; then
    report "$f: projectReaders special group (VA-90)"
  fi
  if [[ "$f" != ./modules/data_domain_shim/* ]]; then
    if grep -nE '"local-exec"|^\s*data\s+"(external|http)"' "$f" >/dev/null; then
      report "$f: local-exec, external or http data source outside modules/data_domain_shim/ (section 2.3.2)"
    fi
  fi
done

# Dataset access pattern (section 6.15.2): each google_bigquery_dataset block has `access {` and
# `ignore_changes` naming access.
for f in "${tf_files[@]}"; do
  awk -v file="$f" '
    /^[[:space:]]*resource[[:space:]]+"google_bigquery_dataset"[[:space:]]/ { inres=1; depth=0; access=0; ignore=0; name=$3 }
    inres {
      line=$0
      if (line ~ /^[[:space:]]*access[[:space:]]*\{/) access=1
      if (line ~ /ignore_changes[[:space:]]*=.*access/) ignore=1
      n=gsub(/\{/, "{", line); m=gsub(/\}/, "}", line); depth+=n-m
      if (depth==0 && n+m>0) {
        if (!access || !ignore) { printf "FAIL %s: google_bigquery_dataset %s needs an access list and lifecycle ignore_changes = [access] (section 6.15.2)\n", file, name; bad=1 }
        inres=0
      }
    }
    END { exit bad }
  ' "$f" || fail=1
done

# Lock files and provider pins (section 6.11; contracts section 6).
roots=()
while IFS= read -r d; do roots+=("$d"); done < <(find bootstrap tiers envs -name 'backend.tf' -not -path '*/.terraform/*' -exec dirname {} \; 2>/dev/null | LC_ALL=C sort)
for r in ${roots[@]+"${roots[@]}"}; do
  [[ -f "$r/.terraform.lock.hcl" ]] || report "$r: no committed .terraform.lock.hcl (section 6.11)"
done
for f in "${tf_files[@]}"; do
  # Inside a required_providers entry for google / google-beta the version must be ~> 8.10 (design §6.11).
  awk -v file="$f" '
    /^[[:space:]]*(google|google-beta)[[:space:]]*=[[:space:]]*\{/ { inp=1; next }
    /^[[:space:]]*http[[:space:]]*=[[:space:]]*\{/ { inh=1; next }
    inp && /version/ { if ($0 !~ /"~> 8\.10"/) { printf "FAIL %s: google provider pin must be ~> 8.10: %s\n", file, $0; bad=1 } inp=0 }
    inh && /version/ { if ($0 !~ /"~> 3\.6"/) { printf "FAIL %s: http provider pin must be ~> 3.6: %s\n", file, $0; bad=1 } inh=0 }
    /^[[:space:]]*\}/ { inp=0; inh=0 }
    /required_version/ { if ($0 !~ /">= 1\.17"/) { printf "FAIL %s: required_version must be >= 1.17: %s\n", file, $0; bad=1 } }
    END { exit bad }
  ' "$f" || fail=1
done

# Workflows (section 6.3).
if [[ -d .github/workflows ]]; then
  if grep -rnE 'id-token:\s*write' .github/workflows >/dev/null; then
    report ".github/workflows: id-token: write is not allowed"
  fi
  if grep -rnE 'google-github-actions/(auth|setup-gcloud)' .github/workflows >/dev/null; then
    report ".github/workflows: Google Cloud authentication actions are not allowed"
  fi
  if grep -rnE 'uses:\s*[^@[:space:]]+@' .github/workflows | grep -vE 'uses:\s*[^@[:space:]]+@[0-9a-f]{40}' >/dev/null; then
    report ".github/workflows: third-party actions must be pinned by full commit SHA"
  fi
fi

# The shim's helper library is duplicated per submodule; the copies must match.
if ! cmp -s modules/data_domain_shim/domain/scripts/lib.sh modules/data_domain_shim/binding/scripts/lib.sh; then
  report "modules/data_domain_shim/*/scripts/lib.sh copies differ"
fi

[[ $fail -eq 0 ]] && echo "ok   policy checks"
exit "$fail"
