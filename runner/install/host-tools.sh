#!/usr/bin/env bash
# Install health (plus the sudo secure_path fix so `sudo health` works), cleanup and disk guard scripts plus their systemd timers,
# the job isolation rules (CI jobs cannot reach the metadata service or host services) and the weekly Docker/GitLab Runner update.
# Use on servers built without the cloud-init in this repo, or to update the scripts.
set -Eeuo pipefail
# shellcheck source=../../common/lib.sh
source "$(dirname "$0")/../../common/lib.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0  installs common/health, cleanup, disk guard and systemd timers"
  exit 0
fi
require_root

install -m 0755 "$REPO_ROOT/common/health" /usr/local/bin/health
restorecon_if /usr/local/bin/health
for f in runner-weekly-cleanup.sh runner-disk-guard.sh runner-engine-update.sh ci-job-isolation.sh; do
  install -m 0755 "$REPO_ROOT/runner/scripts/$f" "/usr/local/bin/$f"
  restorecon_if "/usr/local/bin/$f"
done
ensure_secure_path

for u in runner-weekly-cleanup.service runner-weekly-cleanup.timer runner-disk-guard.service runner-disk-guard.timer runner-engine-update.service runner-engine-update.timer ci-job-isolation.service; do
  install -m 0644 "$REPO_ROOT/runner/systemd/$u" "/etc/systemd/system/$u"
  restorecon_if "/etc/systemd/system/$u"
done

systemctl daemon-reload
systemctl enable --now runner-weekly-cleanup.timer runner-disk-guard.timer runner-engine-update.timer
# Needs Docker (the DOCKER-USER chain). On a host without it the unit is enabled and applies at the next Docker start.
if systemctl is-active --quiet docker; then systemctl enable --now ci-job-isolation.service; else systemctl enable ci-job-isolation.service; fi

DRY_RUN=1 /usr/local/bin/runner-weekly-cleanup.sh >/dev/null
systemctl list-timers 'runner-*' --no-pager
log "OK: run 'health' for a full report (it uses sudo itself when needed)"
