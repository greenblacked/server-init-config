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
    value=$(sed -E 's/^-?[[:space:]]*(\{[[:space:]]*)?uses:[[:space:]]*//; s/[[:space:]]+#.*$//; s/[[:space:]]*\}[[:space:]]*$//; s/,.*$//; s/^["'\'']//; s/["'\'']$//' <<<"$ref")
    case "$value" in
      ./*) pass "${name}:${no} local action ${value}" ;;
      docker://*@sha256:*) if [[ "${value##*@sha256:}" =~ ^[0-9a-f]{64}$ ]]; then pass "${name}:${no} ${value}"; else fail "${name}:${no} '${value}' has no valid 64-hex sha256 digest"; fi ;;
      *@*) if [[ "${value##*@}" =~ ^[0-9a-f]{40}$ ]]; then pass "${name}:${no} ${value%%@*} pinned"; else fail "${name}:${no} '${value}' is not pinned to a 40-hex commit SHA"; fi ;;
      *) fail "${name}:${no} '${value}' has no @ref" ;;
    esac
  done < <(grep -nE '^[[:space:]]*(-[[:space:]]*)?(\{[[:space:]]*)?uses:' "$f" || true)
  if grep -qE '^permissions:' "$f"; then pass "${name} has a top-level permissions block"; else fail "${name} has no top-level 'permissions:' block"; fi
done
# The helper image (common/lib.sh HELPER_IMAGE) is spelled out in other tracked files too: none may carry a different alpine pin.
# Only meaningful for the real tree (the default WORKFLOW_DIR); tests that point at a fixture directory skip it.
if [[ "$dir" == "$CI_ROOT/.github/workflows" ]]; then
  helper=$(sed -n 's/^HELPER_IMAGE="\(.*\)"$/\1/p' "$CI_ROOT/common/lib.sh")
  [[ "$helper" =~ ^alpine:3\.[0-9]+@sha256:[0-9a-f]{64}$ ]] || fail "common/lib.sh: HELPER_IMAGE is not an alpine:3.N@sha256:<64 hex> string"
  bad=0
  while IFS=: read -r file no found; do
    [[ "$found" == "$helper" ]] && continue
    fail "${file}:${no} alpine pin '${found}' differs from HELPER_IMAGE in common/lib.sh"; bad=1
  done < <(cd "$CI_ROOT" && git ls-files -z | xargs -0 grep -noE 'alpine:3\.[0-9]+@sha256:[0-9a-f]+' -- 2>/dev/null || true)
  (( bad == 0 )) && pass "every alpine pin in tracked files equals HELPER_IMAGE"
fi
finish
