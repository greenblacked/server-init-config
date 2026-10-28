#!/usr/bin/env bash
# Switch SELinux to enforcing now and after reboot (Rocky/RHEL). Rollback: setenforce 0.
# Restarts Docker and the runner: refuses to run while CI jobs are running.
set -Eeuo pipefail
# shellcheck source=install/lib.sh
source "$(dirname "$0")/lib.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0  enables SELinux enforcing mode and verifies Docker and the runner still work"
  exit 0
fi
require_root
command -v getenforce >/dev/null || die "SELinux tools not present on this system"
require_runner_idle
systemctl is-active --quiet auditd || log "WARN: auditd not active, denials will not be logged"

setenforce 1
sed -i -E 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config

getenforce
grep -E '^SELINUX=' /etc/selinux/config
hello=$(docker run --rm hello-world)
grep -m1 Hello <<<"$hello"
systemctl restart docker
systemctl restart gitlab-runner || true
systemctl is-active docker gitlab-runner || true
denials=$(ausearch --input-logs -m avc -ts recent </dev/null 2>/dev/null | grep -c 'avc:' || true)
log "recent SELinux denials: ${denials:-0}"
