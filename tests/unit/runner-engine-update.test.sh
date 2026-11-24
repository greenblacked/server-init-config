# shellcheck shell=bash
# Test the updater's pure probe/isolation helpers with package-manager and systemd stubs.
source "$REPO/runner/scripts/runner-engine-update.sh"

note() { last_note="$*"; printf '%s\n' "$*" >> "$T/messages"; }

setup_dnf() {
  mkdir -p "$T/bin"
  cat > "$T/bin/dnf" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T/dnf.calls"
printf '%s\n' "${DNF_OUTPUT:-}" >&2
exit "${DNF_RC:-0}"
STUB
  chmod +x "$T/bin/dnf"
  PATH="$T/bin:$PATH"
  export PATH
}

setup_apt() {
  mkdir -p "$T/bin"
  cat > "$T/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  update)
    printf '%s\n' "$*" >> "$T/apt.calls"
    printf '%s\n' "${APT_UPDATE_OUTPUT:-}" >&2
    exit "${APT_UPDATE_RC:-0}"
    ;;
  -s)
    touch "$T/apt-query-called"
    printf '%s\n' "${APT_QUERY_OUTPUT:-}" >&2
    exit "${APT_QUERY_RC:-0}"
    ;;
  *) exit 99 ;;
esac
STUB
  chmod +x "$T/bin/apt-get"
  PATH="$T/bin:$PATH"
  export PATH
}

setup_systemctl() {
  systemctl() {
    printf '%s\n' "$*" >> "$T/systemctl.calls"
    case "$1" in
      cat) return "${ISO_CAT_RC:-0}" ;;
      restart) return "${ISO_RESTART_RC:-0}" ;;
      is-active) return "${ISO_ACTIVE_RC:-0}" ;;
      start) return 0 ;;
    esac
  }
}

test_dnf_exit_codes_distinguish_pending_none_and_error() {
  setup_dnf
  local rc=0
  DNF_RC=0; DNF_OUTPUT=''; export DNF_RC DNF_OUTPUT
  pending_dnf docker-ce > "$T/out" 2> "$T/err" || rc=$?
  assert_eq "$rc" 1 'DNF exit 0 means no updates'

  rc=0; DNF_RC=100; DNF_OUTPUT='docker-ce.x86_64 update available'; export DNF_RC DNF_OUTPUT
  pending_dnf docker-ce > "$T/out" 2> "$T/err" || rc=$?
  assert_eq "$rc" 0 'DNF exit 100 means updates are available'

  rc=0; DNF_RC=1; DNF_OUTPUT='repository metadata unavailable'; export DNF_RC DNF_OUTPUT
  pending_dnf docker-ce > "$T/out" 2> "$T/err" || rc=$?
  assert_eq "$rc" 2 'other DNF errors are distinct from no updates'
  assert_ok 'DNF diagnostic is preserved' grep -q 'repository metadata unavailable' "$T/err"
}

test_apt_metadata_failure_is_an_error_and_skips_query() {
  setup_apt
  local rc=0
  APT_UPDATE_RC=100 APT_UPDATE_OUTPUT='E: Some index files failed to download; old ones used instead' export APT_UPDATE_RC APT_UPDATE_OUTPUT
  pending_apt docker-ce > "$T/out" 2> "$T/err" || rc=$?
  assert_eq "$rc" 2 'APT metadata failure propagates'
  assert_ok 'APT metadata diagnostic is preserved' grep -q 'Some index files failed to download' "$T/err"
  assert_ok 'APT update requests strict handling of transient index failures' grep -q -- '--error-on=any' "$T/apt.calls"
  assert_fail 'APT simulation is not run with stale metadata' test -e "$T/apt-query-called"
}

test_apt_query_failure_is_an_error() {
  setup_apt
  local rc=0
  APT_UPDATE_RC=0 APT_QUERY_RC=100 APT_QUERY_OUTPUT='simulation failed' export APT_UPDATE_RC APT_QUERY_RC APT_QUERY_OUTPUT
  pending_apt docker-ce > "$T/out" 2> "$T/err" || rc=$?
  assert_eq "$rc" 2 'APT query failure propagates'
  assert_ok 'APT query diagnostic is preserved' grep -q 'simulation failed' "$T/err"
}

