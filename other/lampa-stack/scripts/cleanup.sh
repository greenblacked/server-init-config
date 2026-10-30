#!/usr/bin/env bash
# Periodic cleanup for the Lampa stack (run by lampa-stack-cleanup.timer every 3 days).
#   - TorrServer: removes every torrent from its list through its API (this is what ends unauthenticated
#     /stream playback of saved torrents), then empties the scratch dirs (data/torrserver/cache, .../torrents).
#   - qBittorrent: NOTHING by default (seeding is allowed). Only when QBT_DELETE_COMPLETED_DAYS > 0 in .env:
#     deletes downloaded FILES not modified for that many days. Off by default; see README.
# Never touches: data/torrserver/config (settings.json, accs.db, viewed.json), data/qbt/config, data/authelia,
# data/lampac, secrets/, .env.
# Usage: cleanup.sh [--dry-run] [-h|--help]
set -Eeuo pipefail

DIR="${LAMPA_STACK_DIR:-/opt/lampa-stack}"
DRY=0

usage() {
  cat <<USAGE
Usage: $0 [--dry-run]
Removes all torrents from TorrServer's list (API) and empties the cache/torrents scratch directories under ${DIR}/data/torrserver.
With QBT_DELETE_COMPLETED_DAYS=N (N>0) in ${DIR}/.env it also deletes qBittorrent download files older than N days.
Never touches configuration, credentials or secrets.
  --dry-run   list what would be removed, remove nothing
Environment: LAMPA_STACK_DIR (default /opt/lampa-stack)
USAGE
}

log() { printf '[cleanup] %s\n' "$*"; }
die() { printf '[cleanup] ERROR: %s\n' "$*" >&2; exit 1; }

for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $a" ;;
  esac
done

[[ -d "$DIR/data" ]] || die "${DIR}/data not found (is the stack installed?)"
DATA=$(cd "$DIR/data" && pwd -P)

env_get() { [[ -f "$DIR/.env" ]] && grep -m1 "^$1=" "$DIR/.env" | cut -d= -f2- || true; }

# Safety: only operate on directories that resolve to a fixed child of DATA, never on a symlink out of it.
safe_dir() {
  local d="$1" real
  [[ -d "$d" ]] || return 1
  real=$(cd "$d" && pwd -P) || return 1
  [[ "$real" == "$DATA"/* ]] || { log "refusing ${d}: outside ${DATA}"; return 1; }
  case "$real" in
    "$DATA"/torrserver/config|"$DATA"/torrserver/config/*|"$DATA"/qbt/config|"$DATA"/qbt/config/*|"$DATA"/authelia|"$DATA"/authelia/*|"$DATA"/lampac|"$DATA"/lampac/*)
      log "refusing ${d}: protected path"; return 1 ;;
  esac
  return 0
}

empty_dir() {
  local d="$1" n
  safe_dir "$d" || return 0
  n=$(find "$d" -mindepth 1 2>/dev/null | wc -l)
  if (( n == 0 )); then log "${d}: already empty"; return 0; fi
  if (( DRY )); then
    log "would remove ${n} entries from ${d}"
    find "$d" -mindepth 1 -maxdepth 2 2>/dev/null | head -20 | sed 's/^/[cleanup]   /'
  else
    find "$d" -mindepth 1 -delete
    log "${d}: removed ${n} entries"
  fi
}

(( DRY )) && log "dry run: nothing will be deleted"

# TorrServer's torrent list lives in config/ (protected from file deletion), so it is emptied through the API:
# POST /torrents {"action":"list"}, then {"action":"rem","hash":...} for each. The credential and bodies go to curl
# (run inside the qBittorrent container, same internal network) as a config on stdin, never on a command line.
ts_api() { # json body (no quotes/backslashes needed beyond plain JSON) -> stdout
  local body="${1//\\/\\\\}" pw
  body="${body//\"/\\\"}"
  pw=$(cat "$DIR/secrets/ts_password")
  { printf 'header = "Authorization: Basic %s"\nheader = "Content-Type: application/json"\n' "$(printf 'lampa:%s' "$pw" | base64 -w0)"
    printf 'data = "%s"\nurl = "http://torrserver:8090/torrents"\n' "$body"
  } | docker exec -i "${LAMPA_STACK_PROJECT:-lampa-stack}-qbittorrent-1" curl -sS --fail --max-time 30 -K -
}

wipe_torrserver_list() {
  local list hashes n=0 h
  if [[ ! -r "$DIR/secrets/ts_password" ]] || ! command -v docker >/dev/null 2>&1; then
    log "TorrServer list: skipped (no secrets/ts_password or no docker)"; return 0
  fi
  if ! list=$(ts_api '{"action":"list"}' 2>/dev/null); then
    log "TorrServer list: API not reachable (stack stopped?), skipped"; return 0
  fi
  hashes=$(grep -oE '"hash":"[0-9a-fA-F]{40}"' <<<"$list" | cut -d'"' -f4 | sort -u || true)
  if [[ -z "$hashes" ]]; then log "TorrServer list: already empty"; return 0; fi
  n=$(wc -l <<<"$hashes")
  if (( DRY )); then log "would remove ${n} torrents from the TorrServer list"; return 0; fi
  while read -r h; do
    ts_api "{\"action\":\"rem\",\"hash\":\"${h}\"}" >/dev/null || log "could not remove ${h}"
  done <<<"$hashes"
  log "TorrServer list: removed ${n} torrents"
}
wipe_torrserver_list

empty_dir "$DATA/torrserver/cache"
empty_dir "$DATA/torrserver/torrents"

days=$(env_get QBT_DELETE_COMPLETED_DAYS)
days="${days:-0}"
if [[ "$days" =~ ^[1-9][0-9]*$ ]]; then
  d="$DATA/qbt/downloads"
  if safe_dir "$d"; then
    n=$(find "$d" -type f -mtime "+${days}" 2>/dev/null | wc -l)
    if (( DRY )); then
      log "would delete ${n} download files older than ${days} days from ${d}"
      find "$d" -type f -mtime "+${days}" 2>/dev/null | head -20 | sed 's/^/[cleanup]   /'
    else
      find "$d" -type f -mtime "+${days}" -delete
      find "$d" -mindepth 1 -type d -empty -delete
      log "${d}: deleted ${n} files older than ${days} days"
    fi
  fi
else
  log "qBittorrent downloads: left alone (QBT_DELETE_COMPLETED_DAYS=${days})"
fi
log "done"
