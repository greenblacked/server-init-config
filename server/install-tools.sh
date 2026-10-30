#!/usr/bin/env bash
# Install the server maintenance tools from a repo checkout (run server-init first: it installs server-cleanup):
#   srv, server-update, server-notify, server-disk-guard, health and its brief timer, the login summary.
# Timers: server-update.timer (daily security updates), server-disk-guard.timer (every 30 min),
# server-health-brief.timer (every 15 min). Safe to rerun; rerun after editing /etc/server-init.conf.
# These are not embedded in the Cloud config files (Hetzner's user-data limit is 32 KiB), hence a separate step.
set -Eeuo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: sudo $0   installs the maintenance tools and timers; settings are read from /etc/server-init.conf"
  exit 0
fi
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root: sudo $0" >&2; exit 1; }
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF=/etc/server-init.conf
for f in server-update server-notify server-disk-guard srv server-login; do
  [[ -f "$SRC/$f.sh" ]] || { echo "ERROR: $SRC/$f.sh not found; run this from a checkout of the repo" >&2; exit 1; }
  bash -n "$SRC/$f.sh" || { echo "ERROR: $f.sh has a syntax error" >&2; exit 1; }
done
[[ -x /usr/local/sbin/server-cleanup ]] || { echo "ERROR: /usr/local/sbin/server-cleanup missing: run the current server-init script first (INSTALL_CLEANUP=1)" >&2; exit 1; }

# shellcheck source=/dev/null
[[ -r $CONF ]] && . "$CONF"
UPDATE_SCHEDULE="${UPDATE_SCHEDULE:-*-*-* 04:30}"
LOGIN_SUMMARY="${LOGIN_SUMMARY:-1}"
if [[ "$UPDATE_SCHEDULE" != off ]] && command -v systemd-analyze >/dev/null 2>&1 && ! systemd-analyze calendar "$UPDATE_SCHEDULE" >/dev/null 2>&1; then
  echo "WARN: invalid UPDATE_SCHEDULE '$UPDATE_SCHEDULE', using '*-*-* 04:30'" >&2
  UPDATE_SCHEDULE="*-*-* 04:30"
fi

put() { # put PATH MODE: write stdin to PATH only when it changed
  local tmp; tmp=$(mktemp); cat > "$tmp"
  if [[ -f "$1" ]] && cmp -s "$tmp" "$1"; then rm -f "$tmp"; return 0; fi
  install -D -m "$2" "$tmp" "$1"; rm -f "$tmp"
}
unit() { systemctl cat "$1" >/dev/null 2>&1; }

if [[ -f $CONF ]] && ! grep -q '^# Maintenance tools' "$CONF"; then
  cat >> "$CONF" <<'CONF'

# Maintenance tools (server/install-tools.sh): defaults shown; uncomment to change, then rerun install-tools.sh.
#UPDATE_SCHEDULE="*-*-* 04:30"   # systemd OnCalendar value; "off" keeps dnf-automatic instead of server-update
#AUTO_REBOOT=0                   # 1: the daily update reboots by itself when a reboot is needed
#LOGIN_SUMMARY=1                 # 0: no health summary when the admin user logs in
#DISK_CLEAN_THRESHOLD=85         # run server-cleanup when / is this percent full
#DISK_CLEAN_COOLDOWN_H=6         # but at most once in this many hours
CONF
fi

for t in server-update server-notify server-disk-guard; do install -D -m 0755 "$SRC/$t.sh" "/usr/local/sbin/$t"; done
install -D -m 0755 "$SRC/srv.sh" /usr/local/bin/srv
"$SRC/install-health.sh" >/dev/null
install -d -m 0755 /var/lib/server-health

# Notification settings: a commented template, created once, root only.
install -d -m 0755 /etc/server-init.d
if [[ ! -e /etc/server-init.d/notify.env ]]; then
  ( umask 077; cat > /etc/server-init.d/notify.env <<'ENV'
# Notifications from server-update, server-cleanup, server-disk-guard and health. Off until a channel is set.
# Keep this file root-only (mode 0600); it is ignored otherwise. Test with: srv notify-test
# Telegram (the bot token is part of the request URL; it is passed to curl on stdin, not in argv)
#TELEGRAM_BOT_TOKEN=
#TELEGRAM_CHAT_ID=
# Slack incoming webhook
#SLACK_WEBHOOK_URL=
# Mail (needs a local mail or sendmail command)
#MAIL_TO=
ENV
  )
fi
chmod 0600 /etc/server-init.d/notify.env

if [[ "$LOGIN_SUMMARY" == 1 ]]; then install -D -m 0644 "$SRC/server-login.sh" /etc/profile.d/91-server-login.sh
else rm -f /etc/profile.d/91-server-login.sh; fi

put /etc/systemd/system/server-update.service 0644 <<'EOF'
[Unit]
Description=Server update (security updates, cleanup, reboot check)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/server-update --security --scheduled
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=2h
EOF
put /etc/systemd/system/server-update.timer 0644 <<EOF
[Unit]
Description=Daily server update

[Timer]
OnCalendar=${UPDATE_SCHEDULE}
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
put /etc/systemd/system/server-disk-guard.service 0644 <<'EOF'
[Unit]
Description=Server disk guard (cleanup when the root disk is nearly full)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/server-disk-guard
Nice=19
IOSchedulingClass=idle
ProtectHome=read-only
NoNewPrivileges=yes
EOF
put /etc/systemd/system/server-disk-guard.timer 0644 <<'EOF'
[Unit]
Description=Server disk guard every 30 minutes

[Timer]
OnBootSec=10min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
EOF
put /etc/systemd/system/server-health-brief.service 0644 <<'EOF'
[Unit]
Description=Server health summary cache (shown at login)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/health --brief --write
Nice=19
IOSchedulingClass=idle
EOF
put /etc/systemd/system/server-health-brief.timer 0644 <<'EOF'
[Unit]
Description=Refresh the server health summary every 15 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload

# One updater only: dnf-automatic and server-update.timer would both run dnf upgrade (dnf lock races, double
# logs). server-update also cleans up, can reboot, and notifies, so it takes over; UPDATE_SCHEDULE=off hands it back.
automatic_timers=(dnf-automatic.timer dnf-automatic-install.timer dnf-automatic-download.timer dnf-automatic-notifyonly.timer dnf5-automatic.timer)
if [[ "$UPDATE_SCHEDULE" == off ]]; then
  systemctl disable --now server-update.timer 2>/dev/null || true
  for t in dnf5-automatic.timer dnf-automatic.timer; do
    if unit "$t"; then systemctl enable --now "$t" && break; fi
  done
else
  systemctl enable --now server-update.timer
  for t in "${automatic_timers[@]}"; do
    if unit "$t"; then systemctl disable --now "$t" 2>/dev/null || true; fi
  done
fi
systemctl enable --now server-disk-guard.timer server-health-brief.timer
systemctl start --no-block server-health-brief.service || true
echo "installed: srv, server-update, server-notify, server-disk-guard, health, timers (srv timers). Try: srv status"
