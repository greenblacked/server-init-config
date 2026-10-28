#!/usr/bin/env bash
# Pre-pull every tag of the CI images listed in /etc/ci-prewarm.conf so jobs start from local images.
set -Eeuo pipefail

CONF="${CONF:-/etc/ci-prewarm.conf}"
log() { logger -t ci-image-prewarm -- "$*"; echo "$(date +%FT%T) $*"; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0  (pulls all tags of REPOS under BASE from $CONF)"
  exit 0
fi
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
command -v crane >/dev/null 2>&1 || { log "ERROR: crane not installed"; exit 1; }
[[ -f "$CONF" ]] || { log "ERROR: $CONF not found"; exit 1; }

BASE=""
REPOS=()
# shellcheck disable=SC1090
source "$CONF"
[[ -n "$BASE" && ${#REPOS[@]} -gt 0 ]] || { log "ERROR: BASE or REPOS empty in $CONF"; exit 1; }

exec 9>/run/ci-image-prewarm.lock
flock -n 9 || { log "another prewarm is running, exit"; exit 0; }

ok=0; noarm=0; fail=0
for repo in "${REPOS[@]}"; do
  if ! tags=$(crane ls "${BASE}/${repo}" 2>&1); then
    log "FAIL    ${BASE}/${repo}: cannot list tags: ${tags}"
    fail=$((fail + 1))
    continue
  fi
  for tag in $tags; do
    ref="${BASE}/${repo}:${tag}"
    if out=$(docker pull -q "$ref" 2>&1); then
      log "OK      $ref"
      ok=$((ok + 1))
    elif grep -qiE 'no matching manifest|does not match the specified platform' <<<"$out"; then
      log "NO ARM  $ref"
      noarm=$((noarm + 1))
    else
      log "FAIL    $ref: $out"
      fail=$((fail + 1))
    fi
  done
done

log "summary: ok=${ok} no_arm=${noarm} failed=${fail}, disk: $(df -h --output=pcent / | tail -1 | xargs)"
(( fail == 0 ))
