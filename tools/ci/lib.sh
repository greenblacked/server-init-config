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
