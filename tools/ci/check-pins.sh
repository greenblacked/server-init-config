#!/usr/bin/env bash
# Supply-chain hygiene for .github/workflows: every `uses:` is pinned to a full 40-hex commit SHA (local ./ actions are
# exempt) and every workflow has a top-level `permissions:` block. Run by tools/ci/lint.sh pins; read-only, no network.
# Usage: tools/ci/check-pins.sh [WORKFLOW_DIR]
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

dir="${1:-$CI_ROOT/.github/workflows}"
shopt -s nullglob
files=("$dir"/*.yml "$dir"/*.yaml)
(( ${#files[@]} > 0 )) || die "no workflow files in $dir"

for f in "${files[@]}"; do
  name="${f#"$CI_ROOT"/}"
  # uses: owner/repo[/path]@<40 hex>  (a trailing comment is fine); ./local actions and docker:// are checked separately.
  while IFS=: read -r no ref; do
    ref="${ref#"${ref%%[![:space:]]*}"}"
    value=$(sed -E 's/^-?[[:space:]]*uses:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^["'\'']//; s/["'\'']$//' <<<"$ref")
    case "$value" in
      ./*) pass "${name}:${no} local action ${value}" ;;
      docker://*@sha256:*) pass "${name}:${no} ${value}" ;;
      *@*) if [[ "${value##*@}" =~ ^[0-9a-f]{40}$ ]]; then pass "${name}:${no} ${value%%@*} pinned"; else fail "${name}:${no} '${value}' is not pinned to a 40-hex commit SHA"; fi ;;
      *) fail "${name}:${no} '${value}' has no @ref" ;;
    esac
  done < <(grep -nE '^[[:space:]]*-?[[:space:]]*uses:' "$f" || true)
  if grep -qE '^permissions:' "$f"; then pass "${name} has a top-level permissions block"; else fail "${name} has no top-level 'permissions:' block"; fi
done
finish
