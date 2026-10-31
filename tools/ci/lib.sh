#!/usr/bin/env bash
# Shared helpers for tools/ci/*.sh. Sourced, not executed. Every script here also runs on a laptop with Docker.
# shellcheck shell=bash

CI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="$PATH:/usr/sbin:/sbin"
export CI_ROOT
# Logs and artifacts go here (the workflows upload it on failure). Override with CI_OUT.
CI_OUT="${CI_OUT:-${CI_ROOT}/ci-out}"
export CI_OUT
mkdir -p "$CI_OUT"

FAILS=0
PASSES=0

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
# GitHub shows ::group:: lines as folds and ::error:: as annotations; elsewhere they are plain text.
group() { echo "::group::$*"; }
endgroup() { echo "::endgroup::"; }
pass() { PASSES=$((PASSES + 1)); echo "  PASS  $*"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL  $*"; echo "::error::$*" 2>/dev/null || true; }
warn() { echo "  WARN  $*"; echo "::warning::$*" 2>/dev/null || true; }
# check "description" command...   (command run directly, no eval)
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
# expect_eq "description" got want
expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1 ($2)"; else fail "$1 (got '$2', want '$3')"; fi; }
# expect_match "description" got regex
expect_match() { if [[ "$2" =~ $3 ]]; then pass "$1 ($2)"; else fail "$1 (got '$2', want /$3/)"; fi; }
# Secrets. The repo is public, so are its CI logs. ci_mask makes GitHub hide a value in everything printed after this call;
# ci_redact hides whole lines that look like credentials (for output that is shown or kept as an artifact, which is not masked).
ci_mask() {
  local v
  for v in "$@"; do
    if [[ -n "$v" && "${GITHUB_ACTIONS:-}" == true ]]; then echo "::add-mask::$v"; fi
  done
  return 0
}
ci_redact() { sed -E 's/.*(password|token|secret|private ?key|preshared ?key).*/    [line hidden: it may hold a secret]/I'; }
ci_redact_file() { local t; t=$(mktemp); ci_redact < "$1" > "$t" && cat "$t" > "$1"; rm -f "$t"; }
# ci_run LOG TAIL_LINES cmd...   runs cmd; the raw output (it may hold generated passwords) stays in a private temp file
# (path in CI_RAW, removed unless CI_KEEP_RAW=1, then the caller removes it); LOG and the console only get the redacted view. Returns cmd's exit code.
ci_run() {
  local log=$1 n=$2 rc=0; shift 2
  CI_RAW=$(mktemp "${TMPDIR:-/tmp}/ci-raw.XXXXXX")
  "$@" > "$CI_RAW" 2>&1 || rc=$?
  ci_redact < "$CI_RAW" > "$log"
  if (( n > 0 )); then tail -n "$n" "$log"; fi
  if [[ -z "${CI_KEEP_RAW:-}" ]]; then rm -f "$CI_RAW"; fi
  return "$rc"
}
finish() {
  echo "== ${PASSES} passed, ${FAILS} failed"
  [[ $FAILS -eq 0 ]]
}
in_ci() { [[ "${GITHUB_ACTIONS:-}" == true || "${CI:-}" == true ]]; }
need() { command -v "$1" >/dev/null 2>&1; }
# Locally a missing tool is skipped with a note; in CI it is an error (a silent skip would hide a broken job).
need_or_skip() {
  if need "$1"; then return 0; fi
  if in_ci; then die "$1 is not installed"; fi
  warn "$1 not installed, skipped (CI installs it)"
  return 1
}
# sudo only when not root (runners are not root, sandbox containers are).
export SUDO=""
if [[ $EUID -ne 0 ]]; then SUDO="sudo"; fi
