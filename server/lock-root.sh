#!/usr/bin/env bash
# Close root SSH on a plain server (optional; server-init leaves root with a key on port 22 so it can never lock you out).
#
#   sudo bash /root/server-init-config/server/lock-root.sh            set PermitRootLogin no
#   sudo bash /root/server-init-config/server/lock-root.sh --unlock-root   undo it (root by key again)
#   ... --status                                                         show the effective setting
#
# Run it only after the admin login works from your laptop. It refuses unless ADMIN_USER (from /etc/server-init.conf,
# default ops) has at least one SSH key and `sudo -n true` works for that user. It writes one sshd drop-in,
# /etc/ssh/sshd_config.d/00-a-root-lock.conf (named to load before 00-hardening.conf, because the first match wins),
# checks it with sshd -t, reloads sshd and verifies the effective value with sshd -T; on any failure it restores
# the previous state. It never changes the SSH port, and a rerun of server-init leaves the drop-in alone.
# Fallback if you lose both logins: Hetzner web console, then: rm /etc/ssh/sshd_config.d/00-a-root-lock.conf && systemctl reload ssh (or sshd)
set -Eeuo pipefail

CONF_FILE=/etc/server-init.conf
DROPIN="${LOCK_ROOT_DROPIN:-/etc/ssh/sshd_config.d/00-a-root-lock.conf}"   # overridable for tests
SSHD_CONFIG="${LOCK_ROOT_SSHD_CONFIG:-/etc/ssh/sshd_config}"
MODE=lock

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

case "${1:-}" in
  "") ;;
  --unlock-root) MODE=unlock ;;
  --status) MODE=status ;;
  -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown option: $1 (--unlock-root, --status, --help)" ;;
esac
[[ $EUID -eq 0 ]] || die "run as root (sudo bash $0)"

ADMIN_USER="${ADMIN_USER:-}"
if [[ -z "$ADMIN_USER" && -f "$CONF_FILE" ]]; then
  ADMIN_USER=$(sed -n 's/^ADMIN_USER=//p' "$CONF_FILE" | tail -1 | tr -d "\"'")
fi
ADMIN_USER="${ADMIN_USER:-ops}"

sshd_bin=$(command -v sshd || echo /usr/sbin/sshd)
[[ -x "$sshd_bin" ]] || die "sshd not found"
effective() { "$sshd_bin" -T 2>/dev/null | awk '$1 == "permitrootlogin" { print $2 }'; }
reload_sshd() {
  if systemctl cat sshd >/dev/null 2>&1; then systemctl reload sshd; else systemctl reload ssh; fi
}

if [[ "$MODE" == status ]]; then
  log "effective PermitRootLogin: $(effective); drop-in ${DROPIN}: $([[ -f "$DROPIN" ]] && echo present || echo absent)"
  exit 0
fi

backup=""
if [[ -f "$DROPIN" ]]; then backup=$(mktemp); cp -a "$DROPIN" "$backup"; fi
restore() {
  if [[ -n "$backup" ]]; then cp -a "$backup" "$DROPIN"; else rm -f "$DROPIN"; fi
  reload_sshd || true
}

if [[ "$MODE" == unlock ]]; then
  rm -f "$DROPIN"
  "$sshd_bin" -t || { restore; die "sshd rejected the configuration, previous state restored"; }
  reload_sshd
  log "OK: root SSH by key is allowed again (effective PermitRootLogin: $(effective))"
  exit 0
fi

# --- guards: do not close the last way in -------------------------------------------------------
id "$ADMIN_USER" >/dev/null 2>&1 || die "admin user ${ADMIN_USER} does not exist (run server-init first)"
home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
keys=$(grep -cE '^(ssh-|ecdsa-|sk-)' "${home}/.ssh/authorized_keys" 2>/dev/null || true)
(( ${keys:-0} > 0 )) || die "refused: ${ADMIN_USER} has no SSH key in ${home}/.ssh/authorized_keys, root would be the only way in"
if command -v runuser >/dev/null 2>&1; then
  runuser -u "$ADMIN_USER" -- sudo -n true >/dev/null 2>&1 || die "refused: sudo -n true does not work for ${ADMIN_USER}"
else
  su -s /bin/bash "$ADMIN_USER" -c 'sudo -n true' >/dev/null 2>&1 || die "refused: sudo -n true does not work for ${ADMIN_USER}"
fi
[[ -d "$(dirname "$DROPIN")" ]] || die "$(dirname "$DROPIN") missing"
grep -qiE '^\s*Include\s+/etc/ssh/sshd_config.d/' "$SSHD_CONFIG" || die "${SSHD_CONFIG} does not include sshd_config.d"
port_before=$("$sshd_bin" -T 2>/dev/null | awk '$1 == "port" { print $2 }' | tr '\n' ' ')

printf '# Managed by server/lock-root.sh. Loads before 00-hardening.conf because the first match wins.\nPermitRootLogin no\n' > "${DROPIN}.new"
chmod 0600 "${DROPIN}.new"
mv "${DROPIN}.new" "$DROPIN"
if command -v restorecon >/dev/null 2>&1; then restorecon "$DROPIN" || true; fi
"$sshd_bin" -t || { restore; die "sshd rejected the configuration, previous state restored"; }
reload_sshd
if [[ "$(effective)" != no ]]; then
  restore
  die "sshd still reports PermitRootLogin $(effective) (another file wins?), previous state restored"
fi
port_after=$("$sshd_bin" -T 2>/dev/null | awk '$1 == "port" { print $2 }' | tr '\n' ' ')
[[ "$port_before" == "$port_after" ]] || log "WARN: the listening ports differ before/after (${port_before}/${port_after}); check sshd -T"
rm -f "${backup:-}"
log "OK: root SSH is closed. Log in as ${ADMIN_USER}. Undo: sudo bash $0 --unlock-root"