test_apt_simulation_distinguishes_updates_from_none() {
  setup_apt
  local rc=0
  APT_UPDATE_RC=0 APT_QUERY_RC=0 APT_QUERY_OUTPUT='Inst docker-ce [1.0] (2.0 repo)' export APT_UPDATE_RC APT_QUERY_RC APT_QUERY_OUTPUT
  pending_apt docker-ce > "$T/out" 2> "$T/err" || rc=$?
  assert_eq "$rc" 0 'APT Inst line means updates are available'

  rc=0; APT_QUERY_OUTPUT='Reading package lists...'; export APT_QUERY_OUTPUT
  pending_apt docker-ce > "$T/out" 2> "$T/err" || rc=$?
  assert_eq "$rc" 1 'successful simulation without Inst means no updates'
}

test_isolation_missing_restart_and_verification_fail_closed() {
  setup_systemctl
  local rc=0

  ISO_CAT_RC=1 ISO_RESTART_RC=0 ISO_ACTIVE_RC=0
  ensure_isolation || rc=$?
  assert_eq "$rc" 1 'missing isolation unit fails'
  assert_eq "$(cat "$T/systemctl.calls")" 'cat ci-job-isolation.service'
  assert_ok 'missing-unit reason is recorded' grep -q 'service missing' "$T/messages"

  rm -f "$T/systemctl.calls" "$T/messages"; rc=0
  ISO_CAT_RC=0 ISO_RESTART_RC=1 ISO_ACTIVE_RC=0
  ensure_isolation || rc=$?
  assert_eq "$rc" 1 'failed isolation restart fails'
  assert_eq "$(cat "$T/systemctl.calls")" $'cat ci-job-isolation.service\nrestart ci-job-isolation.service'
  assert_ok 'restart failure reason is recorded' grep -q 'restart failed' "$T/messages"

  rm -f "$T/systemctl.calls" "$T/messages"; rc=0
  ISO_CAT_RC=0 ISO_RESTART_RC=0 ISO_ACTIVE_RC=3
  ensure_isolation || rc=$?
  assert_eq "$rc" 1 'inactive isolation after restart fails'
  assert_eq "$(cat "$T/systemctl.calls")" $'cat ci-job-isolation.service\nrestart ci-job-isolation.service\nis-active --quiet ci-job-isolation.service'
  assert_ok 'inactive-unit reason is recorded' grep -q 'not active after restart' "$T/messages"
}

test_isolation_success_requires_verified_active_unit() {
  setup_systemctl
  ISO_CAT_RC=0 ISO_RESTART_RC=0 ISO_ACTIVE_RC=0
  assert_ok 'isolation restart and active verification succeed' ensure_isolation
  assert_eq "$(cat "$T/systemctl.calls")" $'cat ci-job-isolation.service\nrestart ci-job-isolation.service\nis-active --quiet ci-job-isolation.service'
}

test_exit_cleanup_does_not_restart_services_without_isolation() {
  setup_systemctl
  HELD_FILE="$T/var/held"
  runner_stopped=1 ctl_stopped=1 restart_allowed=0 isolation_required=0
  cleanup_services
  assert_eq "$(cat "$T/systemctl.calls" 2>/dev/null || true)" '' 'failed isolation leaves both services stopped'
  assert_ok 'held marker records that the controller was stopped' grep -qx 'ctl_stopped=1' "$HELD_FILE"
  assert_ok 'held marker has a timestamp' grep -Eq '^time=[0-9]{4}-' "$HELD_FILE"
  rm -f "$HELD_FILE"

  restart_allowed=1
  cleanup_services
  assert_eq "$(cat "$T/systemctl.calls")" $'start --no-block gitlab-runner\nstart --no-block github-runner-ctl' 'verified isolation permits cleanup restart'
  assert_fail 'a restorable exit writes no marker' test -e "$HELD_FILE"
}

test_exit_cleanup_rechecks_isolation_before_restarting_services() {
  setup_systemctl
  HELD_FILE="$T/var/held"
  runner_stopped=1 ctl_stopped=1 restart_allowed=1 isolation_required=1
  ISO_ACTIVE_RC=3
  cleanup_services
  assert_ok 'inactive isolation at exit writes the held marker' test -s "$HELD_FILE"
  assert_eq "$(cat "$T/systemctl.calls")" 'is-active --quiet ci-job-isolation.service' 'inactive isolation prevents cleanup restart'
  assert_eq "$restart_allowed" 0 'failed isolation recheck disables later restart attempts'
}
