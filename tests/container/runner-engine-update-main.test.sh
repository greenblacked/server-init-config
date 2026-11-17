# shellcheck shell=bash
# Main-flow regressions run from tools/test-server-tools.sh in its root-only hermetic harness.
# Exercise the updater's real main flow with all host-facing commands stubbed.
# Lock, drop-in, log and simulated service state stay beneath $T.
setup_main() {
  mkdir -p "$T/bin"
  export PATH="$T/bin:/usr/bin:/bin"
  export ENGINE_UPDATE_LOG="$T/updater.log" ENGINE_UPDATE_DROPIN="$T/graceful-stop.conf" ENGINE_UPDATE_LOCK="$T/lock" STOP_WAIT=0
  : > "$T/events"
  printf 'active\n' > "$T/runner-state"
  printf 'active\n' > "$T/controller-state"
  printf '[Service]\nKillSignal=SIGQUIT\nTimeoutStopSec=infinity\n' > "$ENGINE_UPDATE_DROPIN"
  cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$T/events"
exit 0
STUB
  cat > "$T/bin/rpm" <<'STUB'
#!/usr/bin/env bash
printf 'rpm %s\n' "$*" >> "$T/events"
if [[ " $* " == *' --qf '* ]]; then printf '%s-1.0-1 ' "${!#}"; fi
exit 0
STUB
  cat > "$T/bin/dnf" <<'STUB'
#!/usr/bin/env bash
printf 'dnf %s\n' "$*" >> "$T/events"
if [[ " $* " == *' check-update '* ]]; then exit "${MAIN_PROBE_RC:-100}"; fi
if [[ " $* " == *' upgrade '* ]]; then
  if [[ " $* " == *' docker-ce '* ]]; then
    [[ "${MAIN_SCRIPTLET_RESTARTS_RUNNER:-0}" == 1 ]] && printf 'active\n' > "$T/runner-state"
    exit "${MAIN_DOCKER_UPGRADE_RC:-0}"
  fi
  exit "${MAIN_RUNNER_UPGRADE_RC:-0}"
fi
exit 99
STUB
  cat > "$T/bin/flock" <<'STUB'
#!/usr/bin/env bash
printf 'flock %s\n' "$*" >> "$T/events"
exit 0
STUB
  cat > "$T/bin/sleep" <<'STUB'
#!/usr/bin/env bash
printf 'sleep %s\n' "$*" >> "$T/events"
exit 0
STUB
  cat > "$T/bin/logger" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$T/events"
case "$1" in
  show) cat "$T/runner-state"; exit $? ;;
  is-active)
    case "$3" in
      github-runner-ctl) [[ "$(cat "$T/controller-state")" == active ]]; exit $? ;;
      gitlab-runner) [[ "$(cat "$T/runner-state")" == active ]]; exit $? ;;
      ci-job-isolation.service) [[ -f "$T/isolation-active" ]]; exit $? ;;
      docker) [[ -f "$T/docker-active" ]]; exit $? ;;
      *) exit 1 ;;
    esac ;;
  stop)
    target=$2; [[ "$target" == --no-block ]] && target=$3
    case "$target" in
      gitlab-runner) printf 'inactive\n' > "$T/runner-state" ;;
      github-runner-ctl) printf 'inactive\n' > "$T/controller-state" ;;
    esac ;;
  start)
    target=$2; [[ "$target" == --no-block ]] && target=$3
    case "$target" in
      gitlab-runner) printf 'active\n' > "$T/runner-state" ;;
      github-runner-ctl) printf 'active\n' > "$T/controller-state" ;;
    esac ;;
  restart)
    case "$2" in
      docker) : > "$T/docker-active"; rm -f "$T/isolation-active" ;;
      ci-job-isolation.service)
        [[ "${MAIN_ISOLATION_RESTART_RC:-0}" -eq 0 ]] || exit "$MAIN_ISOLATION_RESTART_RC"
        [[ "${MAIN_ISOLATION_INACTIVE:-0}" == 1 ]] || : > "$T/isolation-active" ;;
    esac ;;
  cat) [[ "${MAIN_ISOLATION_CAT_RC:-0}" -eq 0 ]]; exit $? ;;
esac
exit 0
STUB
  chmod +x "$T/bin/"*
  export MAIN_PROBE_RC=100 MAIN_DOCKER_UPGRADE_RC=0 MAIN_RUNNER_UPGRADE_RC=0
  export MAIN_ISOLATION_CAT_RC=0 MAIN_ISOLATION_RESTART_RC=0 MAIN_ISOLATION_INACTIVE=0 MAIN_SCRIPTLET_RESTARTS_RUNNER=0
}
run_main() {
  local rc=0
  "$REPO/runner/scripts/runner-engine-update.sh" > "$T/main.out" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$T/main.rc"
}
event_line() { grep -n -m1 -F "$1" "$T/events" | cut -d: -f1 || true; }

