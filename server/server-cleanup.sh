#!/usr/bin/env bash
# server-cleanup: safe cleanup for a general server (journal, package cache, Docker leftovers, rotated logs,
# temp files, core dumps). Never touches /home, /root, /srv, /opt, Docker volumes, databases or repos.
# Same text is embedded in the server/server-init-*.sh scripts that install it (they must stay
# self-contained): keep all copies identical, tools/test-cloud-init.py checks that.
# Settings come from /etc/server-init.conf (CLEAN_JOURNAL_TIME, CLEAN_JOURNAL_SIZE, CLEAN_AUTOREMOVE,
# CLEAN_DOCKER_UNUSED_IMAGES); missing keys use the defaults below.
set -uo pipefail
CONF=${SERVER_INIT_CONF:-/etc/server-init.conf}
STATE=${SERVER_CLEANUP_STATE:-/var/lib/server-cleanup}
DRY=0

usage() {
  cat <<'USAGE'
Usage: server-cleanup [--dry-run] [--help]

Safe cleanup, each part skipped when its tool is missing:
  journald     journalctl --vacuum-time/--vacuum-size (CLEAN_JOURNAL_TIME, CLEAN_JOURNAL_SIZE)
  packages     dnf clean packages (installonly_limit=3 if unset), apt-get clean or zypper clean;
               dnf/apt-get autoremove only with CLEAN_AUTOREMOVE=1
  docker       dangling images, build cache and stopped containers older than 7d; never volumes;
               CLEAN_DOCKER_UNUSED_IMAGES=1 also prunes unused images older than 30d
  temp         systemd-tmpfiles --clean for /tmp and /var/tmp (the system's own age rules)
  logs         /var/log/*.gz and *.[0-9] older than 30d
  core dumps   /var/lib/systemd/coredump older than 7d; crash dirs (/var/crash, /var/spool/abrt) older than 30d
  --dry-run    print what would be done, change nothing
Logs to stdout and syslog (tag server-cleanup). Exit: 0 ok, 1 not root, 2 bad option, 3 an action failed.
USAGE
}
for a in "$@"; do
  case "$a" in
    -n|--dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "server-cleanup: unknown option: $a" >&2; usage >&2; exit 2 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "server-cleanup: run as root (sudo server-cleanup)" >&2; exit 1; }
# shellcheck source=/dev/null
[[ -r $CONF ]] && . "$CONF"
J_TIME=${CLEAN_JOURNAL_TIME:-1month}
J_SIZE=${CLEAN_JOURNAL_SIZE:-500M}
ERRORS=0

log() {
  local lvl=$1; shift
  printf 'ts=%s level=%s msg="%s"\n' "$(date -Is)" "$lvl" "$*"
  (( DRY )) || ! command -v logger >/dev/null 2>&1 || logger -t server-cleanup -- "level=$lvl msg=\"$*\"" || true
}
have() { command -v "$1" >/dev/null 2>&1; }
skip() { log info "skip $1: $2"; }
[[ $J_TIME =~ ^[0-9]+[a-z]*$ ]] || { log warn "bad CLEAN_JOURNAL_TIME '$J_TIME', using 1month"; J_TIME=1month; }
[[ $J_SIZE =~ ^[0-9]+[KMGT]?$ ]] || { log warn "bad CLEAN_JOURNAL_SIZE '$J_SIZE', using 500M"; J_SIZE=500M; }

run() {
  if (( DRY )); then log info "would run: $*"; return 0; fi
  local out rc l
  out=$("$@" 2>&1); rc=$?
  log info "ran: $* (exit $rc)"
  if [[ -n $out ]]; then
    while IFS= read -r l; do log info "  $l"; done < <(tail -n 5 <<<"$out")
  fi
  (( rc == 0 )) || { log warn "failed (exit $rc): $*"; ERRORS=$((ERRORS + 1)); }
  return 0
}

# prune_old DESC DAYS DIR [find tests...]: delete regular files older than DAYS under DIR, same filesystem.
prune_old() {
  local desc=$1 days=$2 dir=$3 n kb; shift 3
  case $dir in /|/home*|/root*|/srv*|/opt*|/var/lib/docker*) log error "refusing protected path $dir"; ERRORS=$((ERRORS + 1)); return 0 ;; esac
  [[ -d $dir ]] || { skip "$desc" "$dir not present"; return 0; }
  read -r n kb < <(find "$dir" -xdev -type f "$@" -mtime +"$days" -printf '%s\n' 2>/dev/null | awk '{ n++; s += $1 } END { print n + 0, int(s / 1024) }')
  if (( n == 0 )); then log info "$desc: nothing older than ${days}d in $dir"; return 0; fi
  if (( DRY )); then log info "would delete $desc: $n files, ${kb} KiB in $dir (older than ${days}d)"; return 0; fi
  find "$dir" -xdev -type f "$@" -mtime +"$days" -delete 2>/dev/null
  [[ $dir == /var/log ]] || find "$dir" -xdev -mindepth 1 -type d -empty -mtime +"$days" -delete 2>/dev/null
  log info "deleted $desc: $n files, ${kb} KiB in $dir (older than ${days}d)"
  return 0
}

avail_mb() { df -Pk / | awk 'NR == 2 { print int($4 / 1024) }'; }
disk() { df -Pk / | awk 'NR == 2 { printf "used=%dMiB avail=%dMiB use=%s", $3 / 1024, $4 / 1024, $5 }'; }

if (( ! DRY )); then
  exec 9>/run/server-cleanup.lock
  if have flock && ! flock -n 9; then log info "another server-cleanup is running, exit"; exit 0; fi
fi
before=$(avail_mb)
log info "start dry_run=$DRY disk_before: $(disk)"

if have journalctl; then
  log info "journal: $(journalctl --disk-usage 2>&1 | head -n1)"
  run journalctl --vacuum-time="$J_TIME" --vacuum-size="$J_SIZE"
else skip journald "journalctl not found"; fi

if have dnf; then
  run dnf clean packages
  if [[ -f /etc/dnf/dnf.conf ]] && ! grep -q '^installonly_limit' /etc/dnf/dnf.conf; then
    if (( DRY )); then log info "would set installonly_limit=3 in /etc/dnf/dnf.conf"
    elif grep -q '^\[main\]' /etc/dnf/dnf.conf; then sed -i '/^\[main\]/a installonly_limit=3' /etc/dnf/dnf.conf && log info "set installonly_limit=3 in /etc/dnf/dnf.conf (old kernels are removed by dnf, never the running one)"
    else log warn "no [main] section in /etc/dnf/dnf.conf, installonly_limit left unset"; fi
  fi
  if [[ ${CLEAN_AUTOREMOVE:-0} == 1 ]]; then run dnf -y autoremove; else skip autoremove "CLEAN_AUTOREMOVE is not 1"; fi
elif have apt-get; then
  run apt-get clean
  if [[ ${CLEAN_AUTOREMOVE:-0} == 1 ]]; then run apt-get -y autoremove; else skip autoremove "CLEAN_AUTOREMOVE is not 1"; fi
elif have zypper; then
  run zypper --non-interactive clean
else skip packages "dnf, apt-get and zypper not found"; fi

if have docker && systemctl is-active --quiet docker 2>/dev/null; then
  run docker container prune -f --filter until=168h
  run docker image prune -f
  run docker builder prune -f --filter until=168h
  if [[ ${CLEAN_DOCKER_UNUSED_IMAGES:-0} == 1 ]]; then run docker image prune -a -f --filter until=720h; fi
else skip docker "docker is not installed or not active"; fi

if have systemd-tmpfiles; then run systemd-tmpfiles --clean --prefix=/tmp --prefix=/var/tmp
else skip temp "systemd-tmpfiles not found"; fi
prune_old "rotated logs" 30 /var/log \( -name '*.gz' -o -name '*.[0-9]' \)
prune_old "core dumps" 7 /var/lib/systemd/coredump
prune_old "crash reports" 30 /var/crash
prune_old "abrt reports" 30 /var/spool/abrt

after=$(avail_mb)
log info "done dry_run=$DRY errors=$ERRORS freed=$(( after - before ))MiB disk_after: $(disk)"
if (( ! DRY )); then
  mkdir -p "$STATE" && chmod 0755 "$STATE" && date +%s > "$STATE/last-run" && chmod 0644 "$STATE/last-run"
  if (( ERRORS == 0 )); then echo ok > "$STATE/last-result"; else echo failed > "$STATE/last-result"; fi
  if [[ -z ${SERVER_CLEANUP_QUIET:-} && -x /usr/local/sbin/server-notify ]]; then
    res="done"; (( ERRORS == 0 )) || res="finished with $ERRORS error(s)"
    /usr/local/sbin/server-notify cleanup "cleanup ${res}: freed $(( after - before )) MiB, $(disk)" || true
  fi
fi
(( ERRORS == 0 )) || exit 3
exit 0
