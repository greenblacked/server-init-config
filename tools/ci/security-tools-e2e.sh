#!/usr/bin/env bash
# common/security-tools.sh for real (real downloads, real distro mirrors).
#   tools/ci/security-tools-e2e.sh scan             on THIS machine (root): --scan, SHA-256 verified release binaries; each binary
#                                                  must run and report the pinned version. Works on x86_64 and aarch64.
#   tools/ci/security-tools-e2e.sh pkgs IMAGE       in a throwaway container of IMAGE: --audit --network with the distro's own
#                                                  mirrors (EPEL and CRB on EL); the package names must resolve.
# "scan" installs into /usr/local/bin and /var/lib/security-tools: CI runner only (or ALLOW_LOCAL=1 on a VM).
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$CI_ROOT"
MODE="${1:-}"
SCRIPT=common/security-tools.sh

pinned() { sed -n "s/^: \"\${$1:=\\([^}]*\\)}\"\$/\\1/p" "$CI_ROOT/$SCRIPT" | head -1; }

scan() {
  [[ $EUID -eq 0 ]] || die "run as root (sudo)"
  in_ci || [[ "${ALLOW_LOCAL:-0}" == 1 ]] || die "this installs into /usr/local/bin: set ALLOW_LOCAL=1 on a disposable machine"
  local W
  W="$CI_OUT/security-scan-$(uname -m)"; mkdir -p "$W"
  log "arch $(uname -m)"
  bash "$SCRIPT" --scan 2>&1 | tee "$W/scan.log" | tail -25
  [[ "${PIPESTATUS[0]}" -eq 0 ]] && pass "security-tools.sh --scan exit 0 (every download passed its SHA-256 check or the script would have refused)" || fail "security-tools.sh --scan failed"
  grep -qi 'CHECKSUM MISMATCH' "$W/scan.log" && fail "a checksum mismatch was reported" || pass "no checksum mismatch"
  if grep -q 'skipped (' "$W/scan.log"; then fail "tools were skipped: $(grep -m1 'skipped (' "$W/scan.log")"; else pass "no tool skipped (all downloaded on $(uname -m))"; fi
  # tool -> pinned variable -> command that prints the version
  local spec name var cmd ver out
  for spec in "trivy:TRIVY_VERSION:trivy --version" "gitleaks:GITLEAKS_VERSION:gitleaks version" "hadolint:HADOLINT_VERSION:hadolint --version" \
              "cosign:COSIGN_VERSION:cosign version" "osv-scanner:OSV_SCANNER_VERSION:osv-scanner --version" \
              "trufflehog:TRUFFLEHOG_VERSION:trufflehog --version" "dockle:DOCKLE_VERSION:dockle --version"; do
    name="${spec%%:*}"; spec="${spec#*:}"; var="${spec%%:*}"; cmd="${spec#*:}"
    ver=$(pinned "$var")
    [[ -n "$ver" ]] || { fail "$name: cannot read $var from $SCRIPT"; continue; }
    if out=$($cmd 2>&1); then
      if grep -q -- "$ver" <<<"$out"; then pass "$name runs and reports ${ver}"; else fail "$name runs but its version output lacks ${ver}: $(head -2 <<<"$out" | tr '\n' ' ')"; fi
    else
      fail "$name does not run on $(uname -m): $(head -2 <<<"$out" | tr '\n' ' ')"
    fi
    file "/usr/local/bin/$name" 2>/dev/null | sed 's/^/      /' || true
  done
  echo "-- rerun is a no-op (version markers)"
  bash "$SCRIPT" --scan > "$W/scan-2.log" 2>&1 && pass "second run exit 0" || fail "second run failed"
  grep -q 'installed now (0)' "$W/scan-2.log" && pass "second run installed nothing" || fail "second run reinstalled: $(grep 'installed now' "$W/scan-2.log")"
  # Not a checksum-mismatch test (the script has no URL override to serve a tampered asset); the real checksum comparison is
  # exercised by every download above. This only checks that a version without a release is skipped and replaces nothing.
  echo "-- an unknown version is skipped and the installed binary is left alone"
  rm -f /var/lib/security-tools/gitleaks.version
  GITLEAKS_VERSION=0.0.1 bash "$SCRIPT" --scan > "$W/scan-bad.log" 2>&1 || true
  [[ "$(gitleaks version 2>&1 | head -1)" == *"$(pinned GITLEAKS_VERSION)"* ]] && pass "the working gitleaks binary was not replaced" || fail "gitleaks changed after the unknown-version run: $(gitleaks version 2>&1 | head -1)"
}

