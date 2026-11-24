#!/usr/bin/env bash
# Weekly upgrade of Docker CE and GitLab Runner while no CI job runs (GitLab jobs, GitHub runner pods): runner and github-runner-ctl
# stopped gracefully, jobs checked again, Docker upgraded and restarted, gitlab-runner last; a job in between: all started again.
# One result line in /var/log/runner-engine-update.log. Env: DRY_RUN=1 plan only; STOP_WAIT seconds for the graceful stop (1800).
# When Docker packages were changed and the CI services cannot be restored safely, they stay stopped, the run FAILs (exit 1) and
# a "held" marker is written; every later run first tries to recover from it (isolation, Docker, no jobs, services back).
set -Eeuo pipefail
LOG="${ENGINE_UPDATE_LOG:-/var/log/runner-engine-update.log}"   # overridable for tests
DRY_RUN="${DRY_RUN:-0}"
STOP_WAIT="${STOP_WAIT:-1800}"
DROPIN="${ENGINE_UPDATE_DROPIN:-/etc/systemd/system/gitlab-runner.service.d/graceful-stop.conf}"
LOCK_FILE="${ENGINE_UPDATE_LOCK:-/run/runner-engine-update.lock}"
HELD_FILE="${ENGINE_UPDATE_HELD:-/var/lib/runner-engine-update/held}"   # overridable for tests
PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin gitlab-runner)
last_note=""
note() { last_note="$*"; logger -t runner-engine-update -- "$*" 2>/dev/null || true; echo "$(date -u +%FT%TZ) $*" | tee -a "$LOG"; }
# A run that leaves the CI services stopped records why; the next run recovers or reports it (see recover_held).
# It runs from the EXIT trap and must never change the exit code of the run (the services stay stopped either way).
write_held() {
  local reason=${last_note:-unknown} tmp
  mkdir -p "$(dirname "$HELD_FILE")" || return 0
  tmp=$(mktemp "$HELD_FILE.XXXXXX") || return 0
  printf 'time=%s\nreason=%s\nctl_stopped=%s\n' "$(date -u +%FT%TZ)" "$reason" "${ctl_stopped:-0}" > "$tmp" || { rm -f "$tmp"; return 0; }
  chmod 0644 "$tmp"   # no secret in it; health prints the reason as a normal user
  mv -f "$tmp" "$HELD_FILE" || { rm -f "$tmp"; return 0; }
  note "HELD CI services stay stopped; the next run re-checks isolation and restarts them (marker ${HELD_FILE})"
}

