#!/usr/bin/env bash
# Root-module comparison (design sections 6.1, 6.3, 6.13): the .tf files of one stack must be
# identical between any two environments (envs/<env>/[<stack>/]) and between the tiers
# (tiers/<tier>/). Only <env|tier>.tfvars, state.config and .terraform.lock.hcl may differ.
#
# Usage: scripts/compare_roots.sh [repo-root]   (exit 1 on any difference)
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$root"

fail=0

# list_tf DIR: sorted names of the .tf files directly in DIR.
list_tf() { find "$1" -maxdepth 1 -type f -name '*.tf' -exec basename {} \; | LC_ALL=C sort; }

# compare_group LABEL DIR...: every DIR must hold the same .tf file names with identical content.
compare_group() {
  local label="$1"; shift
  local dirs=("$@")
  if (( ${#dirs[@]} < 2 )); then
    echo "ok   $label: ${#dirs[@]} root module(s), nothing to compare"
    return 0
  fi
  local ref="${dirs[0]}" d f
  for d in "${dirs[@]:1}"; do
    if ! diff <(list_tf "$ref") <(list_tf "$d") >/dev/null; then
      echo "FAIL $label: $ref and $d declare different .tf files:"
      diff <(list_tf "$ref") <(list_tf "$d") | sed 's/^/       /' || true
      fail=1
      continue
    fi
    while IFS= read -r f; do
      if ! cmp -s "$ref/$f" "$d/$f"; then
        echo "FAIL $label: $ref/$f and $d/$f differ (only .tfvars and state.config may differ)"
        diff -u "$ref/$f" "$d/$f" | head -40 | sed 's/^/       /' || true
        fail=1
      fi
    done < <(list_tf "$ref")
  done
  [[ $fail -eq 0 ]] && echo "ok   $label: ${dirs[*]}"
  return 0
}

# Tiers.
if [[ -d tiers ]]; then
  tier_dirs=()
  while IFS= read -r d; do tier_dirs+=("$d"); done < <(find tiers -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)
  compare_group "tiers" "${tier_dirs[@]}"
fi

# Environments: a stack is either the environment directory itself (it holds .tf files), named
# ".", or each subdirectory of it holding .tf files (envs/<env>/<stack>/).
if [[ -d envs ]]; then
  env_dirs=()
  while IFS= read -r d; do env_dirs+=("$d"); done < <(find envs -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort)

  stack_names=()
  for e in "${env_dirs[@]}"; do
    [[ -n "$(list_tf "$e")" ]] && stack_names+=(".")
    while IFS= read -r s; do
      [[ -n "$(list_tf "$s")" ]] && stack_names+=("$(basename "$s")")
    done < <(find "$e" -mindepth 1 -maxdepth 1 -type d ! -name '.terraform' | LC_ALL=C sort)
  done

  if (( ${#stack_names[@]} > 0 )); then
    while IFS= read -r s; do
      group=()
      for e in "${env_dirs[@]}"; do
        if [[ "$s" == "." ]]; then d="$e"; else d="$e/$s"; fi
        [[ -d "$d" && -n "$(list_tf "$d")" ]] && group+=("$d")
      done
      compare_group "envs stack '$s'" "${group[@]}"
      if (( ${#group[@]} != ${#env_dirs[@]} )); then
        echo "FAIL envs stack '$s' exists in ${#group[@]} of ${#env_dirs[@]} environments"
        fail=1
      fi
    done < <(printf '%s\n' "${stack_names[@]}" | LC_ALL=C sort -u)
  fi
fi

exit "$fail"
