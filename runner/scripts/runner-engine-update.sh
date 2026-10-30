#!/usr/bin/env bash
# Weekly upgrade of Docker CE and GitLab Runner, only while no CI job runs.
# The distro's automatic updates (dnf-automatic security only, unattended-upgrades) skip these vendor repos, so
# without this they would never be updated. No job is started or killed by the upgrade: the runner is first stopped
# gracefully (it takes no new job and lets a job that is already running finish; the unit gets KillSignal=SIGQUIT),
# the job list is checked again, and only then are the packages upgraded. A package scriptlet may start the runner
# again, so the runner and the job list are checked once more right before Docker is restarted. Docker is restarted,
# then gitlab-runner is started; both must be active afterwards. If a job is still there, the runner is started again
# and nothing is changed (or, after the package upgrade, only the Docker restart is left out).
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

if ! upgrade >>"$LOG" 2>&1; then
  note "FAIL package upgrade failed, see ${LOG}"
  exit 1
fi
# A package scriptlet may have started the runner (a unit file in /etc cannot be masked from /run), and it may have
# taken a job. Restarting Docker under a running job would kill it, so stop the runner again and look once more.
if [[ "$(runner_state)" != inactive ]]; then
  if ! stop_runner_wait; then
    note "SKIP packages upgraded, but gitlab-runner is busy again; Docker not restarted (new version active after its next restart or reboot)"
    exit 0
  fi
fi
if ! no_jobs; then
  note "SKIP packages upgraded, but a CI job runs or docker does not answer; Docker not restarted (new version active after its next restart or reboot)"
  exit 0
fi
systemctl restart docker
sleep 5
# The isolation rules live in iptables; reapply them after the Docker restart.
bad=""
if systemctl cat ci-job-isolation.service >/dev/null 2>&1; then systemctl restart ci-job-isolation.service || bad+=" ci-job-isolation"; fi
systemctl start gitlab-runner || true
runner_stopped=0
sleep 5
for s in docker gitlab-runner; do systemctl is-active --quiet "$s" || bad+=" $s"; done
if [[ -n "$bad" ]]; then
  note "FAIL not active after the upgrade:${bad}; was: ${before}"
  exit 1
fi
note "OK upgraded ${installed[*]}; was: ${before}"
