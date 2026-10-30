#!/usr/bin/env bash
# Weekly upgrade of Docker CE and GitLab Runner, only while no CI job runs.
# The distro's automatic updates (dnf-automatic security only, unattended-upgrades) skip these vendor repos, so
# without this they would never be updated. Docker is restarted first, then gitlab-runner; both must be active
# afterwards. The result is one line in /var/log/runner-engine-update.log, which health reads.
# Env: DRY_RUN=1 shows the plan only.
set -Eeuo pipefail

LOG="${ENGINE_UPDATE_LOG:-/var/log/runner-engine-update.log}"   # overridable for tests
DRY_RUN="${DRY_RUN:-0}"
PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin gitlab-runner)

note() { logger -t runner-engine-update -- "$*" 2>/dev/null || true; echo "$(date -u +%FT%TZ) $*" | tee -a "$LOG"; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0 [--dry-run]   upgrades ${PKGS[*]} when no CI job runs"
  exit 0
fi
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
exec 9>/run/runner-engine-update.lock
flock -n 9 || { note "SKIP another update is running"; exit 0; }

# A docker error is not "no jobs": updating then could kill running jobs.
if ! jobs=$(docker ps -q --filter "label=com.gitlab.gitlab-runner.managed=true" 2>/dev/null); then
  note "SKIP docker does not answer, cannot tell whether jobs run"
  exit 0
fi
if [[ -n "$jobs" ]]; then
  note "SKIP $(wc -w <<<"$jobs") CI job(s) running, will retry next week"
  exit 0
fi

installed=()
if command -v dnf >/dev/null 2>&1; then
  for p in "${PKGS[@]}"; do rpm -q "$p" >/dev/null 2>&1 && installed+=("$p"); done
  upgrade() { dnf -y -q upgrade "${installed[@]}"; }
  pending() { dnf -q check-update "${installed[@]}" >/dev/null 2>&1; [[ $? -eq 100 ]]; }
elif command -v apt-get >/dev/null 2>&1; then
  for p in "${PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 && installed+=("$p"); done
  upgrade() { DEBIAN_FRONTEND=noninteractive apt-get install -y -q --only-upgrade "${installed[@]}"; }
  pending() { apt-get update -q >/dev/null 2>&1; apt-get -s install --only-upgrade "${installed[@]}" 2>/dev/null | grep -q '^Inst '; }
else
  note "FAIL no supported package manager"
  exit 1
fi
(( ${#installed[@]} )) || { note "SKIP none of the packages is installed"; exit 0; }

if ! pending; then
  note "OK nothing to upgrade (${installed[*]})"
  exit 0
fi
if [[ "$DRY_RUN" == 1 ]]; then
  note "DRY-RUN would upgrade ${installed[*]}"
  exit 0
fi

before=$(for p in "${installed[@]}"; do if command -v rpm >/dev/null 2>&1; then rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE} ' "$p"; else dpkg-query -W -f='${Package}-${Version} ' "$p"; fi; done)
if ! upgrade >>"$LOG" 2>&1; then
  note "FAIL package upgrade failed, see ${LOG}"
  exit 1
fi
systemctl restart docker
sleep 5
systemctl restart gitlab-runner
sleep 5
bad=""
for s in docker gitlab-runner; do systemctl is-active --quiet "$s" || bad+=" $s"; done
# The isolation rules live in iptables; reapply them after the Docker restart.
if systemctl cat ci-job-isolation.service >/dev/null 2>&1; then systemctl restart ci-job-isolation.service || bad+=" ci-job-isolation"; fi
if [[ -n "$bad" ]]; then
  note "FAIL not active after the upgrade:${bad}; was: ${before}"
  exit 1
fi
note "OK upgraded ${installed[*]}; was: ${before}"
