# shellcheck shell=bash
# Run the real installer with filesystem paths redirected into $T and host operations stubbed.
# No root, Docker daemon, GitHub API, systemd changes, or real credentials are needed.
setup_installer() {
  mkdir -p "$T/repo/common" "$T/repo/runner/install" "$T/repo/runner/scripts" "$T/repo/runner/systemd" \
    "$T/etc/systemd/system" "$T/usr/local/bin"
  cp "$REPO/common/lib.sh" "$T/repo/common/lib.sh"
  cp "$REPO/runner/scripts/github-runner-ctl" "$T/repo/runner/scripts/"
  cp "$REPO/runner/systemd/github-runner-ctl.service" "$T/repo/runner/systemd/"
  python3 - "$REPO/runner/install/github-runner.sh" "$T" <<'PY'
import pathlib
import sys

source, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
text = source.read_text()
for prefix in ("/etc/", "/usr/local/"):
    text = text.replace(prefix, str(root) + prefix)
(root / "repo/runner/install/github-runner.sh").write_text(text)
PY
  cat >> "$T/repo/common/lib.sh" <<'STUB'

require_root() { :; }
pkg_install() { die "unexpected package installation in test"; }
systemctl() {
  printf '%s\n' "$*" >> "$T/systemctl.log"
  case "$1" in cat) return 1 ;; esac
}
docker() { [[ "$1" != info ]] || printf 'systemd 2\n'; }
curl() { die "unexpected network call in installer test"; }
getent() { printf 'docker:x:999:\n'; }
id() { :; }
usermod() { :; }
chown() { :; }
restorecon_if() { :; }
sysctl() { printf '28633\n'; }
sleep() { :; }
runuser() { return "${INSTALL_SELFTEST_RC:-0}"; }
install() {
  local args=()
  while (( $# )); do
    case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
  done
  command install "${args[@]}"
}
STUB
  touch "$T/etc/systemd/system/ci-jobs.slice"
  openssl genrsa -out "$T/download.pem" 2048 2>/dev/null
  export GH_OWNER=octo GH_APP_CLIENT_ID=Iv1.testclient GH_BUILDKIT=0 GH_KEY_SRC="$T/download.pem"
  installer_run
  : > "$T/systemctl.log"
}

installer_run() {
  local rc=0
  bash "$T/repo/runner/install/github-runner.sh" --no-pull > "$T/installer.out" 2>&1 || rc=$?
  if (( rc )); then cat "$T/installer.out"; fi
  return "$rc"
}

test_installer_key_rotation_restarts_active_controller() {
  setup_installer
  openssl genrsa -out "$T/rotated.pem" 2048 2>/dev/null
  GH_KEY_SRC="$T/rotated.pem" installer_run
  assert_ok "rotated key installed" cmp -s "$T/rotated.pem" "$T/etc/github-runner/app.pem"
  assert_eq "$(grep -c '^restart github-runner-ctl.service$' "$T/systemctl.log")" 1
  assert_eq "$(stat -c %a "$T/etc/github-runner/app.pem")" 600
}

test_installer_unchanged_key_does_not_restart_controller() {
  setup_installer
  installer_run
  assert_fail "unchanged installation does not restart" grep -q '^restart github-runner-ctl.service$' "$T/systemctl.log"
}

test_installer_invalid_config_preserves_installed_config() {
  setup_installer
  cp "$T/etc/github-runner/config.env" "$T/before.env"
  assert_fail "semantic validation rejects zero jobs" env GH_MAX_JOBS=0 \
    bash "$T/repo/runner/install/github-runner.sh" --no-pull --no-self-test > "$T/invalid.out" 2>&1
  assert_ok "installed config preserved" cmp -s "$T/before.env" "$T/etc/github-runner/config.env"
  assert_fail "invalid candidate never restarts service" grep -q '^restart github-runner-ctl.service$' "$T/systemctl.log"
}

test_installer_failed_selftest_preserves_activation() {
  setup_installer
  assert_fail "self-test failure stops activation" env INSTALL_SELFTEST_RC=1 \
    bash "$T/repo/runner/install/github-runner.sh" --no-pull > "$T/failed.out" 2>&1
  assert_fail "no activation after failed check" grep -Eq '^(enable|start|restart) github-runner-ctl.service$' "$T/systemctl.log"
  assert_ok "message describes existing service accurately" grep -q 'existing service may still be running' "$T/failed.out"
}

test_installer_rotation_retry_restarts_after_failed_selftest() {
  setup_installer
  openssl genrsa -out "$T/rotated.pem" 2048 2>/dev/null
  export GH_KEY_SRC="$T/rotated.pem"
  assert_fail "rotation check fails" env INSTALL_SELFTEST_RC=1 \
    bash "$T/repo/runner/install/github-runner.sh" --no-pull > "$T/failed.out" 2>&1
  assert_ok "rotation stays pending" test -f "$T/etc/github-runner/key-restart-required"
  installer_run
  assert_eq "$(grep -c '^restart github-runner-ctl.service$' "$T/systemctl.log")" 1
  assert_fail "successful restart clears pending rotation" test -f "$T/etc/github-runner/key-restart-required"
}

test_installer_rotation_no_start_defers_restart_until_retry() {
  setup_installer
  openssl genrsa -out "$T/rotated.pem" 2048 2>/dev/null
  export GH_KEY_SRC="$T/rotated.pem"
  bash "$T/repo/runner/install/github-runner.sh" --no-pull --no-start > "$T/deferred.out" 2>&1
  assert_ok "rotation stays pending with no-start" test -f "$T/etc/github-runner/key-restart-required"
  assert_fail "no-start never restarts controller" grep -q '^restart github-runner-ctl.service$' "$T/systemctl.log"
  installer_run
  assert_eq "$(grep -c '^restart github-runner-ctl.service$' "$T/systemctl.log")" 1
}
