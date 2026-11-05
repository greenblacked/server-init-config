#!/usr/bin/env bash
# Weekly upgrade of Docker CE and GitLab Runner while no CI job runs (GitLab jobs, GitHub runner pods): runner and github-runner-ctl
# stopped gracefully, jobs checked again, Docker upgraded and restarted, gitlab-runner last; a job in between: all started again.
# One result line in /var/log/runner-engine-update.log. Env: DRY_RUN=1 plan only; STOP_WAIT seconds for the graceful stop (1800).
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
# A docker error is not "no jobs".
job_ids() { docker ps -q --filter "label=com.gitlab.gitlab-runner.managed=true" && docker ps -q --filter "label=io.server-init.github-runner=job"; }
if ! jobs=$(job_ids 2>/dev/null); then
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
docker_pkgs=(); runner_pkgs=()
for p in "${installed[@]}"; do if [[ "$p" == gitlab-runner ]]; then runner_pkgs+=("$p"); else docker_pkgs+=("$p"); fi; done
if [[ "$DRY_RUN" == 1 ]]; then
  note "DRY-RUN would upgrade ${installed[*]}"
  exit 0
fi
before=$(for p in "${installed[@]}"; do if command -v rpm >/dev/null 2>&1; then rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE} ' "$p"; else dpkg-query -W -f='${Package}-${Version} ' "$p"; fi; done)
# From here whatever happens: start the runner again.
runner_stopped=0 ctl_stopped=0
ctl_back() { if (( ctl_stopped )); then systemctl start --no-block github-runner-ctl >/dev/null 2>&1 || true; fi; }
runner_back() { systemctl start --no-block gitlab-runner >/dev/null 2>&1 || true; ctl_back; }
trap '[[ $runner_stopped -eq 1 ]] && runner_back' EXIT
runner_state() { systemctl show -p ActiveState --value gitlab-runner 2>/dev/null || echo unknown; }
# SIGQUIT = graceful stop (jobs finish). Returns 1 when still running after STOP_WAIT.
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
no_jobs() { local j; j=$(job_ids 2>/dev/null) && [[ -z "$j" ]]; }
# SIGTERM would end jobs; TimeoutStopSec=infinity: systemd never SIGKILLs the runner.
if ! grep -qs '^KillSignal=SIGQUIT' "$DROPIN" 2>/dev/null || ! grep -qs '^TimeoutStopSec=infinity' "$DROPIN" 2>/dev/null; then
  mkdir -p "$(dirname "$DROPIN")"
  printf '[Service]\nKillSignal=SIGQUIT\nTimeoutStopSec=infinity\n' > "$DROPIN"
  systemctl daemon-reload
fi
runner_stopped=1
# no new GitHub pod during the upgrade
if systemctl is-active --quiet github-runner-ctl 2>/dev/null; then systemctl stop github-runner-ctl && ctl_stopped=1; fi
if ! stop_runner_wait; then
  note "SKIP gitlab-runner did not stop within ${STOP_WAIT}s (jobs still running), will retry next week"
  exit 0
fi
if ! no_jobs; then
  note "SKIP a CI job appeared or docker does not answer after the runner stopped; will retry next week"
  exit 0
fi
if (( ${#docker_pkgs[@]} )) && ! upgrade "${docker_pkgs[@]}" >>"$LOG" 2>&1; then
  note "FAIL Docker package upgrade failed, see ${LOG}"
  exit 1
fi
# a package scriptlet may have started the runner and it may have taken a job
if [[ "$(runner_state)" != inactive ]]; then
  if ! stop_runner_wait; then
    note "SKIP Docker packages upgraded, but gitlab-runner is busy again; Docker not restarted (retry next week)"
    exit 0
  fi
fi
if ! no_jobs; then
  note "SKIP Docker packages upgraded, but a CI job runs or docker does not answer; Docker not restarted (retry next week)"
  exit 0
fi
bad=""
if (( ${#docker_pkgs[@]} )); then
  systemctl restart docker
  sleep 5
  # reapply the isolation rules
  if systemctl cat ci-job-isolation.service >/dev/null 2>&1; then systemctl restart ci-job-isolation.service || bad+=" ci-job-isolation"; fi
fi
if (( ${#runner_pkgs[@]} )) && ! upgrade "${runner_pkgs[@]}" >>"$LOG" 2>&1; then
  note "FAIL gitlab-runner upgrade failed, see ${LOG}"
  exit 1
fi
systemctl start gitlab-runner || true
runner_stopped=0
ctl_back
sleep 5
for s in docker gitlab-runner; do systemctl is-active --quiet "$s" || bad+=" $s"; done
if [[ -n "$bad" ]]; then
  note "FAIL not active after the upgrade:${bad}; was: ${before}"
  exit 1
fi
note "OK upgraded ${installed[*]}; was: ${before}"