test_main_success_preserves_maintenance_and_activation_order() {
  setup_main
  run_main
  cat "$T/main.out"
  assert_eq "$(cat "$T/main.rc")" 0 'successful main flow exits zero'
  local ctl_stop runner_stop docker_upgrade docker_restart isolation_cat isolation_restart isolation_active runner_upgrade runner_start ctl_start
  ctl_stop=$(event_line 'systemctl stop github-runner-ctl')
  runner_stop=$(event_line 'systemctl stop --no-block gitlab-runner')
  docker_upgrade=$(event_line 'dnf -y -q upgrade docker-ce')
  docker_restart=$(event_line 'systemctl restart docker')
  isolation_cat=$(event_line 'systemctl cat ci-job-isolation.service')
  isolation_restart=$(event_line 'systemctl restart ci-job-isolation.service')
  isolation_active=$(event_line 'systemctl is-active --quiet ci-job-isolation.service')
  runner_upgrade=$(event_line 'dnf -y -q upgrade gitlab-runner')
  runner_start=$(event_line 'systemctl start gitlab-runner')
  ctl_start=$(event_line 'systemctl start --no-block github-runner-ctl')
  assert_ok 'runner and controller stop before Docker package upgrade' test "$ctl_stop" -lt "$runner_stop" -a "$runner_stop" -lt "$docker_upgrade"
  assert_ok 'Docker upgrade precedes restart and isolation revalidation' test "$docker_upgrade" -lt "$docker_restart" -a "$docker_restart" -lt "$isolation_cat" -a "$isolation_cat" -lt "$isolation_restart" -a "$isolation_restart" -lt "$isolation_active"
  assert_ok 'runner package upgrade and service activation follow isolation validation' test "$isolation_active" -lt "$runner_upgrade" -a "$runner_upgrade" -lt "$runner_start" -a "$runner_start" -lt "$ctl_start"
  assert_eq "$(cat "$T/runner-state")" active 'runner is active after success'
  assert_eq "$(cat "$T/controller-state")" active 'controller is active after success'
}

test_main_probe_error_exits_before_service_actions() {
  setup_main
  export MAIN_PROBE_RC=1
  run_main
  assert_eq "$(cat "$T/main.rc")" 1 'probe error exits nonzero'
  assert_ok 'probe failure diagnostic' grep -q 'package update probe failed' "$T/main.out"
  assert_fail 'probe error causes no service stop/start/restart' grep -Eq '^systemctl (stop|start|restart) ' "$T/events"
  assert_fail 'probe error causes no package upgrade' grep -Eq '^dnf -y -q upgrade ' "$T/events"
}

test_main_docker_upgrade_failure_does_not_activate_services_or_kill_scriptlet_runner() {
  setup_main
  export MAIN_DOCKER_UPGRADE_RC=1 MAIN_SCRIPTLET_RESTARTS_RUNNER=1
  run_main
  assert_eq "$(cat "$T/main.rc")" 1 'Docker package failure exits nonzero'
  assert_ok 'Docker package upgrade was attempted' grep -Eq '^dnf -y -q upgrade docker-ce ' "$T/events"
  assert_fail 'failed package transaction does not activate services' grep -Eq '^systemctl start ' "$T/events"
  assert_eq "$(cat "$T/runner-state")" active 'scriptlet-started runner is not forcibly stopped'
  assert_eq "$(cat "$T/controller-state")" inactive 'stopped controller remains down'
}

check_main_isolation_failure() {
  local name=$1 cat_rc=$2 restart_rc=$3 inactive=$4 diagnostic=$5
  setup_main
  export MAIN_ISOLATION_CAT_RC=$cat_rc MAIN_ISOLATION_RESTART_RC=$restart_rc MAIN_ISOLATION_INACTIVE=$inactive
  run_main
  assert_eq "$(cat "$T/main.rc")" 1 "$name exits nonzero"
  assert_ok "$name follows Docker restart" grep -Fq 'systemctl restart docker' "$T/events"
  assert_ok "$name reports failure" grep -Fq "$diagnostic" "$T/main.out"
  assert_fail "$name does not activate runner/controller" grep -Eq '^systemctl start ' "$T/events"
  assert_fail "$name does not upgrade runner package" grep -Eq '^dnf -y -q upgrade gitlab-runner' "$T/events"
}

test_main_missing_isolation_after_docker_maintenance_fails_closed() {
  check_main_isolation_failure 'missing isolation' 1 0 0 'ci-job-isolation.service missing'
}

test_main_failed_isolation_restart_after_docker_maintenance_fails_closed() {
  check_main_isolation_failure 'failed isolation restart' 0 1 0 'ci-job-isolation.service restart failed'
}

test_main_inactive_isolation_after_docker_maintenance_fails_closed() {
  check_main_isolation_failure 'inactive isolation' 0 0 1 'ci-job-isolation.service is not active'
}