# Probe contract: 0 = updates available, 1 = none, 2 = package metadata/query error.
probe_failed() {
  local command=$1 rc=$2 output=$3
  if [[ -n "$output" ]]; then
    printf '%s failed (exit %s):\n%s\n' "$command" "$rc" "$output" >&2
  else
    printf '%s failed (exit %s)\n' "$command" "$rc" >&2
  fi
}
pending_dnf() {
  local output rc
  if output=$(dnf -q check-update "$@" 2>&1); then rc=0; else rc=$?; fi
  case $rc in
    0) return 1 ;;
    100) return 0 ;;
    *) probe_failed 'dnf -q check-update' "$rc" "$output"; return 2 ;;
  esac
}
pending_apt() {
  local output rc
  if output=$(apt-get update -q --error-on=any 2>&1); then :; else
    rc=$?; probe_failed 'apt-get update -q' "$rc" "$output"; return 2
  fi
  if output=$(apt-get -s install --only-upgrade "$@" 2>&1); then :; else
    rc=$?; probe_failed 'apt-get -s install --only-upgrade' "$rc" "$output"; return 2
  fi
  if grep -q '^Inst ' <<<"$output"; then return 0; fi
  return 1
}
ensure_isolation() {
  if ! systemctl cat ci-job-isolation.service >/dev/null 2>&1; then
    note "FAIL ci-job-isolation.service missing; refusing to restart CI services"
    return 1
  fi
  if ! systemctl restart ci-job-isolation.service; then
    note "FAIL ci-job-isolation.service restart failed; refusing to restart CI services"
    return 1
  fi
  if ! systemctl is-active --quiet ci-job-isolation.service; then
    note "FAIL ci-job-isolation.service is not active after restart; refusing to restart CI services"
    return 1
  fi
}
can_restart_services() {
  (( restart_allowed )) || return 1
  if (( isolation_required )) && ! systemctl is-active --quiet ci-job-isolation.service; then
    restart_allowed=0
    note "FAIL ci-job-isolation.service is no longer active; refusing to restart CI services"
    return 1
  fi
}
ctl_back() {
  if (( ctl_stopped )) && can_restart_services; then
    systemctl start --no-block github-runner-ctl >/dev/null 2>&1 || true
  fi
}
runner_back() {
  if can_restart_services; then
    systemctl start --no-block gitlab-runner >/dev/null 2>&1 || true
    ctl_back
  fi
}
# A docker error is not "no jobs".
job_ids() { docker ps -q --filter "label=com.gitlab.gitlab-runner.managed=true" && docker ps -q --filter "label=io.server-init.github-runner=job"; }
cleanup_services() {
  if (( runner_stopped )); then
    if can_restart_services; then runner_back; else write_held || true; fi
  fi
}
# A marker from an earlier fail-closed run means the CI services were left stopped. Restart them only after the checks the normal
# path needs (isolation rebuilt and active, Docker answers, no job); otherwise stay held and fail so that it is noticed.
# The services are only stopped, not disabled, so a reboot brings them back: with both running (and the isolation active) the marker
# is stale and is cleared without touching the isolation rules under live jobs; running without isolation is a loud failure.
recover_held() {
  [[ -e "$HELD_FILE" ]] || return 0
  local reason jobs running=1
  reason=$(sed -n 's/^reason=//p' "$HELD_FILE" 2>/dev/null | head -1)
  systemctl is-active --quiet gitlab-runner || running=0
  if grep -qs '^ctl_stopped=1$' "$HELD_FILE" && ! systemctl is-active --quiet github-runner-ctl; then running=0; fi
  if (( running )); then
    if [[ "$DRY_RUN" == 1 ]]; then
      note "DRY-RUN held marker is stale: the CI services are already running"
      return 0
    fi
    if systemctl is-active --quiet ci-job-isolation.service; then
      rm -f "$HELD_FILE"
      note "OK held marker cleared: services already running (${reason:-unknown})"
      return 0
    fi
    note "FAIL CI services are running but ci-job-isolation.service is not active; marker kept (${reason:-unknown})"
    return 1
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    note "DRY-RUN CI services are held since $(sed -n 's/^time=//p' "$HELD_FILE" | head -1) (${reason:-unknown}); a real run would re-check isolation and restart them"
    return 0
  fi
  note "HELD marker found (${reason:-unknown}); trying to restore the CI services"
  if ! ensure_isolation; then
    note "FAIL CI services still held: isolation is not restored"
    return 1
  fi
  if ! jobs=$(job_ids 2>/dev/null); then
    note "FAIL CI services still held: docker does not answer"
    return 1
  fi
  if [[ -n "$jobs" ]]; then
    note "FAIL CI services still held: $(wc -w <<<"$jobs") CI job(s) running"
    return 1
  fi
  systemctl start gitlab-runner || true
  if grep -qs '^ctl_stopped=1$' "$HELD_FILE"; then systemctl start github-runner-ctl || true; fi
  sleep 5
  if ! systemctl is-active --quiet gitlab-runner; then
    note "FAIL CI services still held: gitlab-runner did not start"
    return 1
  fi
  if grep -qs '^ctl_stopped=1$' "$HELD_FILE" && ! systemctl is-active --quiet github-runner-ctl; then
    note "FAIL CI services still held: github-runner-ctl did not start"
    return 1
  fi
  rm -f "$HELD_FILE"
  note "OK held CI services restored (${reason:-unknown})"
}
main() {
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0 [--dry-run]   upgrades ${PKGS[*]} when no CI job runs"
  exit 0
fi
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
exec 9>"$LOCK_FILE"
flock -n 9 || { note "SKIP another update is running"; exit 0; }
recover_held || exit 1
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
elif command -v apt-get >/dev/null 2>&1; then
  for p in "${PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 && installed+=("$p"); done
  upgrade() { DEBIAN_FRONTEND=noninteractive apt-get install -y -q --only-upgrade "$@"; }
else
  note "FAIL no supported package manager"
  exit 1
fi
(( ${#installed[@]} )) || { note "SKIP none of the packages is installed"; exit 0; }
has_updates=0 probe_rc=0
if command -v dnf >/dev/null 2>&1; then
  if pending_dnf "${installed[@]}"; then has_updates=1; else probe_rc=$?; fi
else
  if pending_apt "${installed[@]}"; then has_updates=1; else probe_rc=$?; fi
fi
if [[ ${probe_rc:-1} -eq 2 ]]; then
  note "FAIL package update probe failed; no packages or services changed"
  exit 1
fi
if [[ ${has_updates:-0} -ne 1 ]]; then
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
# From here, EXIT cleanup restarts only services that this run stopped and is allowed to restore.
runner_stopped=0 ctl_stopped=0 restart_allowed=1 isolation_required=0
trap cleanup_services EXIT
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
# The package transaction can restart Docker and alter its firewall before our explicit restart.
if (( ${#docker_pkgs[@]} )); then
  restart_allowed=0
  isolation_required=1
fi
if (( ${#docker_pkgs[@]} )) && ! upgrade "${docker_pkgs[@]}" >>"$LOG" 2>&1; then
  note "FAIL Docker package upgrade failed, see ${LOG}; CI services left stopped"
  exit 1
fi
# a package scriptlet may have started the runner and it may have taken a job
if [[ "$(runner_state)" != inactive ]]; then
  if ! stop_runner_wait; then
    note "FAIL Docker packages upgraded, but gitlab-runner is busy again; Docker not restarted; CI services left stopped"
    exit 1
  fi
fi
if ! no_jobs; then
  note "FAIL Docker packages upgraded, but a CI job runs or docker does not answer; Docker not restarted; CI services left stopped"
  exit 1
fi
bad=""
if (( ${#docker_pkgs[@]} )); then
  # Docker's restart can clear the job firewall rules. Keep both CI services down
  # unless isolation is present, restarts successfully, and is active afterward.
  restart_allowed=0
  isolation_required=1
  if ! systemctl restart docker; then
    note "FAIL Docker restart failed; CI services left stopped"
    exit 1
  fi
  sleep 5
  ensure_isolation || exit 1
  restart_allowed=1
fi
if (( ${#runner_pkgs[@]} )) && ! upgrade "${runner_pkgs[@]}" >>"$LOG" 2>&1; then
  note "FAIL gitlab-runner upgrade failed, see ${LOG}"
  exit 1
fi
if ! can_restart_services; then
  note "FAIL refusing to restart CI services without active isolation"
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

}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
