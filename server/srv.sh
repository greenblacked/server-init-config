#!/usr/bin/env bash
# srv: single entry point for server maintenance. A thin dispatcher; re-runs itself through passwordless sudo.
# Installed as /usr/local/bin/srv by server/install-tools.sh.
set -uo pipefail
SBIN=${SERVER_SBIN:-/usr/local/sbin}
BIN=${SERVER_BIN:-/usr/local/bin}

usage() {
  cat <<'USAGE'
Usage: srv COMMAND [options]

  status                          short health summary, fresh (health --brief)
  health [-q]                     full health report
  update [--check|--security|--reboot]   update packages (server-update)
  clean [--dry-run]               clean up disk space (server-cleanup)
  logs                            last runs of update, cleanup and disk guard from the journal
  timers                          state and next run of the server timers
  notify-test                     send a test notification (/etc/server-init.d/notify.env)
  help                            this text
USAGE
}
cmd=${1:-help}; shift || true
case $cmd in
  help|-h|--help) usage; exit 0 ;;
  status|health|update|clean|logs|timers|notify-test) ;;
  *) echo "srv: unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac
# health re-runs itself through sudo; --help needs no root; everything else is elevated here.
case "$cmd:${1:-}" in
  health:*|*:--help|*:-h) ;;
  *)
    if [[ $EUID -ne 0 ]]; then
      command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1 || { echo "srv: $cmd needs root or passwordless sudo" >&2; exit 1; }
      exec sudo -n -- "$(readlink -f "$0")" "$cmd" "$@"
    fi ;;
esac
case $cmd in
  status) exec "$BIN/health" --brief "$@" ;;
  health) exec "$BIN/health" "$@" ;;
  update) exec "$SBIN/server-update" "$@" ;;
  clean) exec "$SBIN/server-cleanup" "$@" ;;
  logs) exec journalctl --no-pager -n 40 -o short-iso -u server-update.service -u server-cleanup.service -u server-disk-guard.service ;;
  timers)
    systemctl list-timers 'server-*' --all --no-pager
    for t in dnf-automatic.timer dnf5-automatic.timer; do
      systemctl is-enabled --quiet "$t" 2>/dev/null && echo "note: $t is enabled too (install-tools disables it; server-update.timer replaces it)"
    done
    exit 0 ;;
  notify-test) exec "$SBIN/server-notify" test "test message from srv" ;;
esac
