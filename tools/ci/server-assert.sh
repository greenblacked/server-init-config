#!/usr/bin/env bash
# Assertions about a plain server AFTER server/bootstrap.sh ran. Runs INSIDE the test container (as root), fed over stdin by
# tools/ci/server-e2e.sh:  docker exec -i NAME bash -s -- KIND "FAILED_STEPS" < tools/ci/server-assert.sh
#   KIND          fedora | el10 | debian | opensuse
#   FAILED_STEPS  steps server-init reported as failed in the container (already checked against the allow-list by the driver);
#                 assertions that depend on a failed step are skipped with a warning instead of failing twice.
# Prints PASS/FAIL/WARN lines; exits 1 when something failed.
set -uo pipefail
KIND="${1:?kind}"
FAILED=" ${2:-} "
fails=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; echo "::error::$*"; fails=$((fails + 1)); }
warn() { echo "  WARN  $*"; echo "::warning::$*"; }
step_failed() { [[ "$FAILED" == *" $1 "* ]]; }
# check DESC CMD...
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }

. /etc/os-release
echo "== OS ${PRETTY_NAME:-$ID} ($KIND)"
[[ -f /etc/server-init.conf ]] && pass "/etc/server-init.conf exists" || fail "/etc/server-init.conf missing"
ADMIN_USER=$(sed -n 's/^ADMIN_USER=//p' /etc/server-init.conf | head -1); ADMIN_USER="${ADMIN_USER:-ops}"

echo "== admin user and sudo"
if step_failed admin-user; then warn "admin-user step failed (allowed), skipped"; else
  check "user ${ADMIN_USER} exists" id "$ADMIN_USER"
  check "sudoers drop-in /etc/sudoers.d/90-${ADMIN_USER} is valid (visudo -cf)" visudo -cf "/etc/sudoers.d/90-${ADMIN_USER}"
  # openSUSE Leap 16 keeps the vendor sudoers in /usr/etc; a bare visudo -c only reads the compiled-in /etc/sudoers.
  sudoers_main=/etc/sudoers; [[ -f $sudoers_main ]] || sudoers_main=/usr/etc/sudoers
  check "visudo -c on the whole sudoers" visudo -cf "$sudoers_main"
  # Not check(): it returns 0 even after fail(), so an `if ! check` branch would never run.
  if su -s /bin/bash "$ADMIN_USER" -c 'sudo -n true' >/dev/null 2>&1; then pass "${ADMIN_USER} has passwordless sudo"; else
    fail "${ADMIN_USER} has passwordless sudo"
    # show why (locked account, PAM, sudoers, SELinux) so the log is enough to diagnose
    echo "  shadow state: $(getent shadow "$ADMIN_USER" | cut -d: -f2 | cut -c1)"
    su -s /bin/bash "$ADMIN_USER" -c 'sudo -n true' 2>&1 | sed 's/^/  sudo: /' || true
    journalctl -u sshd -u ssh --no-pager -n 20 2>/dev/null | grep -i "$ADMIN_USER" | sed 's/^/  sshd: /' || true
    # PAM account-phase failures (PAM_AUTHINFO_UNAVAIL) come from the stack, the NSS order, the shadow entry or a damaged helper.
    {
      echo "--- getent passwd/shadow flags, chage"; getent passwd "$ADMIN_USER"; getent shadow "$ADMIN_USER" | cut -d: -f1,3-; chage -l "$ADMIN_USER"
      echo "--- shadow and PAM helper files"; ls -lZ /etc/shadow /etc/passwd /usr/sbin/unix_chkpwd /usr/bin/sudo /etc/sudoers 2>&1
      echo "--- account lines of the PAM stacks"; grep -H '^account' /etc/pam.d/system-auth /etc/pam.d/sudo /etc/pam.d/sshd /etc/pam.d/password-auth 2>&1
      echo "--- authselect"; authselect current 2>&1; ls -l /etc/pam.d/system-auth /etc/authselect 2>&1
      echo "--- nsswitch"; grep -E '^(passwd|shadow|group):' /etc/nsswitch.conf
      echo "--- selinux"; getenforce 2>&1; grep -s '^SELINUX=' /etc/selinux/config
      echo "--- rpm -V of the auth packages"; rpm -V pam shadow-utils sudo openssh-server authselect libselinux 2>&1 | head -20
      echo "--- pam/sudo/sshd journal"; journalctl --no-pager -n 400 2>/dev/null | grep -Ei "pam_|sudo\[|unix_chkpwd|account" | tail -15
      echo "--- init-failed.log tail"; tail -n 20 /var/log/server-init-failed.log 2>&1
      echo "--- date, timezone"; date; timedatectl 2>&1 | head -4
    } 2>&1 | sed 's/^/  diag: /' || true
  fi
  [[ -s "/home/${ADMIN_USER}/.ssh/authorized_keys" ]] && pass "${ADMIN_USER} has authorized_keys" || fail "${ADMIN_USER} has no authorized_keys"
