#!/usr/bin/env bash
# server-update: update packages, clean up, and report whether a reboot is needed (Fedora and EL, dnf4 and dnf5).
# Installed as /usr/local/sbin/server-update by server/install-tools.sh. Run by server-update.timer with --security.
set -uo pipefail
CONF=${SERVER_INIT_CONF:-/etc/server-init.conf}
STATE=${SERVER_UPDATE_STATE:-/var/lib/server-update}
SBIN=${SERVER_SBIN:-/usr/local/sbin}
CHECK=0; SECURITY=0; REBOOT=0; SCHEDULED=0

usage() {
  cat <<'USAGE'
Usage: server-update [--check | --security] [--reboot]

  (no option)  dnf upgrade --refresh, then server-cleanup, then report reboot need and kernels
  --check      only list available updates; changes nothing
  --security   only security updates
  --reboot     reboot afterwards, but only if a reboot is needed (never reboots without this option)
  --scheduled  used by server-update.timer: also reboots if AUTO_REBOOT=1 in /etc/server-init.conf
Logs to syslog (tag server-update). Exit: 0 ok (with --check: nothing to update), 100 --check found updates,
1 failed or not root, 2 bad option.
USAGE
}
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    --security) SECURITY=1 ;;
    --reboot) REBOOT=1 ;;
    --scheduled) SCHEDULED=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "server-update: unknown option: $a" >&2; usage >&2; exit 2 ;;
  esac
done
(( CHECK == 0 || REBOOT == 0 )) || { echo "server-update: --check and --reboot cannot be combined" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "server-update: run as root (sudo server-update)" >&2; exit 1; }
# shellcheck source=/dev/null
[[ -r $CONF ]] && . "$CONF"
(( SCHEDULED == 1 )) && [[ ${AUTO_REBOOT:-0} == 1 ]] && REBOOT=1

log() { echo "server-update: $*"; ! command -v logger >/dev/null 2>&1 || logger -t server-update -- "$*" || true; }
notify() { [[ -x $SBIN/server-notify ]] && "$SBIN/server-notify" update "$*" || true; }
command -v dnf >/dev/null 2>&1 || { log "dnf not found"; exit 1; }
exec 9>/run/server-update.lock
if command -v flock >/dev/null 2>&1 && ! flock -n 9; then log "another server-update is running, exit"; exit 0; fi
SEC=(); (( SECURITY == 0 )) || SEC=(--security)

NEED=0 RUN_K="" NEW_K=""
reboot_check() {
  local rc=0
  NEED=0
  timeout 60 dnf -q -C needs-restarting -r >/dev/null 2>&1 || rc=$?
  if (( rc > 1 )); then rc=0; timeout 60 dnf -q needs-restarting -r >/dev/null 2>&1 || rc=$?; fi
  (( rc != 1 )) || NEED=1
  (( rc <= 1 )) || log "warn: needs-restarting unavailable (exit $rc), comparing kernels only"
  RUN_K=$(uname -r)
  NEW_K=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V | tail -n1)
  [[ -z $NEW_K || $NEW_K == "$RUN_K" ]] || NEED=1
}
# write_state UPDATES [RESULT]: cache for health --brief (it never runs dnf at login)
write_state() {
  local upd="" res=""
  mkdir -p "$STATE" && chmod 0755 "$STATE" || return 0
  if (( CHECK )); then
    upd=$(sed -nE 's/.* updated=([0-9]+).*/\1/p' "$STATE/state" 2>/dev/null); res=$(sed -nE 's/.* uresult=([a-z]+).*/\1/p' "$STATE/state" 2>/dev/null)
  else upd=$(date +%s); res=${2:-ok}; fi
  printf 'time=%s updates=%s reboot=%s running=%s newest=%s updated=%s uresult=%s\n' "$(date +%s)" "$1" "$NEED" "$RUN_K" "${NEW_K:-$RUN_K}" \
    "${upd:-0}" "${res:-none}" > "$STATE/state.tmp" && chmod 0644 "$STATE/state.tmp" && mv -f "$STATE/state.tmp" "$STATE/state"
}

if (( CHECK )); then
  out=$(dnf -q check-update --refresh "${SEC[@]}" 2>&1); rc=$?
  case $rc in
    0) n=0 ;;
    100) n=$(grep -cE '^[[:alnum:]_.+-]+\.[[:alnum:]_]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+$' <<<"$out") ;;
    *) log "dnf check-update failed (exit $rc): $(tail -n 3 <<<"$out")"; exit 1 ;;
  esac
  reboot_check
  (( n == 0 )) || echo "$out"
  log "check: $n update(s) available, reboot needed: $( (( NEED )) && echo yes || echo no ), kernel running $RUN_K newest ${NEW_K:-$RUN_K}"
  write_state "$n" ok
  (( rc == 100 )) && exit 100
  exit 0
fi

log "start upgrade${SEC[*]:+ (security only)}"
if ! dnf -y upgrade --refresh "${SEC[@]}"; then
  log "dnf upgrade failed"
  reboot_check; write_state "?" failed
  notify "update FAILED (dnf upgrade)"
  exit 1
fi
if [[ -x $SBIN/server-cleanup ]]; then SERVER_CLEANUP_QUIET=1 "$SBIN/server-cleanup" || log "warn: server-cleanup exit $?"; fi
reboot_check
write_state 0 ok
log "done: reboot needed: $( (( NEED )) && echo yes || echo no ), kernel running $RUN_K newest ${NEW_K:-$RUN_K}"
if (( NEED && REBOOT )); then
  notify "update done, rebooting now (kernel $RUN_K -> ${NEW_K:-$RUN_K})"
  log "rebooting (reboot needed and requested)"
  systemctl reboot
elif (( NEED )); then
  notify "update done, REBOOT PENDING (running $RUN_K, newest ${NEW_K:-$RUN_K}); run: srv update --reboot"
else
  notify "update done, no reboot needed"
fi
exit 0
