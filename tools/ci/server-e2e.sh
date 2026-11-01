#!/usr/bin/env bash
# End-to-end test of a plain server on one OS image: a systemd container, the REAL server/bootstrap.sh over its sshd with a
# throwaway key (real package mirrors), then assertions inside the container (tools/ci/server-assert.sh).
#   Usage: tools/ci/server-e2e.sh IMAGE        e.g. rockylinux/rockylinux:10, debian:13, opensuse/leap:16.0
#   Env:   KEEP=1 keep the container for debugging; ALLOW_DIRTY=1 test HEAD although the tree has changes;
#          STRICT=1 empty the allow-list of container-only failures (shows what a container really cannot do).
# Container-only failures: server-init exits 1, bootstrap.sh stops before step 2, so the test runs step 2 itself (see boot()).
# Steps: 1 bootstrap --dry-run (no target); 2 bootstrap as root (first run); 3 assertions; 4 bootstrap again (idempotency:
# the managed config files must be byte-identical afterwards); 5 bootstrap as the admin user over sudo.
set -Eeuo pipefail
# shellcheck source=systemd-lib.sh
source "$(dirname "$0")/systemd-lib.sh"
cd "$CI_ROOT"

IMAGE="${1:?usage: $0 IMAGE}"
SLUG=$(tr -c 'A-Za-z0-9\n' '_' <<<"$IMAGE")
NAME="srv-e2e-${SLUG}"
TAG="srv-e2e-img:${SLUG}"
W="$CI_OUT/server-${SLUG}"
mkdir -p "$W"
need docker || die "docker is required"
need ssh-keygen || die "ssh-keygen is required"
need ssh-keyscan || die "ssh-keyscan is required"

# --- which init script the OS must pick, and which steps may fail inside a container -------------------------------------
case "$IMAGE" in
  *centos* | *rocky* | *almalinux*) KIND=el10 ;;
  *fedora*) KIND=fedora ;;
  *ubuntu* | *debian*) KIND=debian ;;
  *opensuse*) KIND=opensuse ;;
  *) die "unknown image family: $IMAGE" ;;
esac
# Steps of server-init that a container cannot do. Everything else must be "ok"; a failure there is a real bug.
#   swap          swapon on a file inside an overlayfs container is refused by the kernel (and must not be done on the CI host)
#   system-tuning part of the sysctl keys are not settable from a container (read-only or host-owned /proc/sys entries)
#   docker        Docker Engine inside a container needs its own storage driver and cgroup setup; the install is tried, the
#                 daemon may not start. (If it does, the step is "ok" and nothing is skipped.)
ALLOWED="swap system-tuning docker"
if [[ "${STRICT:-0}" == 1 ]]; then ALLOWED=""; fi
log "image ${IMAGE} -> init kind ${KIND}; allowed container-only failures: ${ALLOWED:-none}"

cleanup() {
  local rc=$?
  sd_collect "$NAME" "$W/collected" 2>/dev/null || true
  if [[ "${KEEP:-0}" != 1 ]]; then docker rm -f "$NAME" >/dev/null 2>&1 || true; fi
  exit "$rc"
}
trap cleanup EXIT

group "build and start the systemd machine (${IMAGE})"
sd_build "$IMAGE" "$TAG" 2>&1 | tee "$W/build.log" | tail -5
sd_run "$NAME" "$TAG"
sd_exec "$NAME" sh -c '. /etc/os-release; echo "${ID}:${VERSION_ID} ${PRETTY_NAME}"' | tee "$W/os.txt"
endgroup

