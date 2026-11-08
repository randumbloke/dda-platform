#!/usr/bin/env bash
# Asserts that the installed Terraform matches the pin (design §6.11; contracts README §6).
# Usage: check-terraform-version [expected]   (default: $TERRAFORM_VERSION, else 1.16.3)
set -euo pipefail

expected="${1:-${TERRAFORM_VERSION:-1.16.3}}"

if ! command -v terraform >/dev/null 2>&1; then
  echo "terraform not found on PATH" >&2
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  actual="$(terraform version -json | jq -r '.terraform_version')"
else
  actual="$(terraform version | head -n 1 | sed -E 's/^Terraform v//')"
fi

if [ "${actual}" != "${expected}" ]; then
  echo "terraform version mismatch: expected ${expected}, found ${actual}" >&2
  exit 1
fi
echo "terraform ${actual} matches the pin"
