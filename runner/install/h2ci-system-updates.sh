#!/usr/bin/env bash
# Install the h2ci-specific extensions on an existing managed h2ci deployment.
set -euo pipefail
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
[[ $EUID == 0 && -f /etc/systemd/system/h2ci-daily-maintenance.service ]] || {
  printf '%s\n' 'Requires root and an existing managed h2ci deployment.' >&2
  exit 1
}

install -d -m 0755 /etc/h2ci-container-update /etc/systemd/system/runner-engine-update.service.d
install -m 0644 "$root/runner/config/h2ci-container-images.json" /etc/h2ci-container-update/images.json
for script in h2ci-container-update h2ci-maintenance; do
  install -m 0755 "$root/runner/scripts/$script" "/usr/local/libexec/$script"
done
install -m 0755 "$root/server/server-update.sh" /usr/local/sbin/server-update
install -m 0755 "$root/runner/scripts/h2ci-telegram-notify" /usr/local/bin/h2ci-telegram-notify
install -m 0644 "$root/runner/systemd/h2ci-server-update.service" /etc/systemd/system/
install -m 0644 "$root/runner/systemd/runner-engine-update.service.d/h2ci.conf" \
  /etc/systemd/system/runner-engine-update.service.d/
if command -v restorecon >/dev/null; then
  restorecon -R /etc/h2ci-container-update /etc/systemd/system/runner-engine-update.service.d \
    /etc/systemd/system/h2ci-server-update.service /usr/local/libexec/h2ci-container-update \
    /usr/local/libexec/h2ci-maintenance /usr/local/bin/h2ci-telegram-notify /usr/local/sbin/server-update
fi
systemctl daemon-reload
