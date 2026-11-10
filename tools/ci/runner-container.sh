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
  local n="$1" rc=0; shift
  "$@" > "/tmp/runner-${n}.log" 2>&1 || rc=$?
  if (( rc == 0 )); then pass "${n}: exit 0"; else tail -15 "/tmp/runner-${n}.log"; fail "${n}: exit ${rc}"; fi
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
    image = "alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f"
TOML
run job-limits env RUNNER_CONFIG=/tmp/config.toml bash runner/install/job-limits.sh
for k in memory cpus shm_size cgroup_parent service_memory; do grep -Eq "^[[:space:]]+${k} = " /tmp/config.toml && pass "config.toml has ${k}" || fail "config.toml lacks ${k}"; done
check "ci-jobs.slice written" test -f /etc/systemd/system/ci-jobs.slice
cp /tmp/config.toml /tmp/config.toml.1
run job-limits-rerun env RUNNER_CONFIG=/tmp/config.toml bash runner/install/job-limits.sh
cmp -s /tmp/config.toml /tmp/config.toml.1 && pass "job-limits rerun: config.toml unchanged" || fail "job-limits rerun changed config.toml"
grep -q 'already set' /tmp/runner-job-limits-rerun.log && pass "job-limits rerun reports 'already set'" || warn "job-limits rerun did not say 'already set'"

