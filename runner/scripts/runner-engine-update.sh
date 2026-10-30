#!/usr/bin/env bash
# Weekly upgrade of Docker CE and GitLab Runner, only while no CI job runs (the distro's automatic updates skip these
# vendor repos). The runner is stopped gracefully (no new job, running jobs finish; KillSignal=SIGQUIT), the job list is
# checked again, the Docker packages are upgraded and Docker restarted, then gitlab-runner is upgraded last and started
# (separate transactions, so no Docker restart happens after the runner is back). Runner and jobs are checked again
# before the Docker restart. If a job is there, the runner is started again and nothing (more) is changed.
# The result is one line in /var/log/runner-engine-update.log, which health reads.
# Env: DRY_RUN=1 shows the plan only; STOP_WAIT seconds to wait for the graceful stop (default 1800).
set -Eeuo pipefail

LOG="${ENGINE_UPDATE_LOG:-/var/log/runner-engine-update.log}"   # overridable for tests
DRY_RUN="${DRY_RUN:-0}"
STOP_WAIT="${STOP_WAIT:-1800}"
DROPIN="${ENGINE_UPDATE_DROPIN:-/etc/systemd/system/gitlab-runner.service.d/graceful-stop.conf}"
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
  upgrade() { dnf -y -q upgrade "$@"; }
  pending() { dnf -q check-update "${installed[@]}" >/dev/null 2>&1; [[ $? -eq 100 ]]; }
elif command -v apt-get >/dev/null 2>&1; then
  for p in "${PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 && installed+=("$p"); done
  upgrade() { DEBIAN_FRONTEND=noninteractive apt-get install -y -q --only-upgrade "$@"; }
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
# Two transactions: Docker packages first (they restart Docker), gitlab-runner last (its scriptlet starts the runner).
docker_pkgs=(); runner_pkgs=()
for p in "${installed[@]}"; do if [[ "$p" == gitlab-runner ]]; then runner_pkgs+=("$p"); else docker_pkgs+=("$p"); fi; done
if [[ "$DRY_RUN" == 1 ]]; then
  note "DRY-RUN would upgrade ${installed[*]}"
  exit 0
fi

before=$(for p in "${installed[@]}"; do if command -v rpm >/dev/null 2>&1; then rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE} ' "$p"; else dpkg-query -W -f='${Package}-${Version} ' "$p"; fi; done)

# From here the runner may be stopped; whatever happens, leave it running again. --no-block: if the runner is still
# finishing a job, systemd runs this start after the stop completes, and this script does not wait for it.
runner_stopped=0
runner_back() { systemctl start --no-block gitlab-runner >/dev/null 2>&1 || true; }
trap '[[ $runner_stopped -eq 1 ]] && runner_back' EXIT

# `systemctl is-active` is false while a unit is deactivating, so the state is read with `show`.
runner_state() { systemctl show -p ActiveState --value gitlab-runner 2>/dev/null || echo unknown; }
# SIGQUIT is the runner's graceful stop: no new job, running jobs finish. Returns 1 when it is still running after STOP_WAIT.
stop_runner_wait() {
  local waited=0 st
  systemctl stop --no-block gitlab-runner
  while :; do
    st=$(runner_state)
    [[ "$st" == inactive || "$st" == failed ]] && return 0
    (( waited >= STOP_WAIT )) && return 1
    sleep 5
    waited=$((waited + 5))
  done
}
no_jobs() { local j; j=$(docker ps -q --filter "label=com.gitlab.gitlab-runner.managed=true" 2>/dev/null) && [[ -z "$j" ]]; }

# The default SIGTERM ends running jobs. TimeoutStopSec=infinity: systemd never SIGKILLs a runner that is still
# waiting for a job; this script gives up waiting on its own (STOP_WAIT) and leaves the stop to finish by itself.
if ! grep -qs '^KillSignal=SIGQUIT' "$DROPIN" 2>/dev/null || ! grep -qs '^TimeoutStopSec=infinity' "$DROPIN" 2>/dev/null; then
  mkdir -p "$(dirname "$DROPIN")"
  printf '[Service]\nKillSignal=SIGQUIT\nTimeoutStopSec=infinity\n' > "$DROPIN"
  systemctl daemon-reload
fi
runner_stopped=1
if ! stop_runner_wait; then
  # Starting a unit that is still stopping queues the start behind the stop: the runner comes back when the job ends.
  note "SKIP gitlab-runner did not stop within ${STOP_WAIT}s (jobs still running); it starts again once it has stopped, will retry next week"
  exit 0
fi
if ! no_jobs; then
  note "SKIP a CI job appeared or docker does not answer after the runner stopped; runner started again, will retry next week"
  exit 0
fi

# Docker packages first, runner stopped: their own Docker restart finds no job.
if (( ${#docker_pkgs[@]} )) && ! upgrade "${docker_pkgs[@]}" >>"$LOG" 2>&1; then
  note "FAIL Docker package upgrade failed, see ${LOG}"
  exit 1
fi
# A package scriptlet may have started the runner (a unit file in /etc cannot be masked from /run), and it may have
# taken a job. Restarting Docker under a running job would kill it, so stop the runner again and look once more.
if [[ "$(runner_state)" != inactive ]]; then
  if ! stop_runner_wait; then
    note "SKIP Docker packages upgraded, but gitlab-runner is busy again; Docker not restarted, gitlab-runner not upgraded (new version active after the next restart or reboot, retry next week)"
    exit 0
  fi
fi
if ! no_jobs; then
  note "SKIP Docker packages upgraded, but a CI job runs or docker does not answer; Docker not restarted, gitlab-runner not upgraded (retry next week)"
  exit 0
fi
bad=""
if (( ${#docker_pkgs[@]} )); then
  systemctl restart docker
  sleep 5
  # The isolation rules live in iptables; reapply them after the Docker restart.
  if systemctl cat ci-job-isolation.service >/dev/null 2>&1; then systemctl restart ci-job-isolation.service || bad+=" ci-job-isolation"; fi
fi
if (( ${#runner_pkgs[@]} )) && ! upgrade "${runner_pkgs[@]}" >>"$LOG" 2>&1; then
  note "FAIL gitlab-runner upgrade failed, see ${LOG}"
  exit 1
fi
systemctl start gitlab-runner || true
runner_stopped=0
sleep 5
for s in docker gitlab-runner; do systemctl is-active --quiet "$s" || bad+=" $s"; done
if [[ -n "$bad" ]]; then
  note "FAIL not active after the upgrade:${bad}; was: ${before}"
  exit 1
fi
note "OK upgraded ${installed[*]}; was: ${before}"
