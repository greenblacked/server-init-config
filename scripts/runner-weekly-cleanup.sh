#!/usr/bin/env bash
# Weekly cleanup of the GitLab Runner host: Docker, runner caches, packages, logs, temp files.
set -Eeuo pipefail

RETENTION_DAYS="${RETENTION_DAYS:-7}"
JOURNAL_MAX="${JOURNAL_MAX:-500M}"
SHARED_CACHE_DIR="${SHARED_CACHE_DIR:-/srv/ci-cache}"
SHARED_CACHE_MAX_AGE_DAYS="${SHARED_CACHE_MAX_AGE_DAYS:-14}"
DRY_RUN="${DRY_RUN:-0}"

CACHE_DIRS=(/home/gitlab-runner/cache /home/gitlab-runner/.cache /var/lib/gitlab-runner/cache /root/.cache)
BUILD_DIRS=(/home/gitlab-runner/builds /var/lib/gitlab-runner/builds)

log()  { logger -t runner-weekly-cleanup -- "$*"; echo "$(date -u +%FT%TZ) $*"; }
disk() { df --output=used,avail,pcent -h / | tail -1 | xargs; }

run() {
  log "-> $*"
  [[ "$DRY_RUN" == "1" ]] && return 0
  "$@" || log "WARN: failed: $*"
}

wipe_dir() {
  local dir="$1" age="${2:-}"
  [[ -d "$dir" ]] || return 0
  if [[ -n "$age" ]]; then
    log "-> cleaning $dir older than ${age}d"
    [[ "$DRY_RUN" == "1" ]] && return 0
    find "$dir" -mindepth 1 -mtime +"$age" -delete 2>/dev/null || log "WARN: partial cleanup of $dir"
  else
    log "-> wiping $dir"
    [[ "$DRY_RUN" == "1" ]] && return 0
    find "$dir" -mindepth 1 -delete 2>/dev/null || log "WARN: partial wipe of $dir"
  fi
}

usage() {
  cat <<USAGE
Usage: $0 [--help]
Env:
  RETENTION_DAYS              keep images, builds and temp files newer than N days (default: 7)
  JOURNAL_MAX                 max systemd journal size (default: 500M)
  SHARED_CACHE_DIR            shared CI cache directory (default: /srv/ci-cache)
  SHARED_CACHE_MAX_AGE_DAYS   prune shared cache files not accessed for N days (default: 14)
  DRY_RUN=1                   show what would be cleaned without deleting anything
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

exec 9>/run/runner-weekly-cleanup.lock
flock -n 9 || { log "another cleanup is running, exit"; exit 0; }

hours=$(( RETENTION_DAYS * 24 ))
log "start (dry_run=${DRY_RUN}), disk before: $(disk)"

if command -v docker >/dev/null 2>&1; then
  running=$(docker ps -q --filter "label=com.gitlab.gitlab-runner.managed=true" | wc -l)
  if (( running > 0 )); then
    log "WARN: ${running} job container(s) running, skipping cache wipe"
  else
    run /usr/share/gitlab-runner/clear-docker-cache prune-volumes
    if [[ "$DRY_RUN" != "1" ]]; then
      docker volume ls -q --filter name=runner- | xargs -r docker volume rm >/dev/null 2>&1 || log "WARN: some runner volumes in use"
    fi
    for dir in "${CACHE_DIRS[@]}"; do wipe_dir "$dir"; done
  fi
  run docker container prune -f --filter "until=${hours}h"
  run docker image prune -af --filter "until=${hours}h"
  run docker builder prune -af --filter "until=${hours}h"
  run docker network prune -f --filter "until=${hours}h"
fi

for dir in "${BUILD_DIRS[@]}"; do wipe_dir "$dir" "$RETENTION_DAYS"; done

if command -v apt-get >/dev/null 2>&1; then
  run apt-get -o DPkg::Lock::Timeout=600 autoremove --purge -y -q
  run apt-get -o DPkg::Lock::Timeout=600 autoclean -q
  run apt-get -o DPkg::Lock::Timeout=600 clean -q
elif command -v dnf >/dev/null 2>&1; then
  run dnf -y -q autoremove
  run dnf -q clean all
fi

run journalctl --vacuum-time="$(( RETENTION_DAYS * 2 ))d" --vacuum-size="$JOURNAL_MAX"

if [[ "$DRY_RUN" != "1" ]]; then
  log "-> removing rotated logs older than 30d"
  find /var/log -type f \( -name '*.gz' -o -name '*-[0-9]*' -o -name '*.[0-9]' -o -name '*.old' \) -mtime +30 -delete 2>/dev/null || true
  find /tmp /var/tmp -xdev -mindepth 1 -type f -atime +"$RETENTION_DAYS" -delete 2>/dev/null || true
fi
run systemd-tmpfiles --clean

if [[ -d "$SHARED_CACHE_DIR" && "$DRY_RUN" != "1" ]]; then
  log "-> pruning ${SHARED_CACHE_DIR} files not used for ${SHARED_CACHE_MAX_AGE_DAYS}d"
  find "$SHARED_CACHE_DIR" -xdev -type f -atime +"$SHARED_CACHE_MAX_AGE_DAYS" -delete 2>/dev/null || true
  find "$SHARED_CACHE_DIR" -xdev -mindepth 2 -type d -empty -delete 2>/dev/null || true
fi

log "done, disk after: $(disk)"