# --- throwaway SSH identity; ssh gets its config through a wrapper because OpenSSH ignores $HOME for ~/.ssh --------------
ssh-keygen -q -t ed25519 -N '' -C ci-test -f "$W/id" <<<y >/dev/null 2>&1 || true
docker exec "$NAME" sh -c 'install -d -m 0700 /root/.ssh'
docker cp "$W/id.pub" "$NAME:/root/.ssh/authorized_keys"
docker exec "$NAME" sh -c 'chown root:root /root/.ssh/authorized_keys && chmod 0600 /root/.ssh/authorized_keys'
IP=$(sd_ip "$NAME")
log "container IP ${IP}"
for _ in $(seq 1 30); do ssh-keyscan -T 3 -t ed25519 "$IP" > "$W/known_hosts" 2>/dev/null && [[ -s "$W/known_hosts" ]] && break; sleep 2; done
[[ -s "$W/known_hosts" ]] || die "sshd in the container does not answer"
cat > "$W/ssh_config" <<CONF
Host *
  IdentityFile $W/id
  IdentitiesOnly yes
  UserKnownHostsFile $W/known_hosts
  StrictHostKeyChecking yes
CONF
mkdir -p "$W/bin"
printf '#!/bin/sh\nexec /usr/bin/ssh -F "%s" "$@"\n' "$W/ssh_config" > "$W/bin/ssh"; chmod +x "$W/bin/ssh"
export PATH="$W/bin:$PATH"
BOOT=(server/bootstrap.sh)
[[ "${ALLOW_DIRTY:-0}" == 1 ]] && BOOT+=(--allow-dirty)

failed_steps() { sed -n 's/.*done with failures: \(.*\) (details.*/\1/p' "$1" | tail -1; }
# every failed step must be in the allow-list
check_failed() { # desc logfile -> sets FAILED_LIST
  FAILED_LIST=$(failed_steps "$2")
  local s bad=""
  for s in $FAILED_LIST; do [[ " $ALLOWED " == *" $s "* ]] || bad+=" $s"; done
  if [[ -z "$bad" ]]; then pass "$1: no unexpected failed step (failed: ${FAILED_LIST:-none})"; else
    fail "$1: steps failed that a container can do:${bad}"
    docker exec "$NAME" sh -c 'tail -n 40 /var/log/server-init-failed.log' 2>&1 | sed 's/^/    init-failed: /' || true
  fi
}
snapshot() { # config files the init manages, hashed inside the container
  docker exec "$NAME" sh -c 'find /etc/ssh/sshd_config.d /etc/sysctl.d /etc/sudoers.d /etc/fail2ban/jail.d /etc/server-init.conf /etc/profile.d /etc/systemd/system /usr/local/bin /usr/local/sbin /etc/security /etc/systemd/journald.conf.d /etc/apt/apt.conf.d /etc/dnf/automatic.conf -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null; echo ---; ufw show added 2>/dev/null; firewall-cmd --permanent --list-all 2>/dev/null; true'
}

# boot LOG [bootstrap options...] -> BOOT_RC. Runs the real bootstrap against the container.
# server-init exits 1 when any step fails, and bootstrap.sh then stops before step 2 (install-tools.sh / install-health.sh), so
# a container-only failure would leave out health, srv and server-cleanup. When every failed step is in the allow-list, step 2
# is run here over the same ssh wrapper, exactly as bootstrap.sh would, and the run counts as successful. A failure outside the
# allow-list (or any STRICT=1 failure) keeps bootstrap's non-zero exit code.
boot() {
  local logf="$1" sudo="" user=root step2 failed s
  shift
  [[ " $* " == *" --user "* ]] && { sudo="sudo -n "; user=ops; }
  BOOT_RC=0
  "${BOOT[@]}" "$@" "$IP" > "$logf" 2>&1 || BOOT_RC=$?
  (( BOOT_RC != 0 )) || return 0
  grep -q 'server-init failed' "$logf" || return 0
  failed=$(failed_steps "$logf")
  [[ -n "$failed" ]] || return 0
  for s in $failed; do [[ " $ALLOWED " == *" $s "* ]] || return 0; done
  case "$KIND" in fedora | el10) step2=server/install-tools.sh ;; *) step2=server/install-health.sh ;; esac
  log "init failed only in allowed steps (${failed}); running ${step2} as bootstrap would have"
  BOOT_RC=0
  { echo "== ${step2} (run by the test: bootstrap stops after a failed init step)"
    ssh -p 22 -o BatchMode=yes "${user}@${IP}" "${sudo}bash -c 'cd /root/server-init-config && bash ${step2}'"
  } >> "$logf" 2>&1 || BOOT_RC=$?
}

