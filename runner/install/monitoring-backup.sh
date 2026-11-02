#!/usr/bin/env bash
# Back up the Grafana data volume (SQLite database, plugins) before the first start of a new Grafana major.
# Grafana migrates its database forward on start and cannot downgrade: the only way back is this backup plus the old image tag
# (runner/README.md, "Grafana upgrade and rollback"). Called by monitoring.sh and by update.sh before they change the stack.
# Idempotent: it backs up only when the installed image tag and the repo tag are on different majors (or the installed
# version is unknown); a rerun after the compose file was updated is a no-op and the first backup stays.
set -Eeuo pipefail
# shellcheck source=../../common/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib.sh"

DIR="${MON_DIR:-/opt/monitoring}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/monitoring}"
KEEP=3
FROM_TAG=""
TO_TAG=""
FORCE=0
DRYRUN=0

usage() {
  cat <<USAGE
Usage: $0 [--dry-run] [--force] [--from-tag TAG] [--to-tag TAG]

Archives the Grafana data volume to ${BACKUP_DIR}/grafana-<from-version>-<date>.tar.gz (mode 0600, last ${KEEP} kept)
when the Grafana major changes. Grafana is stopped for the copy so the SQLite file is consistent, and started again afterwards.
  --from-tag  version the data belongs to (default: image tag in ${DIR}/docker-compose.yml)
  --to-tag    version about to start (default: image tag in this repo's monitoring compose file)
  --force     back up even when the major does not change
USAGE
}

while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -n|--dry-run) DRYRUN=1 ;;
    --force) FORCE=1 ;;
    --from-tag) FROM_TAG="${2:?--from-tag needs a value}"; shift ;;
    --to-tag) TO_TAG="${2:?--to-tag needs a value}"; shift ;;
    *) usage >&2; exit 1 ;;
  esac
  shift
done

grafana_tag() { awk '/image: grafana\/grafana:/ { sub(/.*grafana\/grafana:/, ""); print $1; exit }' "$1"; }
major() { echo "${1%%.*}"; }

require_root
command -v docker >/dev/null || die "docker not installed"

[[ -n "$TO_TAG" ]] || TO_TAG=$(grafana_tag "${REPO_ROOT}/runner/stacks/monitoring/docker-compose.yml")
[[ -n "$TO_TAG" ]] || die "cannot read the Grafana tag from the repo compose file"
if [[ -z "$FROM_TAG" && -f "${DIR}/docker-compose.yml" ]]; then FROM_TAG=$(grafana_tag "${DIR}/docker-compose.yml"); fi

vol=$(docker volume ls -q --filter label=com.docker.compose.project=monitoring --filter label=com.docker.compose.volume=grafana-data | head -n1)
if [[ -z "$vol" ]]; then
  log "grafana backup: no Grafana data volume yet, nothing to back up"
  exit 0
fi
# A dry run only reads: no container, so no image pull. It assumes a database is in the volume.
if (( ! DRYRUN )) && ! docker run --rm --network none -v "${vol}:/v:ro" alpine:3.20 test -s /v/grafana.db; then
  log "grafana backup: ${vol} holds no database yet, nothing to back up"
  exit 0
fi

# No compose file (reinstall over a leftover volume): the version is on the stopped container that last used the volume, if any.
if [[ -z "$FROM_TAG" ]]; then
  FROM_TAG=$(docker ps -a --filter "volume=${vol}" --format '{{.Image}}' | awk -F: '/^grafana\/grafana:/ { print $2; exit }')
fi

if (( ! FORCE )) && [[ -n "$FROM_TAG" && "$(major "$FROM_TAG")" == "$(major "$TO_TAG")" ]]; then
  log "grafana backup: ${FROM_TAG} -> ${TO_TAG} stays on major $(major "$TO_TAG"), no backup needed"
  exit 0
fi

label=$(printf '%s' "${FROM_TAG:-unknown}" | tr -c 'A-Za-z0-9._-' '_')
target="${BACKUP_DIR}/grafana-${label}-$(date +%Y%m%d-%H%M%S).tar.gz"
if (( DRYRUN )); then
  log "[dry-run] would back up ${vol}, if it holds a database (${FROM_TAG:-unknown} -> ${TO_TAG}) to ${target}"
  exit 0
fi

install -d -m 0700 "$BACKUP_DIR"
tmp=$(umask 077; mktemp "${BACKUP_DIR}/.grafana-backup.XXXXXX")
stopped=$(docker ps -q --filter "volume=${vol}")
cleanup() {
  rm -f "$tmp"
  if [[ -n "$stopped" ]]; then
    # shellcheck disable=SC2086
    docker start $stopped >/dev/null || log "WARN: could not start the Grafana container again, run docker compose up -d in ${DIR}"
  fi
}
trap cleanup EXIT

if [[ -n "$stopped" ]]; then
  log "grafana backup: stopping Grafana for a consistent copy"
  # shellcheck disable=SC2086
  docker stop $stopped >/dev/null
fi
log "grafana backup: ${vol} (${FROM_TAG:-unknown} -> ${TO_TAG})"
docker run --rm --network none -v "${vol}:/v:ro" alpine:3.20 tar -C /v -czf - . > "$tmp"
# Read the listing into a variable first: grep -q exiting early would SIGPIPE tar under pipefail.
listing=$(tar -tzf "$tmp")
grep -Eq '^(\./)?grafana\.db$' <<<"$listing" || die "the archive has no grafana.db, backup discarded"
chmod 600 "$tmp"
mv "$tmp" "$target"
log "grafana backup: wrote ${target} ($(du -h "$target" | cut -f1))"

# Keep the newest ${KEEP} archives.
find "$BACKUP_DIR" -maxdepth 1 -type f -name 'grafana-*.tar.gz' -printf '%T@ %p\n' | sort -rn | tail -n "+$((KEEP + 1))" | cut -d' ' -f2- \
  | xargs -r rm -f --