echo "== GitHub Actions runner component (stubbed docker, throwaway key, no GitHub)"
# No Docker daemon here: a stub answers the few docker commands the installer uses, and a stand-in docker.service lets the preflight see "running".
# The installer now fails closed unless ci-job-isolation.service starts, and that script needs the DOCKER-USER chain dockerd would create.
# Add the chain here; the actual isolation rules are still checked on a real daemon in runner-host-e2e.sh.
# Not under /tmp: the container mounts it noexec (--tmpfs), so a stub there cannot be run and `docker info` would fail.
GHR_STUB=/var/tmp/ghr-stub; install -d "$GHR_STUB"
cat > "$GHR_STUB/docker" <<'STUB'
#!/bin/sh
case "$1" in info) echo "systemd 2" ;; esac
exit 0
STUB
chmod +x "$GHR_STUB/docker"
getent group docker >/dev/null || groupadd -r docker
printf '[Service]\nExecStart=/bin/sleep infinity\n' > /etc/systemd/system/docker.service
systemctl daemon-reload; systemctl start docker.service
iptables -N DOCKER-USER 2>/dev/null || true
iptables -n -L DOCKER-USER >/dev/null 2>&1 || fail "cannot create the stand-in DOCKER-USER chain (iptables is required for ci-job-isolation)"
# a minimal image has no openssl command (the installer fetches it itself, but only after it needs a key to start with)
command -v openssl >/dev/null 2>&1 || { dnf -y -q install openssl || { apt-get update -q && apt-get install -y -q openssl; }; } >/tmp/runner-openssl.log 2>&1
openssl genrsa -out /tmp/ghr-test.pem 2048 2>/dev/null || fail "cannot create the throwaway RSA key (openssl genrsa)"
KEYLINE=$(sed -n 2p /tmp/ghr-test.pem)
ghr_install() { PATH="$GHR_STUB:$PATH" GH_OWNER=octo GH_APP_CLIENT_ID=Iv1.citest GH_KEY_SRC=/tmp/ghr-test.pem bash runner/install/github-runner.sh --no-self-test --no-start --no-pull; }
run github-runner ghr_install
check "service user github-runner exists, no login shell" bash -c 'id github-runner && [[ "$(getent passwd github-runner | cut -d: -f7)" == *nologin* ]]'
check "github-runner is in the docker group (root-equivalent, documented)" bash -c 'id -nG github-runner | tr " " "\n" | grep -qx docker'
check "ops is still NOT in the docker group" bash -c '! id -nG ops | tr " " "\n" | grep -qx docker'
check "/etc/github-runner is 750 root:github-runner" bash -c '[[ "$(stat -c %a:%U:%G /etc/github-runner)" == 750:root:github-runner ]]'
check "config.env is 640 root:github-runner" bash -c '[[ "$(stat -c %a:%U:%G /etc/github-runner/config.env)" == 640:root:github-runner ]]'
check "app.pem is 600 owned by github-runner, same key" bash -c '[[ "$(stat -c %a:%U /etc/github-runner/app.pem)" == 600:github-runner ]] && cmp -s /tmp/ghr-test.pem /etc/github-runner/app.pem'
check "no key material in config.env or in the installer output" bash -c '! grep -q "PRIVATE KEY" /etc/github-runner/config.env && ! grep -qF "$1" /etc/github-runner/config.env /tmp/runner-github-runner.log' _ "$KEYLINE"
check "config.env: owner, client id, labels, pool, pinned images" bash -c 'grep -qx "GH_OWNER=octo" /etc/github-runner/config.env && grep -qx "GH_APP_CLIENT_ID=Iv1.citest" /etc/github-runner/config.env && grep -qE "^GH_LABELS=self-hosted,linux,(arm64|x64),hetzner$" /etc/github-runner/config.env && grep -qx "GH_JOB_SUBNET_POOL=10.213.0.0/20" /etc/github-runner/config.env && grep -qx "GH_RUNNER_IMAGE=$(sed -n "s/^GHR_RUNNER_IMAGE=\"\(.*\)\"\$/\1/p" common/lib.sh)" /etc/github-runner/config.env && grep -qx "GH_BUILDKIT_IMAGE=$(sed -n "s/^GHR_BUILDKIT_IMAGE=\"\(.*\)\"\$/\1/p" common/lib.sh)" /etc/github-runner/config.env'
check "controller installed, executable" test -x /usr/local/bin/github-runner-ctl
check "controller --help works without a config" bash -c 'GHR_CONFIG=/nonexistent /usr/local/bin/github-runner-ctl --help | grep -q "Usage: github-runner-ctl"'
check "controller accepts the installed config" bash -c 'GHR_CONFIG=/etc/github-runner/config.env /usr/local/bin/github-runner-ctl check-config'
check "unit file installed" test -f /etc/systemd/system/github-runner-ctl.service
check "unit passes systemd-analyze verify" bash -c '! systemd-analyze verify /etc/systemd/system/github-runner-ctl.service 2>&1 | grep -iE "error|unknown (section|lvalue)|bad|invalid"'
check "unit is enabled" systemctl is-enabled --quiet github-runner-ctl.service
check "unit is not started (--no-start)" bash -c '! systemctl is-active --quiet github-runner-ctl.service'
printf 'GH_OWNER=octo\nGH_MAX_JOBS=0\n' > /tmp/ghr-bad.env
check "an invalid config is refused with exit 2" bash -c 'GHR_CONFIG=/tmp/ghr-bad.env /usr/local/bin/github-runner-ctl check-config; [[ $? -eq 2 ]]'
sha() { sha256sum /etc/github-runner/config.env /etc/github-runner/app.pem /etc/systemd/system/github-runner-ctl.service /usr/local/bin/github-runner-ctl; stat -c '%a %U:%G %n' /etc/github-runner/*; }
sha > /tmp/ghr-state-1.txt
run github-runner-2 ghr_install
sha > /tmp/ghr-state-2.txt
cmp -s /tmp/ghr-state-1.txt /tmp/ghr-state-2.txt && pass "github-runner rerun: files, modes and owners unchanged" || { diff /tmp/ghr-state-1.txt /tmp/ghr-state-2.txt; fail "github-runner rerun changed state"; }
check "github-runner rerun left no backup copies" bash -c '! ls /etc/github-runner/*.bak.* /usr/local/bin/github-runner-ctl.bak.* 2>/dev/null | grep -q .'
# a value given in the environment replaces the stored one; the key is kept without GH_KEY_SRC
run github-runner-3 env PATH="$GHR_STUB:$PATH" GH_MAX_JOBS=2 GH_EXCLUDE_REPOS=octo/scratch bash runner/install/github-runner.sh --no-self-test --no-start --no-pull
check "rerun with GH_MAX_JOBS=2 keeps the key and changes only that value" bash -c 'grep -qx "GH_MAX_JOBS=2" /etc/github-runner/config.env && grep -qx "GH_EXCLUDE_REPOS=octo/scratch" /etc/github-runner/config.env && cmp -s /tmp/ghr-test.pem /etc/github-runner/app.pem && ls /etc/github-runner/config.env.bak.* >/dev/null 2>&1'
check "the installer refuses unsafe characters in a value" bash -c '! PATH="$1:$PATH" GH_EXCLUDE_REPOS="a;b" bash runner/install/github-runner.sh --no-self-test --no-start --no-pull >/dev/null 2>&1' _ "$GHR_STUB"
check "the installer refuses a file that is not an RSA key" bash -c 'echo nope > /tmp/ghr-nokey.pem; ! PATH="$1:$PATH" GH_KEY_SRC=/tmp/ghr-nokey.pem bash runner/install/github-runner.sh --no-self-test --no-start --no-pull >/dev/null 2>&1' _ "$GHR_STUB"
# update.sh: an older image pin in config.env is replaced by the pin of common/lib.sh, the file keeps its owner and mode, the key is untouched
sed -i 's#^GH_RUNNER_IMAGE=.*#GH_RUNNER_IMAGE=example.org/stale-runner:1@sha256:0000000000000000000000000000000000000000000000000000000000000000#' /etc/github-runner/config.env
cmp -s /tmp/ghr-test.pem /etc/github-runner/app.pem || fail "key changed before the update test"
run github-runner-update env PATH="$GHR_STUB:$PATH" bash -c 'source runner/install/update.sh; BACKUP_DIR=/tmp/ghr-backup; WORK=$(mktemp -d); CHANGED=(); SKIPPED=(); update_github_runner'
check "update.sh: runner image pin follows common/lib.sh again" bash -c 'grep -qx "GH_RUNNER_IMAGE=$(sed -n "s/^GHR_RUNNER_IMAGE=\"\(.*\)\"\$/\1/p" common/lib.sh)" /etc/github-runner/config.env'
check "update.sh: config.env still 640 root:github-runner, key untouched" bash -c '[[ "$(stat -c %a:%U:%G /etc/github-runner/config.env)" == 640:root:github-runner ]] && cmp -s /tmp/ghr-test.pem /etc/github-runner/app.pem'
check "update.sh: the old config.env is in the backup folder" test -f /tmp/ghr-backup/etc/github-runner/config.env
# health reads the status file the controller writes; a fresh one for this check
now=$(date +%s)
cat > /tmp/ghr-status.json <<JSON
{"version":1,"updated":$now,"last_poll_ok":$now,"last_token_ok":$now,"last_error":null,"rate_remaining":4900,"rate_limit":5000,"served":3,"skipped":1,"active_pods":0,"idle_pods":0,"max_jobs":1,"update_required":false,"backoff_until":0,"runner_image_created":$((now - 86400))}
JSON
out=$(PATH="$GHR_STUB:$PATH" HEALTH_GHR_STATUS=/tmp/ghr-status.json /usr/local/bin/health -q --no-color --profile runner 2>&1); rc=$?
echo "$out" > /tmp/health-ghr.txt
(( rc <= 2 )) && pass "health with the GitHub runner installed: exit ${rc}" || fail "health with the GitHub runner installed: exit ${rc}"
grep -q "GitHub Actions runner" <<<"$out" && grep -q "last successful poll" <<<"$out" && grep -q "GitHub API quota: 4900 of 5000 left" <<<"$out" && pass "health shows the controller status (poll age, quota)" || fail "health lacks the GitHub runner section: $(grep -A8 'GitHub Actions' <<<"$out" | tr '\n' '|')"
grep -Eq "$BAD_RE|command not found" <<<"$out" && fail "health shell error with the GitHub runner installed" || pass "health: no bash errors with the GitHub runner installed"
systemctl stop docker.service; rm -f /etc/systemd/system/docker.service; systemctl daemon-reload
rm -rf /tmp/ghr-test.pem /tmp/ghr-nokey.pem "$GHR_STUB"

echo "== idempotency: run every component again"
snapshot > /tmp/state-1.txt
run users-2 bash runner/install/users.sh
run packages-2 bash common/admin-tools.sh
run host-tools-2 bash runner/install/host-tools.sh
run firewall-2 bash runner/install/host-firewall.sh
snapshot > /tmp/state-2.txt
if diff -u /tmp/state-1.txt /tmp/state-2.txt > /tmp/state.diff; then pass "second run changed no managed file, user, group or firewall rule"; else head -30 /tmp/state.diff; fail "second run changed managed state"; fi
exit $(( fails > 0 ))