group "1. bootstrap --dry-run (nothing is touched)"
if "${BOOT[@]}" --dry-run --os "$KIND" 192.0.2.10 > "$W/dry-run.log" 2>&1; then pass "bootstrap --dry-run exits 0"; else tail -20 "$W/dry-run.log"; fail "bootstrap --dry-run"; fi
grep -q '\[dry-run\]' "$W/dry-run.log" && pass "dry-run prints the planned ssh commands" || fail "dry-run printed nothing planned"
grep -q "server/server-init-${KIND}.sh" "$W/dry-run.log" && pass "dry-run plans server-init-${KIND}.sh" || fail "dry-run does not plan server-init-${KIND}.sh"
endgroup

group "2. bootstrap, first run (real mirrors)"
boot "$W/bootstrap-1.log"; rc=$BOOT_RC
tail -40 "$W/bootstrap-1.log"
# health exits 1 or 2 on a container (warnings); bootstrap only warns about that, so rc is 0 when the init worked.
expect_eq "bootstrap run 1 exit code" "$rc" 0
grep -q "OS: .* -> ${KIND}" "$W/bootstrap-1.log" && pass "OS detected as ${KIND}: $(grep -m1 'OS: ' "$W/bootstrap-1.log" | sed 's/^\[[^]]*\] //')" || fail "bootstrap did not detect OS as ${KIND}"
check_failed "run 1" "$W/bootstrap-1.log"
grep -qE 'ok: (packages|configs)' "$W/bootstrap-1.log" && pass "init steps logged ok" || fail "no 'ok: step' lines in the output"
FIRST_FAILED="$FAILED_LIST"
endgroup

group "3. assertions inside the machine"
# No `|| true` after the pipeline: it would overwrite PIPESTATUS, and assert_rc would always be 0.
set +e
docker exec -i "$NAME" bash -s -- "$KIND" "$FIRST_FAILED" < tools/ci/server-assert.sh 2>&1 | tee "$W/assert.log"
assert_rc=${PIPESTATUS[0]}
set -e
if ! grep -q '^ASSERT-DONE$' "$W/assert.log"; then fail "assertions did not run to the end (no ASSERT-DONE marker, docker exec exit ${assert_rc})"
elif grep -q '  FAIL  ' "$W/assert.log" || (( assert_rc != 0 )); then fail "assertions inside the machine failed (exit ${assert_rc}, see above)"
else pass "assertions inside the machine"; fi
endgroup

group "4. bootstrap again: idempotent"
snapshot > "$W/state-1.txt"
boot "$W/bootstrap-2.log"; rc=$BOOT_RC
tail -15 "$W/bootstrap-2.log"
expect_eq "bootstrap run 2 exit code" "$rc" 0
check_failed "run 2" "$W/bootstrap-2.log"
expect_eq "same failed steps on rerun" "$FAILED_LIST" "$FIRST_FAILED"
snapshot > "$W/state-2.txt"
if diff -u "$W/state-1.txt" "$W/state-2.txt" > "$W/state.diff"; then pass "rerun changed no managed file or firewall rule ($(wc -l < "$W/state-1.txt") entries compared)"; else head -30 "$W/state.diff"; fail "rerun changed managed files (diff above)"; fi
endgroup

group "5. bootstrap as the admin user (ssh + sudo -n)"
boot "$W/bootstrap-3.log" --user ops; rc=$BOOT_RC
tail -15 "$W/bootstrap-3.log"
expect_eq "bootstrap --user ops exit code" "$rc" 0
check_failed "run 3 (ops)" "$W/bootstrap-3.log"
endgroup

finish