fi

echo "== sshd"
if step_failed ssh-hardening; then warn "ssh-hardening step failed (allowed), skipped"; else
  t=$(sshd -T 2>/dev/null)
  grep -qi '^passwordauthentication no' <<<"$t" && pass "sshd: passwordauthentication no" || fail "sshd: password login still on"
  grep -qiE '^permitrootlogin (prohibit-password|without-password)' <<<"$t" && pass "sshd: root by key only" || fail "sshd: permitrootlogin is not prohibit-password ($(grep -i '^permitrootlogin' <<<"$t"))"
  grep -qi '^port 22$' <<<"$t" && pass "sshd: port 22" || fail "sshd: not on port 22"
fi

echo "== firewall allows SSH"
if step_failed firewall; then warn "firewall step failed (allowed), skipped"; else
  case "$KIND" in
    debian)
      out=$(ufw status 2>&1)
      grep -q '^Status: active' <<<"$out" && pass "ufw is active" || fail "ufw is not active: $out"
      grep -qE '^22(/tcp)? +ALLOW' <<<"$out" && pass "ufw allows 22/tcp" || fail "ufw does not list 22/tcp ALLOW: $out" ;;
    *)
      systemctl is-active --quiet firewalld && pass "firewalld is active" || fail "firewalld is not active"
      firewall-cmd --zone=public --query-service=ssh >/dev/null 2>&1 && pass "firewalld public zone allows ssh" || fail "firewalld public zone does not allow ssh" ;;
  esac
fi

echo "== fail2ban"
if step_failed fail2ban; then warn "fail2ban step failed (allowed), skipped"; else
  if systemctl is-active --quiet fail2ban; then
    pass "fail2ban is active"
    for _ in 1 2 3 4 5 6 7 8 9 10; do fail2ban-client status 2>/dev/null | grep -q sshd && break; sleep 2; done
    fail2ban-client status 2>/dev/null | grep -q sshd && pass "fail2ban has the sshd jail" || { fail "fail2ban has no sshd jail: $(fail2ban-client status 2>&1 | tr '\n' ' ')"; }
  else
    fail "fail2ban is not active: $(systemctl status fail2ban --no-pager 2>&1 | tail -5 | tr '\n' ' ')"
  fi
fi

echo "== automatic updates"
if step_failed auto-updates; then warn "auto-updates step failed (allowed), skipped"; else
  case "$KIND" in
    el10 | fedora) check "server-update.timer is active (install-tools)" systemctl is-active --quiet server-update.timer
                   check "server-cleanup.timer is active" systemctl is-active --quiet server-cleanup.timer ;;
    debian)        check "apt-daily-upgrade.timer is active" systemctl is-active --quiet apt-daily-upgrade.timer
                   [[ -f /etc/apt/apt.conf.d/50unattended-upgrades ]] && pass "unattended-upgrades is configured" || fail "no unattended-upgrades config" ;;
    opensuse)      check "server-security-updates.timer is active" systemctl is-active --quiet server-security-updates.timer
                   check "server-cleanup.timer is active" systemctl is-active --quiet server-cleanup.timer ;;
  esac
fi

echo "== health and tools run without shell errors"
BAD_RE='unbound variable|syntax error|bad substitution|: line [0-9]+: |command not found|unexpected EOF'
for args in "--brief" "-q --no-color"; do
  # shellcheck disable=SC2086
  out=$(/usr/local/bin/health $args 2>&1); rc=$?
  echo "$out" > "/tmp/health-${args// /_}.txt"
  if (( rc <= 2 )); then pass "health ${args} exit code ${rc} (0 ok, 1 warnings, 2 failures)"; else fail "health ${args} exit code ${rc}"; fi
  if grep -Eq "$BAD_RE" <<<"$out"; then fail "health ${args} printed a shell error: $(grep -Em3 "$BAD_RE" <<<"$out" | tr '\n' '|')"; else pass "health ${args}: no bash errors in the output"; fi
done
if [[ "$KIND" == el10 || "$KIND" == fedora ]]; then
  out=$(srv status 2>&1); rc=$?
  (( rc <= 2 )) && pass "srv status exit code ${rc}" || fail "srv status exit code ${rc}"
  grep -Eq "$BAD_RE" <<<"$out" && fail "srv status printed a shell error" || pass "srv status: no bash errors"
  out=$(server-cleanup --dry-run 2>&1); rc=$?
  (( rc == 0 )) && pass "server-cleanup --dry-run" || fail "server-cleanup --dry-run exit ${rc}: $(tail -3 <<<"$out")"
fi
echo "ASSERT-DONE"
exit $(( fails > 0 ))
