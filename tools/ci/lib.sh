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
# Also hidden: the WireGuard client config together with its QR code (a scannable private key), and the plugin URLs that
# carry a Lampac device key in the path (/on/js/KEY, /online/js/KEY, /sisi/js/KEY).
# One exception, so a failing security check still says why in the public logs: a test-harness result line (PASS/FAIL/WARN, or
# ::error::/::warning::) keeps the word "password" when the WHOLE line is one fixed check phrase from tools/ci/*.sh
# (CI_SAFE_PHRASES), optionally followed by one parenthesised note, e.g. "  FAIL  sshd: password login is off" or
# "  FAIL  sshd: permitrootlogin is not prohibit-password (permitrootlogin yes)". Free text after the phrase is not allowed.
# The phrases are an explicit allow-list, not a rule: awk marks the word inside them with a control character (\001) so the
# secret rule below does not see it, and it is removed again at the end. A line that is not exactly phrase(+note) is left as it
# is, so the secret rule hides it. Also never marked: a line with a run of 32 or more base64-looking characters (a note with a run of 20+),
# one with "key:"/"key=", "user:"/"login=" credentials, or "pass:"/"passwd="/"pwd:" followed by a value.
# (The run length is counted by a loop, not a {n,} interval: old mawk, e.g. Ubuntu 22.04, treats {32,} literally.)
CI_SAFE_PHRASES='sshd: password login( still| is)? (on|off)|sshd: passwordauthentication no|[a-z0-9_.-]+ has passwordless sudo|sshd: permitrootlogin is not prohibit-password|install printed the admin web password once|no admin password in the install output|rerun replaced the password|public: wrong password is 401'
ci_redact() {
  awk -v phrases="$CI_SAFE_PHRASES" '
    function qr(s) { gsub(/\033\[[0-9;]*m/, "", s); return s ~ /^( |▀|▄|█)*$/ }
    function longrun(s, n) {
      while (match(s, /[A-Za-z0-9+\/=_-]+/)) { if (RLENGTH >= n) return 1; s = substr(s, RSTART + RLENGTH) }
      return 0
    }
    function mark(s,   lo, o, seg, note) {
      lo = tolower(s); o = ""
      if (lo ~ /key[ \t]*[:=]/ || lo ~ /(pass(wd)?|pwd)[ \t]*[:=]/) return "    [line hidden: it may hold a secret]"
      if (lo ~ /(user(name)?|login)[ \t]*[:=]/) return s
      if (lo !~ ("^[ \t]+(pass|fail|warn)[ \t]+(" phrases ")( \\([^()]*\\))?$") && lo !~ ("^::(error|warning)::(" phrases ")( \\([^()]*\\))?$")) return s
      if (match(lo, / \([^()]*\)$/) && longrun(substr(lo, RSTART), 20)) return s
      while (match(lo, phrases)) {
        seg = substr(s, RSTART, RLENGTH)
        if (substr(lo, RSTART + RLENGTH) !~ /^[ \t]*[:=]/) gsub(/[Pp][Aa][Ss][Ss]/, "&" SENT, seg)
        o = o substr(s, 1, RSTART - 1) seg; s = substr(s, RSTART + RLENGTH); lo = substr(lo, RSTART + RLENGTH)
      }
      return o s
    }
    BEGIN { SENT = sprintf("%c", 1) }
    { gsub(SENT, "") }
    st == 2 && qr($0) { next }
    { st = (st == 2 ? 0 : st) }
    st == 1 { if ($0 ~ /^PersistentKeepalive/) st = 2; next }
    /^\[Interface\]/ { st = 1; print "    [WireGuard client config and QR code hidden]"; next }
    /^[ \t]+(PASS|FAIL|WARN)[ \t]/ || /^::(error|warning)::/ { if (!longrun($0, 32)) $0 = mark($0) }
    { print }
  ' | sed -E -e 's/.*(password|token|secret|private ?key|preshared ?key).*/    [line hidden: it may hold a secret]/I' \
    -e 's#.*/(on|online|sisi)/js/.*#    [line hidden: it may hold a device key]#' | tr -d '\001'
}
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