pkgs() {
  local image="${1:?image}" slug W
  slug=$(tr -c 'A-Za-z0-9\n' '_' <<<"$image"); W="$CI_OUT/security-pkgs-${slug}"; mkdir -p "$W"
  need docker || die "docker is required"
  # Required: tools the README promises on every OS. Optional: extras that EPEL or a release may lack; reported, not fatal.
  local required="nmap tcpdump socat whois dig lsof traceroute lynis ssh-audit testssl auditctl" optional="tshark iperf3 mtr iftop nethogs bmon ncat"
  case "$image" in *rocky* | *fedora* | *alma* | *centos*) required+=" oscap" ;; esac
  log "== $image: --audit --network"
  docker run --rm -v "$CI_ROOT:/repo:ro" -e CI_REQUIRED="$required" -e CI_OPTIONAL="$optional" "$image" bash -c '
    set -u
    # minimal images lack curl/ca-certificates for the git checkout of testssl and for pip; the script installs what it needs
    cd /repo && bash common/security-tools.sh --audit --network; rc=$?
    echo "SCRIPT_EXIT=$rc"
    for c in $CI_REQUIRED; do if command -v "$c" >/dev/null 2>&1; then echo "HAVE_REQ $c"; else echo "MISSING_REQ $c"; fi; done
    for c in $CI_OPTIONAL; do if command -v "$c" >/dev/null 2>&1; then echo "HAVE_OPT $c"; else echo "MISSING_OPT $c"; fi; done
    . /etc/os-release; echo "OSID=$ID"
    if command -v dnf >/dev/null 2>&1; then dnf repolist 2>/dev/null | sed "s/^/REPO /"; fi
    lynis --version 2>&1 | head -1 | sed "s/^/LYNIS /"; ssh-audit --help 2>&1 | head -1 | sed "s/^/SSHAUDIT /"; testssl --version 2>&1 | head -3 | sed "s/^/TESTSSL /"
  ' 2>&1 | tee "$W/run.log" | grep -vE '^(HAVE_|REPO |LYNIS |SSHAUDIT |TESTSSL )' | tail -30
  grep -q '^SCRIPT_EXIT=0' "$W/run.log" && pass "$image: security-tools.sh exit 0" || fail "$image: security-tools.sh exit code: $(grep SCRIPT_EXIT "$W/run.log")"
  local m
  for m in $(sed -n 's/^MISSING_REQ //p' "$W/run.log"); do fail "$image: required tool missing: $m"; done
  [[ -z "$(sed -n 's/^MISSING_REQ //p' "$W/run.log")" ]] && pass "$image: all required tools present ($required)"
  for m in $(sed -n 's/^MISSING_OPT //p' "$W/run.log"); do warn "$image: optional tool not installed: $m (package not on this release/mirror)"; done
  grep -m1 'not available on this release' "$W/run.log" | sed 's/^/      /' || true
  case "$image" in
    *rocky* | *alma* | *centos*)
      grep -qi '^REPO .*epel' "$W/run.log" && pass "$image: EPEL enabled" || fail "$image: EPEL is not enabled"
      grep -qiE '^REPO .*(crb|codeready|powertools)' "$W/run.log" && pass "$image: CRB enabled" || fail "$image: CRB is not enabled" ;;
  esac
}

case "$MODE" in
  scan) scan ;;
  pkgs) pkgs "${2:-}" ;;
  *) die "usage: $0 scan | pkgs IMAGE" ;;
esac
finish
