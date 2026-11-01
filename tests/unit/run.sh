#!/usr/bin/env bash
# Plain-bash unit test runner (no dependencies). Usage: tests/unit/run.sh [FILE.test.sh ...]   (default: all)
# Why not bats-core: a pinned release needs a SHA-256 taken from the real tarball, and that download was not possible when
# this was written. A hash that was never checked would defeat the pin, so nothing is vendored. The test files are plain
# bash functions named test_*, so porting them to bats later is mechanical.
# Each test runs in its own subshell with its own empty directory in $T (under a private temp dir, removed at the end).
# Nothing here touches the real system: tests write only below $T.
# In a test file: assert_eq GOT WANT [DESC], assert_ok DESC CMD..., assert_fail DESC CMD...; a failing assert fails the test.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
export REPO

# Child mode: run one test in a fresh process, so that `set -e` really applies (it is ignored inside a subshell that is
# the left side of `||`, which would let a failing assert in the middle of a test go unnoticed).
if [[ "${1:-}" == --one ]]; then
  # shellcheck disable=SC1090
  source "$2"
  "$3"
  exit 0
fi

UNIT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/unit.XXXXXX")
trap 'rm -rf "$UNIT_TMP"' EXIT
export UNIT_TMP

assert_eq() { # assert_eq GOT WANT [DESC]
  if [[ "$1" != "$2" ]]; then echo "    assert_eq failed${3:+ ($3)}: got '$1', want '$2'" >&2; return 1; fi
}
assert_ok() { local d=$1; shift; "$@" || { echo "    expected success: $d" >&2; return 1; }; }
assert_fail() { local d=$1; shift; if "$@"; then echo "    expected failure: $d" >&2; return 1; fi; }
export -f assert_eq assert_ok assert_fail

pass=0 failed=0
files=("$@")
[[ ${#files[@]} -gt 0 ]] || files=("$HERE"/*.test.sh)

for file in "${files[@]}"; do
  echo "== ${file#"$REPO"/}"
  mapfile -t tests < <(grep -oE '^test_[A-Za-z0-9_]+' "$file" | sort -u)
  for t in "${tests[@]}"; do
    T="$UNIT_TMP/${t}"; mkdir -p "$T"; export T
    rc=0
    "$BASH" "${BASH_SOURCE[0]}" --one "$file" "$t" > "$T.out" 2>&1 || rc=$?
    if (( rc == 0 )); then pass=$((pass + 1)); echo "  ok    $t"
    else failed=$((failed + 1)); echo "  FAIL  $t (exit $rc)"; sed 's/^/    | /' "$T.out"; fi
  done
done
echo "== ${pass} passed, ${failed} failed"
[[ $failed -eq 0 ]]
