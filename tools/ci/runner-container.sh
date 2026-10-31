#!/usr/bin/env bash
# The runner-host components that need neither a GitLab token nor Docker, run and checked INSIDE a systemd container
# (as root, repo in /root/server-init-config). Started by tools/ci/runner-e2e.sh over `docker exec`.
# Not covered here (they need a real Docker daemon, see runner-host-e2e.sh): registry cache, DOCKER-USER isolation rules,
# the Compose stacks. Never run: register.sh (needs a real glrt- token).
#   Usage: bash tools/ci/runner-container.sh KIND      KIND = el | debian
set -uo pipefail
KIND="${1:?el|debian}"
cd /root/server-init-config || exit 2
fails=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; echo "::error::$*"; fails=$((fails + 1)); }
warn() { echo "  WARN  $*"; echo "::warning::$*"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
BAD_RE='unbound variable|syntax error|bad substitution|: line [0-9]+: |unexpected EOF'
run() { # name command... ; log to /tmp/runner-NAME.log
  local n="$1"; shift
  if "$@" > "/tmp/runner-${n}.log" 2>&1; then pass "${n}: exit 0"; else tail -15 "/tmp/runner-${n}.log"; fail "${n}: exit $?"; fi
  grep -Eq "$BAD_RE" "/tmp/runner-${n}.log" && fail "${n}: shell error in output ($(grep -Em2 "$BAD_RE" "/tmp/runner-${n}.log" | tr '\n' '|'))"
  return 0
}
snapshot() {
  find /etc/ssh/sshd_config.d /etc/sysctl.d /etc/sudoers.d /etc/fail2ban/jail.d /etc/profile.d /etc/systemd/system /usr/local/bin /etc/security/limits.d -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null
  echo ---; ufw show added 2>/dev/null; firewall-cmd --permanent --list-all 2>/dev/null; getent passwd ops monitoring; getent group ssh-users
}

echo "== install: users, admin tools, health and timers, firewall"
# keys for ops come from root's authorized_keys: give root one (a throwaway; no real key is used)
install -d -m 0700 /root/.ssh
if [[ ! -s /root/.ssh/authorized_keys ]]; then
  ssh-keygen -q -t ed25519 -N '' -f /tmp/ci-key >/dev/null && cat /tmp/ci-key.pub >> /root/.ssh/authorized_keys
fi
run users bash runner/install/users.sh
run packages bash common/admin-tools.sh
run host-tools bash runner/install/host-tools.sh
run firewall bash runner/install/host-firewall.sh

echo "== users and SSH"
check "ops exists" id ops
check "service user monitoring exists" id monitoring
check "service users cannot log in (nologin shell)" bash -c '[[ "$(getent passwd monitoring | cut -d: -f7)" == *nologin* ]]'
check "ops is in ssh-users" bash -c 'id -nG ops | tr " " "\n" | grep -qx ssh-users'
check "ops is NOT in the docker group" bash -c '! id -nG ops | tr " " "\n" | grep -qx docker'
t=$(sshd -T 2>/dev/null)
grep -qi '^passwordauthentication no' <<<"$t" && pass "sshd: keys only" || fail "sshd: password login on"
grep -qi '^allowgroups ssh-users' <<<"$t" && pass "sshd: AllowGroups ssh-users" || fail "sshd: AllowGroups missing"
check "visudo -c" visudo -c
[[ -s /home/ops/.ssh/authorized_keys ]] && pass "ops got root's keys" || fail "ops has no authorized_keys"

echo "== admin tools"
for c in htop jq tmux; do check "$c installed" command -v "$c"; done
grep -q "^alias health='sudo /usr/local/bin/health'" /etc/profile.d/ci-runner.sh && pass "aliases written" || fail "aliases missing in /etc/profile.d/ci-runner.sh"

echo "== health, timers, kernel hardening"
for f in health runner-weekly-cleanup.sh runner-disk-guard.sh runner-engine-update.sh ci-job-isolation.sh; do check "/usr/local/bin/$f installed" test -x "/usr/local/bin/$f"; done
for t in runner-weekly-cleanup runner-disk-guard runner-engine-update; do check "${t}.timer active" systemctl is-active --quiet "${t}.timer"; done
check "ci-job-isolation.service enabled (applies at the next Docker start)" systemctl is-enabled --quiet ci-job-isolation.service
check "sysctl hardening file installed" test -f /etc/sysctl.d/90-ci-hardening.conf
check "core dumps off (limits)" grep -q 'hard core 0' /etc/security/limits.d/50-nocore.conf
# Container-only limit: sysctl keys under /proc/sys that belong to the host kernel may be read-only here. The file is
# written with "-" prefixes (errors ignored); the one namespaced key must be applied.
[[ "$(sysctl -n net.ipv4.conf.all.log_martians 2>/dev/null)" == 1 ]] && pass "net.ipv4.conf.all.log_martians = 1 applied" || warn "log_martians not applied (read-only /proc/sys in this container?)"
if [[ "$KIND" == el ]]; then check "sudo secure_path includes /usr/local/bin" bash -c 'sudo -l -U root >/dev/null; grep -rhs secure_path /etc/sudoers /etc/sudoers.d | grep -q /usr/local/bin'; fi
out=$(su -s /bin/bash ops -c 'sudo -n health --brief' 2>&1); rc=$?
(( rc <= 2 )) && pass "ops: sudo -n health --brief works (exit ${rc})" || fail "ops: sudo health --brief failed (exit ${rc}): $(head -3 <<<"$out")"
grep -Eq "$BAD_RE|command not found" <<<"$out" && fail "health --brief shell error" || pass "health --brief: no bash errors"
out=$(/usr/local/bin/health -q --no-color --profile runner 2>&1); rc=$?
echo "$out" > /tmp/health-runner.txt
(( rc <= 2 )) && pass "health -q --profile runner exit ${rc}" || fail "health -q --profile runner exit ${rc}"
grep -Eq "$BAD_RE|command not found" <<<"$out" && fail "health -q --profile runner shell error: $(grep -Em2 "$BAD_RE|command not found" <<<"$out" | tr '\n' '|')" || pass "health -q --profile runner: no bash errors"
out=$(DRY_RUN=1 /usr/local/bin/runner-weekly-cleanup.sh 2>&1) && pass "runner-weekly-cleanup.sh dry run" || fail "runner-weekly-cleanup.sh dry run: $(tail -3 <<<"$out")"

echo "== firewall and fail2ban"
if [[ "$KIND" == debian ]]; then
  ufw status | grep -q '^Status: active' && pass "ufw active" || fail "ufw not active"
  ufw status | grep -qE '^22(/tcp)? +ALLOW' && pass "ufw allows 22/tcp" || fail "ufw has no 22/tcp rule"
else
  systemctl is-active --quiet firewalld && pass "firewalld active" || fail "firewalld not active"
  firewall-cmd --query-service=ssh >/dev/null 2>&1 && pass "firewalld allows ssh" || fail "firewalld does not allow ssh"
fi
for _ in $(seq 1 10); do fail2ban-client status 2>/dev/null | grep -q sshd && break; sleep 2; done
fail2ban-client status 2>/dev/null | grep -q sshd && pass "fail2ban sshd jail exists" || fail "no fail2ban sshd jail"

echo "== job limits on a stand-in config.toml (no runner is registered; the file has no token)"
cat > /tmp/config.toml <<'TOML'
concurrent = 2
[[runners]]
  name = "ci-test-standin"
  url = "https://gitlab.invalid"
  token = "not-a-real-token"
  executor = "docker"
  [runners.docker]
    image = "alpine:3.20"
TOML
run job-limits env RUNNER_CONFIG=/tmp/config.toml bash runner/install/job-limits.sh
for k in memory cpus shm_size cgroup_parent service_memory; do grep -Eq "^[[:space:]]+${k} = " /tmp/config.toml && pass "config.toml has ${k}" || fail "config.toml lacks ${k}"; done
check "ci-jobs.slice written" test -f /etc/systemd/system/ci-jobs.slice
cp /tmp/config.toml /tmp/config.toml.1
run job-limits-rerun env RUNNER_CONFIG=/tmp/config.toml bash runner/install/job-limits.sh
cmp -s /tmp/config.toml /tmp/config.toml.1 && pass "job-limits rerun: config.toml unchanged" || fail "job-limits rerun changed config.toml"
grep -q 'already set' /tmp/runner-job-limits-rerun.log && pass "job-limits rerun reports 'already set'" || warn "job-limits rerun did not say 'already set'"

echo "== idempotency: run every component again"
snapshot > /tmp/state-1.txt
run users-2 bash runner/install/users.sh
run packages-2 bash common/admin-tools.sh
run host-tools-2 bash runner/install/host-tools.sh
run firewall-2 bash runner/install/host-firewall.sh
snapshot > /tmp/state-2.txt
if diff -u /tmp/state-1.txt /tmp/state-2.txt > /tmp/state.diff; then pass "second run changed no managed file, user, group or firewall rule"; else head -30 /tmp/state.diff; fail "second run changed managed state"; fi
exit $(( fails > 0 ))
