#!/usr/bin/env bash
# server-disk-guard: run server-cleanup when / is at least DISK_CLEAN_THRESHOLD percent full (default 85),
# at most once per DISK_CLEAN_COOLDOWN_H hours (default 6); notify if still above the threshold afterwards.
# Run every 30 minutes by server-disk-guard.timer. Installed by server/install-tools.sh. Silent when the disk is fine.
set -uo pipefail
CONF=${SERVER_INIT_CONF:-/etc/server-init.conf}
STATE=${SERVER_CLEANUP_STATE:-/var/lib/server-cleanup}
SBIN=${SERVER_SBIN:-/usr/local/sbin}
if [[ ${1:-} == -h || ${1:-} == --help ]]; then
  echo "Usage: server-disk-guard   (settings DISK_CLEAN_THRESHOLD=85, DISK_CLEAN_COOLDOWN_H=6 in /etc/server-init.conf)"; exit 0
fi
[[ $EUID -eq 0 ]] || { echo "server-disk-guard: run as root" >&2; exit 1; }
# shellcheck source=/dev/null
[[ -r $CONF ]] && . "$CONF"
LIMIT=${DISK_CLEAN_THRESHOLD:-85}; COOL=${DISK_CLEAN_COOLDOWN_H:-6}
[[ $LIMIT =~ ^[0-9]+$ ]] || LIMIT=85
[[ $COOL =~ ^[0-9]+$ ]] || COOL=6
log() { echo "server-disk-guard: $*"; ! command -v logger >/dev/null 2>&1 || logger -t server-disk-guard -- "$*" || true; }
used() { df -Pk / | awk 'NR == 2 { gsub(/%/, "", $5); print $5 }'; }

u=$(used)
[[ $u =~ ^[0-9]+$ ]] || { log "cannot read disk usage"; exit 1; }
(( u >= LIMIT )) || exit 0
now=$(date +%s)
last=0; [[ -r $STATE/guard-last ]] && read -r last < "$STATE/guard-last"
[[ $last =~ ^[0-9]+$ ]] || last=0
if (( now - last < COOL * 3600 )); then log "/ at ${u}% (limit ${LIMIT}%), cleanup ran $(( (now - last) / 60 )) min ago, cooldown ${COOL}h"; exit 0; fi
log "/ at ${u}% >= ${LIMIT}%, running server-cleanup"
mkdir -p "$STATE" && echo "$now" > "$STATE/guard-last"
SERVER_CLEANUP_QUIET=1 "$SBIN/server-cleanup" || log "warn: server-cleanup exit $?"
u2=$(used)
if (( u2 >= LIMIT )); then
  log "/ still at ${u2}% after cleanup (limit ${LIMIT}%)"
  [[ -x $SBIN/server-notify ]] && "$SBIN/server-notify" disk "disk guard: / at ${u}%, still ${u2}% after cleanup (limit ${LIMIT}%); free space by hand" || true
else
  log "/ now at ${u2}%"
fi
exit 0
