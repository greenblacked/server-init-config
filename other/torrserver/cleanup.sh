#!/usr/bin/env bash
# TorrServer cleanup: drop torrents from the running server and delete old downloaded data.
# Run by torrserver-cleanup.timer every 3 days; safe to run by hand (use --dry-run first).
#
# What it touches:   $TS_DIR/data/downloads  (leftover disk cache; TorrServer streams from RAM now, so this is a safety net) and the torrent list in the API.
# What it never does: touch $TS_DIR/data/config (accs.db, config.db, settings.json), the log, or $TS_DIR/credentials.
# Sources (API actions "list", "drop", "rem"): https://github.com/YouROK/TorrServer/blob/MatriX.147.2/server/web/api/torrents.go
set -Eeuo pipefail

TS_DIR="${TS_DIR:-/opt/torrserver}"
DAYS="${CLEAN_DAYS:-3}"
DRY=0

usage() {
  cat <<USAGE
Usage: cleanup.sh [--dry-run] [--days N] [--help]

  1. If TorrServer answers on 127.0.0.1: 'drop' every torrent loaded in memory (closes peer
     connections, so nothing is shared) and 'rem' (delete from the list and its cache) every
     torrent added more than N days ago.
  2. Delete files under ${TS_DIR}/data/downloads that were last modified more than N days ago,
     then empty directories that are also that old (a directory emptied by this run is removed by the next one). Skipped if the container is running but the API cannot be used.

Environment: TS_DIR (default /opt/torrserver), CLEAN_DAYS (default 3).
  --dry-run   print what would happen, change nothing
  --days N    age limit in days (default ${DAYS})
USAGE
}

while (($#)); do
  case "$1" in
    --dry-run) DRY=1 ;;
    --days) shift; DAYS="${1:-}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[[ "$DAYS" =~ ^[0-9]+$ && "$DAYS" -ge 1 ]] || { echo "ERROR: --days must be a whole number >= 1" >&2; exit 2; }

log() { echo "cleanup: $*"; }
act() { if ((DRY)); then log "[dry-run] $*"; else log "$*"; fi; }

DL="${TS_DIR}/data/downloads"
CREDS="${TS_DIR}/credentials"
ENVF="${TS_DIR}/.env"

# Guard: the target must be the downloads directory inside our data dir, nothing else.
if [[ ! -d "$DL" ]]; then log "no downloads directory at ${DL}, nothing to do"; exit 0; fi
real=$(realpath -e -- "$DL")
[[ "$real" == "$(realpath -e -- "$TS_DIR")/data/downloads" ]] || { echo "ERROR: ${DL} resolves outside ${TS_DIR}/data/downloads (${real})" >&2; exit 1; }

port=8090
if [[ -r "$ENVF" ]]; then
  p=$(grep -E '^TS_HOST_PORT=[0-9]+$' "$ENVF" | tail -n1 | cut -d= -f2 || true)
  [[ -n "$p" ]] && port="$p"
fi
base="http://127.0.0.1:${port}"

container_running() {
  command -v docker >/dev/null 2>&1 || return 1
  [[ "$(docker inspect -f '{{.State.Running}}' torrserver 2>/dev/null || true)" == "true" ]]
}

tmp=$(mktemp -d); chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT
cfg="${tmp}/curl.conf"

api_ready=0
api_error=0
if curl -fsS -m 5 -o /dev/null "${base}/echo" 2>/dev/null; then
  if [[ -r "$CREDS" ]]; then
    user=$(grep -E '^TS_USER=' "$CREDS" | head -n1 | cut -d= -f2-)
    pass=$(grep -E '^TS_PASS=' "$CREDS" | head -n1 | cut -d= -f2-)
    # The password goes through a 0600 file in a private tmp dir, never on a command line.
    umask 077
    printf 'user = "%s:%s"\nheader = "Content-Type: application/json"\n' "$user" "$pass" > "$cfg"
    unset user pass
    api() { curl -fsS -m 30 -K "$cfg" -X POST --data-binary "$1" "${base}$2"; }
    if api '{"action":"list"}' /torrents > "${tmp}/list.json" 2>/dev/null && jq -e 'type=="array"' "${tmp}/list.json" >/dev/null 2>&1; then
      api_ready=1
    else
      api_error=1
      log "WARN: API did not accept the credentials or returned bad data"
    fi
  else
    api_error=1
    log "WARN: ${CREDS} not readable, cannot use the API"
  fi
else
  log "TorrServer does not answer on ${base}, skipping API step"
  if container_running; then api_error=1; fi
fi

if ((api_ready)); then
  cutoff=$(( $(date +%s) - DAYS * 86400 ))
  n_all=$(jq 'length' "${tmp}/list.json")
  log "${n_all} torrent(s) listed"
  # stat 5 = "in db" (not loaded in memory): nothing to drop.
  while IFS=$'\t' read -r hash stat ts title; do
    [[ -n "$hash" ]] || continue
    if [[ "$stat" != "5" ]]; then
      act "drop ${hash} (${title})"
      if ((!DRY)); then api "{\"action\":\"drop\",\"hash\":\"${hash}\"}" /torrents >/dev/null || log "WARN: drop failed for ${hash}"; fi
    fi
    if (( ts > 0 && ts < cutoff )); then
      act "rem ${hash} (${title}), added $(date -d "@${ts}" +%F)"
      if ((!DRY)); then api "{\"action\":\"rem\",\"hash\":\"${hash}\"}" /torrents >/dev/null || log "WARN: rem failed for ${hash}"; fi
    fi
  done < <(jq -r '.[] | [(.hash // ""), (.stat // 0), (.timestamp // 0), ((.title // .name // "") | gsub("[\\t\\n\\r]"; " "))] | @tsv' "${tmp}/list.json")
fi

# A running container with a broken API means we cannot tell if files are in use: do not delete under it.
if ((api_error)) && container_running; then
  log "ERROR: container is running but the API is unusable; file cleanup skipped"
  exit 1
fi

# -xdev: stay on this filesystem; no -L: symlinks are never followed (an old link is removed, its target is not); -mindepth 1: never the directory itself.
n_files=$(find "$real" -xdev -mindepth 1 \( -type f -o -type l \) -mtime "+$((DAYS - 1))" -printf '.' | wc -c)
bytes=$(find "$real" -xdev -mindepth 1 \( -type f -o -type l \) -mtime "+$((DAYS - 1))" -printf '%s\n' | awk '{ s += $1 } END { printf "%d", s }')
act "delete ${n_files} file(s) older than ${DAYS} day(s) in ${real} ($((bytes / 1048576)) MiB)"
if ((!DRY)); then
  find "$real" -xdev -mindepth 1 \( -type f -o -type l \) -mtime "+$((DAYS - 1))" -delete
  find "$real" -xdev -mindepth 1 -type d -empty -mtime "+$((DAYS - 1))" -delete
fi
log "done"
