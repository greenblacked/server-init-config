# shellcheck shell=sh
# Prints the cached health summary when the admin user logs in interactively (sh and bash).
# Installed as /etc/profile.d/91-server-login.sh by server/install-tools.sh (LOGIN_SUMMARY=1 in /etc/server-init.conf).
# Instant: it only prints a file written every 15 minutes by server-health-brief.timer. Silent for scp, rsync, sftp
# and other non-interactive shells. Always returns 0.
__server_login() {
  case $- in *i*) ;; *) return 0 ;; esac
  # shellcheck source=/dev/null
  __sl=$( . "${SERVER_INIT_CONF:-/etc/server-init.conf}" >/dev/null 2>&1; echo "${ADMIN_USER:-ops} ${LOGIN_SUMMARY:-1}" ) || return 0
  [ "$(id -un 2>/dev/null)" = "${__sl%% *}" ] || return 0
  [ "${__sl##* }" = 1 ] || return 0
  if [ -r "${SERVER_HEALTH_BRIEF:-/var/lib/server-health/brief.txt}" ]; then
    cat "${SERVER_HEALTH_BRIEF:-/var/lib/server-health/brief.txt}" 2>/dev/null
  else
    echo "(health summary not generated yet)"
  fi
  return 0
}
__server_login || :
unset -f __server_login 2>/dev/null || :
unset __sl
