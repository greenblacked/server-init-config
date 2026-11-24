# shellcheck shell=bash
# runner-disk-guard.sh with stubbed df, systemctl, logger and cleanup (the cleanup path is rewritten into $T).

setup_guard() {
  mkdir -p "$T/bin"
  sed "s#/usr/local/bin/#$T/bin/#" "$REPO/runner/scripts/runner-disk-guard.sh" > "$T/guard.sh"
  cat > "$T/bin/df" <<'STUB'
#!/usr/bin/env bash
printf 'Use%%\n%s%%\n' "${GUARD_USED:-90}"
STUB
  cat > "$T/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T/systemctl.calls"
case "$1" in
  cat) exit "${GUARD_UNIT_CAT_RC:-0}" ;;
  start) exit "${GUARD_START_RC:-0}" ;;
esac
STUB
  cat > "$T/bin/logger" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$T/logger.calls"
STUB
  cat > "$T/bin/runner-weekly-cleanup.sh" <<'STUB'
#!/usr/bin/env bash
echo "cleanup RETENTION_DAYS=$RETENTION_DAYS" >> "$T/cleanup.calls"
STUB
  chmod +x "$T"/bin/*
  export PATH="$T/bin:$PATH"
}

test_disk_guard_alerts_through_telegram_when_the_unit_exists() {
  setup_guard
  bash "$T/guard.sh"
  assert_ok 'cleanup ran with one day of retention' grep -qx 'cleanup RETENTION_DAYS=1' "$T/cleanup.calls"
  assert_ok 'alert queued' grep -qx 'start --no-block h2ci-telegram-notify@disk-threshold.service' "$T/systemctl.calls"
  assert_fail 'nothing logged as a failure' grep -q 'could not queue' "$T/logger.calls"
}

test_disk_guard_without_the_telegram_unit_is_quiet() {
  setup_guard
  GUARD_UNIT_CAT_RC=1 bash "$T/guard.sh" 2> "$T/err"
  assert_ok 'cleanup still ran' test -s "$T/cleanup.calls"
  assert_fail 'no start attempt for a unit that does not exist' grep -q '^start' "$T/systemctl.calls"
  assert_fail 'no "could not queue" log line on every run' grep -q 'could not queue' "$T/logger.calls"
  assert_eq "$(cat "$T/err")" '' 'nothing on stderr'
}

test_disk_guard_logs_a_failed_alert_start_and_still_cleans() {
  setup_guard
  GUARD_START_RC=1 bash "$T/guard.sh"
  assert_ok 'failed start is logged' grep -q 'could not queue Telegram disk alert' "$T/logger.calls"
  assert_ok 'cleanup still ran' test -s "$T/cleanup.calls"
}

test_disk_guard_below_the_limit_does_nothing() {
  setup_guard
  GUARD_USED=50 bash "$T/guard.sh"
  assert_fail 'no cleanup' test -e "$T/cleanup.calls"
  assert_fail 'no systemctl' test -e "$T/systemctl.calls"
}
