#!/usr/bin/env bash
# The cloud-init files a user pastes into Hetzner, tested on a REAL virtual machine: an official cloud image of the OS boots
# under QEMU/KVM with the repo's YAML as NoCloud user-data, UNCHANGED. A container cannot prove cloud-init itself, swap,
# kernel tuning, Docker, the firewall on a real kernel, or a reboot.
#   Usage: tools/ci/vm-e2e.sh KEY        KEY from tools/ci/vm-images.sh list (rocky10 alma10 centos10 fedora44 debian13 ubuntu2604
#                                         opensuse16 runner-rocky10 runner-debian13)
#   Needs: /dev/kvm (read-write), qemu-system-x86_64, qemu-img, ssh, ssh-keygen, genisoimage or xorriso, python3; OVMF for UEFI images.
#   Env:   ALLOW_LOCAL=1  required outside GitHub Actions (starts a VM, listens on 127.0.0.1:SSH_PORT, caches images in VM_CACHE)
#          VM_CACHE=DIR   downloaded images (default ~/.cache/server-init-vm; CI: .vm-cache)
#          VM_ACCEL=tcg  software emulation, ONLY to smoke-test this harness (far too slow for the real init)
#          SSH_PORT=2222  MEM_MB=4096  CPUS=2  DISK_GB=20  BOOT_TIMEOUT=900 (seconds until sshd answers)  KEEP=1 leave the VM running
# Server keys: cloud-init done without errors, schema, no failed step, tools/ci/server-assert.sh with an empty list of
# allowed failures (nothing may be allow-listed), swap, sysctl, Docker, firewall, fail2ban, ops over ssh + sudo; REBOOT and check again; rerun
# /usr/local/sbin/server-init.sh and compare the managed files. Runner keys: cloud-init done, Docker, gitlab-runner installed
# (NO token: nothing is registered), timers, job isolation rules, reboot and check again.
# Logs (redacted) go to ci-out/vm-KEY/. The throwaway SSH key lives in a temp dir and is never copied there.
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=vm-images.sh
source "$(dirname "${BASH_SOURCE[0]}")/vm-images.sh"

SSH_PORT="${SSH_PORT:-2222}"
MEM_MB="${MEM_MB:-4096}"
CPUS="${CPUS:-2}"
DISK_GB="${DISK_GB:-20}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-900}"

# --- pieces that are tested without a VM (tools/ci/vm-selftest.sh) ----------------------------------------------------------
# vm_make_seed OUT.iso PUBKEY_FILE USERDATA KEY: a NoCloud seed (volume label cidata). user-data is the repo file byte for
# byte. meta-data mirrors what Hetzner injects: instance-id, local-hostname and the SSH keys. vendor-data lifts the images'
# default "root login disabled" (Hetzner's own images allow root, and the init copies root's keys to the admin user).
vm_make_seed() {
  local out=$1 pub=$2 userdata=$3 key=$4 d
  [[ -f "$userdata" ]] || die "user-data file not found: $userdata"
  [[ -s "$pub" ]] || die "public key file empty: $pub"
  d=$(mktemp -d)
  cp "$userdata" "$d/user-data"
  printf 'instance-id: iid-ci-%s-%s\nlocal-hostname: ci-%s\npublic-keys:\n  - %s\n' "$key" "$(date +%s)" "$key" "$(cat "$pub")" > "$d/meta-data"
  printf '#cloud-config\ndisable_root: false\n' > "$d/vendor-data"
  if need genisoimage; then genisoimage -quiet -output "$out" -volid cidata -joliet -rock "$d/user-data" "$d/meta-data" "$d/vendor-data"
  elif need xorriso; then xorriso -as mkisofs -quiet -output "$out" -volid cidata -joliet -rock "$d/user-data" "$d/meta-data" "$d/vendor-data"
  else rm -rf "$d"; die "genisoimage or xorriso is required to build the cloud-init seed"; fi
  rm -rf "$d"
}

# vm_ovmf: prints "CODE VARS" paths of the OVMF firmware (UEFI) or fails.
vm_ovmf() {
  local c v
  for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/qemu/OVMF_CODE.fd; do
    [[ -f "$c" ]] || continue
    v=${c/CODE/VARS}
    [[ -f "$v" ]] && { echo "$c $v"; return 0; }
  done
  return 1
}

# --- the machine ----------------------------------------------------------------------------------------------------------
TMP="" W="" PIDFILE="" KEYFILE="" QEMU_PID=""

SSH_BASE=()
vm_ssh() { # USER COMMAND...   (run as USER on the VM)
  local u=$1; shift
  ssh "${SSH_BASE[@]}" "${u}@127.0.0.1" "$@"
}

vm_alive() { [[ -n "$QEMU_PID" ]] && kill -0 "$QEMU_PID" 2>/dev/null; }

vm_start() { # IMAGE SEED BOOT
  local image=$1 seed=$2 boot=$3 overlay="$TMP/disk.qcow2" fw
  qemu-img create -q -f qcow2 -F qcow2 -b "$(realpath "$image")" "$overlay" "${DISK_GB}G"
  local accel=(-enable-kvm -cpu "${VM_CPU:-host}")
  [[ "${VM_ACCEL:-kvm}" == tcg ]] && accel=(-accel tcg -cpu max)
  local args=(-machine q35 "${accel[@]}" -m "$MEM_MB" -smp "$CPUS"
    -display none -serial "file:$W/serial.log" -monitor none -no-user-config -nodefaults
    -pidfile "$PIDFILE" -daemonize
    -d "guest_errors,cpu_reset" -D "$W/qemu.log"
    -drive "file=$overlay,if=virtio,format=qcow2,cache=unsafe"
    -drive "file=$seed,if=virtio,format=raw,readonly=on"
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" -device "virtio-net-pci,netdev=n0"
    -device virtio-rng-pci)
  if [[ "$boot" == uefi ]]; then
    fw=$(vm_ovmf) || die "this image boots with UEFI but OVMF is not installed (apt install ovmf)"
    cp "${fw#* }" "$TMP/OVMF_VARS.fd"
    args+=(-drive "if=pflash,format=raw,unit=0,readonly=on,file=${fw%% *}" -drive "if=pflash,format=raw,unit=1,file=$TMP/OVMF_VARS.fd")
  fi
  # -nodefaults removes the VGA card and the serial device; -serial above adds the serial back. Nothing else is needed.
  qemu-system-x86_64 "${args[@]}"
  QEMU_PID=$(cat "$PIDFILE")
  log "qemu started, pid ${QEMU_PID}, ${CPUS} CPU, ${MEM_MB} MB, ${boot}, ssh on 127.0.0.1:${SSH_PORT}"
}

# Wait until root answers over ssh with our key. cloud-init writes the key late in the first boot, so early failures are normal.
# With SOFT=1 a timeout returns 1 (after showing the serial console) instead of ending the run.
vm_wait_ssh() { # SECONDS [SOFT]
  local deadline=$((SECONDS + $1)) out
  while (( SECONDS < deadline )); do
    vm_alive || { tail -n 40 "$W/serial.log" 2>/dev/null | ci_redact || true; die "qemu is not running any more"; }
    if out=$(vm_ssh root 'echo vm-ssh-ok' 2>/dev/null) && [[ "$out" == vm-ssh-ok ]]; then return 0; fi
    sleep 5
  done
  echo "serial console: $(wc -l < "$W/serial.log" 2>/dev/null || echo 0) lines, GRUB menu shown $(grep -c 'Booting `' "$W/serial.log" 2>/dev/null || true) time(s); head and tail:"
  { head -n 20 "$W/serial.log"; echo '[...]'; tail -n 40 "$W/serial.log"; } 2>/dev/null | ci_redact || true
  echo "qemu log, $(grep -c 'CPU Reset' "$W/qemu.log" 2>/dev/null || true) 'CPU Reset' lines (one per vCPU at power-on, more means the guest reset itself); tail:"
  tail -n 30 "$W/qemu.log" 2>/dev/null | ci_redact || true
  [[ "${2:-}" == 1 ]] && return 1
  die "no ssh login as root within $1 s (see the serial console above)"
}

# Stop qemu and wait until it is gone: it is daemonized, so it cannot be waited on and the disk lock must be free before the
# next qemu-img create / qemu-system on the same overlay.
vm_stop() {
  local n=0
  kill "$QEMU_PID" 2>/dev/null || true
  while vm_alive && (( n++ < 50 )); do sleep 0.2; done
  if vm_alive; then kill -9 "$QEMU_PID" 2>/dev/null || true; n=0; while vm_alive && (( n++ < 25 )); do sleep 0.2; done; fi
  ! vm_alive || die "qemu pid ${QEMU_PID} does not exit"
}

# First boot. A guest that never gets to sshd (seen as a GRUB menu printed over and over, or a silent console) is started once
# more with a fixed baseline CPU model before the run is given up. The logs so far point at the image, not the CPU (the same
# runner CPUs boot other images), so this is cheap insurance and not the fix; qemu's own log ($W/qemu.log: guest errors and
# CPU resets) says what the guest did. Not with VM_ACCEL=tcg: that already runs -cpu max, a retry would repeat the same boot.
vm_first_boot() { # IMAGE SEED BOOT
  local fast=${BOOT_FAST_TIMEOUT:-300}
  vm_start "$1" "$2" "$3"
  if [[ "${VM_ACCEL:-kvm}" == tcg ]]; then vm_wait_ssh "$BOOT_TIMEOUT"; return; fi
  vm_wait_ssh "$fast" 1 && return 0
  warn "no ssh within ${fast} s with -cpu ${VM_CPU:-host}; retrying once with -cpu Haswell-noTSX (x86-64-v3, fixed feature set)"
  vm_stop; : > "$W/serial.log"; mv -f "$W/qemu.log" "$W/qemu-first-try.log" 2>/dev/null || true
  VM_CPU=Haswell-noTSX vm_start "$1" "$2" "$3"
  vm_wait_ssh $(( BOOT_TIMEOUT > fast ? BOOT_TIMEOUT - fast : 300 ))
}

# Pull diagnostics out of the VM (best effort, redacted) into $W/guest/.
vm_collect() {
  local g="$W/guest" f
  mkdir -p "$g"
  vm_alive || return 0
  for f in /var/log/cloud-init.log /var/log/cloud-init-output.log /var/log/server-init-failed.log /var/log/ci-bootstrap-failed.log /etc/server-init.conf; do
    timeout 60 ssh "${SSH_BASE[@]}" "root@127.0.0.1" "cat $f" > "$g/$(basename "$f")" 2>/dev/null || rm -f "$g/$(basename "$f")"
  done
  timeout 120 ssh "${SSH_BASE[@]}" "root@127.0.0.1" '
    echo "--- cloud-init status"; cloud-init status --long 2>&1
    echo "--- failed units"; systemctl --failed --no-pager 2>&1
    echo "--- swap"; cat /proc/swaps; free -m
    echo "--- listening"; ss -ltn 2>&1
    echo "--- firewall"; { ufw status verbose; firewall-cmd --list-all; nft list ruleset | head -80; iptables -S | head -60; } 2>&1
    echo "--- docker"; docker ps -a 2>&1 | head -20
    echo "--- hostname"; hostname; hostnamectl 2>&1 | head -12; systemctl status systemd-hostnamed --no-pager 2>&1 | head -15
    echo "--- journal, warnings and worse, this boot"; journalctl -b -p warning --no-pager -n 300 2>&1
    echo "--- journal of the key units"; journalctl -b --no-pager -n 200 -u cloud-init-local -u cloud-init -u cloud-config -u cloud-final -u ssh -u sshd -u docker -u firewalld -u fail2ban 2>&1' \
    > "$g/diagnostics.txt" 2>&1 || true
  [[ -f "$W/serial.log" ]] && cp "$W/serial.log" "$g/serial.log"
  for f in "$W"/qemu*.log; do [[ -f "$f" ]] && cp "$f" "$g/"; done
  for f in "$g"/*; do [[ -f "$f" ]] && ci_redact_file "$f"; done
  if [[ -f "$g/cloud-init.log" ]] && grep -qi 'hostname' "$g/cloud-init.log"; then
    echo "--- hostname lines of cloud-init.log"; grep -i 'hostname' "$g/cloud-init.log" | cut -c1-400 | head -n 60
  fi
  return 0
}

cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n "$W" ]]; then
    vm_collect 2>/dev/null || true
    [[ -f "$W/serial.log" ]] && ci_redact_file "$W/serial.log"
  fi
  if [[ "${KEEP:-0}" != 1 ]]; then
    if vm_alive; then kill "$QEMU_PID" 2>/dev/null || true; fi
    [[ -n "$TMP" ]] && rm -rf "$TMP"
  else
    log "KEEP=1: VM pid ${QEMU_PID:-none}, ssh -p ${SSH_PORT} -i ${KEYFILE:-?} root@127.0.0.1 (files in ${TMP:-?})"
  fi
  exit "$rc"
}

# Run the in-guest checks and count their result.
guest_checks() { # PHASE
  local phase=$1 out="$W/guest-checks-$1.log" rc=0
  timeout 600 ssh "${SSH_BASE[@]}" root@127.0.0.1 "bash -s -- ${VM_ROLE} ${VM_KIND} ${phase}" < "$CI_ROOT/tools/ci/vm-guest-checks.sh" > "$out" 2>&1 || rc=$?
  ci_redact_file "$out"
  cat "$out"
  if ! grep -q '^CHECKS-DONE$' "$out"; then fail "in-guest checks (${phase}) did not run to the end (ssh exit ${rc})"
  elif grep -q '^  FAIL  ' "$out" || (( rc != 0 )); then fail "in-guest checks (${phase}) failed"
  else pass "in-guest checks (${phase})"; fi
}

ops_check() { # PHASE
  local who
  if who=$(vm_ssh ops 'echo "$(id -un) $(sudo -n id -un)"' 2>&1) && [[ "$who" == "ops root" ]]; then pass "$1: ops logs in with the same key and sudo -n works"
  else fail "$1: ops login or sudo -n failed: $(tr '\n' ' ' <<<"$who" | cut -c1-300)"; fi
}

# The files and rules the init manages, hashed inside the VM (same set as tools/ci/server-e2e.sh).
snapshot() {
  vm_ssh root 'find /etc/ssh/sshd_config.d /etc/sysctl.d /etc/sudoers.d /etc/fail2ban/jail.d /etc/server-init.conf /etc/profile.d /etc/systemd/system /usr/local/bin /usr/local/sbin /etc/security /etc/systemd/journald.conf.d /etc/apt/apt.conf.d /etc/dnf/automatic.conf /etc/docker /etc/fstab -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null; echo ---; ufw show added 2>/dev/null; firewall-cmd --permanent --list-all 2>/dev/null; swapon --noheadings --show=NAME 2>/dev/null; true'
}

failed_log_empty() { # DESC
  if vm_ssh root '[ ! -e /var/log/server-init-failed.log ] || [ ! -s /var/log/server-init-failed.log ]'; then pass "$1: /var/log/server-init-failed.log absent or empty"
  else fail "$1: /var/log/server-init-failed.log has entries: $(vm_ssh root 'tail -n 20 /var/log/server-init-failed.log' 2>&1 | tr '\n' '|' | cut -c1-600)"; fi
}

reboot_vm() {
  local old new i
  old=$(vm_ssh root 'cat /proc/sys/kernel/random/boot_id')
  vm_ssh root 'systemctl reboot' >/dev/null 2>&1 || true
  sleep 10
  for ((i = 0; i < 60; i++)); do
    vm_alive || die "qemu exited during the reboot"
    new=$(vm_ssh root 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null) && [[ -n "$new" && "$new" != "$old" ]] && { pass "rebooted: new boot id"; return 0; }
    sleep 5
  done
  fail "the VM did not come back after the reboot within about 10 min"
  return 1
}

main() {
  local key=${1:-}
  [[ -n "$key" ]] || die "usage: $0 KEY   (one of: ${VM_KEYS[*]})"
  vm_catalogue "$key" || die "unknown image key: $key (known: ${VM_KEYS[*]})"
  in_ci || [[ "${ALLOW_LOCAL:-0}" == 1 ]] || die "this starts a VM, listens on 127.0.0.1:${SSH_PORT} and downloads an image: set ALLOW_LOCAL=1"
  local t
  for t in qemu-system-x86_64 qemu-img ssh ssh-keygen python3; do need "$t" || die "$t is not installed"; done
  if [[ "${VM_ACCEL:-kvm}" == kvm ]]; then
    [[ -e /dev/kvm ]] || die "/dev/kvm does not exist. On a GitHub-hosted Linux runner enable it first (see .github/workflows/vm.yml: udev rule, then udevadm trigger); a VM without KVM would be far too slow"
    [[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm is not readable and writable for $(id -un): on a runner apply the udev rule KERNEL==\"kvm\", GROUP=\"kvm\", MODE=\"0666\""
  fi
  [[ -f "$CI_ROOT/$VM_USERDATA" ]] || die "cloud-init file missing: $VM_USERDATA"

  W="$CI_OUT/vm-${key}"; mkdir -p "$W"
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/vm-e2e.XXXXXX"); PIDFILE="$TMP/qemu.pid"; KEYFILE="$TMP/id"
  trap cleanup EXIT

  group "image ${key}"
  local image
  image=$(vm_fetch "$key" "${VM_CACHE:-${HOME:-/tmp}/.cache/server-init-vm}")
  ls -l "$image"
  endgroup

  # Throwaway identity; host keys are new on every boot, so host key checking is off for this loopback forward only.
  ssh-keygen -q -t ed25519 -N '' -C "ci-vm-${key}" -f "$KEYFILE" <<<y >/dev/null 2>&1 || true
  [[ -s "$KEYFILE.pub" ]] || die "could not generate the throwaway ssh key"
  SSH_BASE=(-p "$SSH_PORT" -i "$KEYFILE" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=8)

  group "boot ${key} with ${VM_USERDATA} (${VM_BOOT})"
  vm_make_seed "$TMP/seed.iso" "$KEYFILE.pub" "$CI_ROOT/$VM_USERDATA" "$key"
  vm_first_boot "$image" "$TMP/seed.iso" "$VM_BOOT"
  log "ssh is up after ${SECONDS} s"
  endgroup

  group "1. cloud-init finished without errors"
  local ci_out="$W/cloud-init-status.txt" ci_rc=0 i
  # sshd comes up while cloud-init still runs; the wait can be cut by an sshd reload or restart, so it is retried.
  for i in 1 2 3; do
    ci_rc=0
    timeout 1200 ssh "${SSH_BASE[@]}" root@127.0.0.1 'cloud-init status --wait --long' > "$ci_out" 2>&1 || ci_rc=$?
    (( ci_rc == 255 )) || break
    log "ssh dropped while waiting for cloud-init (try ${i}), retrying"; vm_wait_ssh 120
  done
  cat "$ci_out"
  expect_eq "cloud-init status --wait exit code" "$ci_rc" 0
  # --wait prints progress dots without a newline, so the first line is ".....status: done"; strip them before matching. The
  # extended status must be a plain "done" too ("degraded done" means a module reported a recoverable error).
  local ci_txt; ci_txt=$(sed 's/^\.*//' "$ci_out")
  grep -qx 'status: done' <<<"$ci_txt" && pass "cloud-init status is done" || fail "cloud-init status is not 'done'"
  grep -qx 'extended_status: done' <<<"$ci_txt" && pass "cloud-init extended status is done" || fail "cloud-init extended status is not 'done' ($(grep -m1 '^extended_status:' <<<"$ci_txt"))"
  local js errs
  js=$(vm_ssh root 'cloud-init status --format json' 2>/dev/null || true)
  if [[ -n "$js" ]]; then
    errs=$(python3 -I -c 'import json,sys; d=json.load(sys.stdin); r=d.get("recoverable_errors") or {}; print(len(d.get("errors") or []) + sum(len(v) for v in r.values()))' <<<"$js" 2>/dev/null || echo "?")
    expect_eq "cloud-init reports no errors" "$errs" 0
  else warn "cloud-init status --format json is not available on this version"; fi
  if vm_ssh root 'cloud-init schema --help >/dev/null 2>&1'; then
    local sc_rc=0 sc
    sc=$(vm_ssh root 'cloud-init schema --system' 2>&1) || sc_rc=$?
    echo "$sc" | head -20
    if (( sc_rc == 0 )); then pass "cloud-init schema --system is clean"; else fail "cloud-init schema --system exit ${sc_rc}"; fi
  else warn "cloud-init schema is not available on this version"; fi
  endgroup

  if [[ "$VM_ROLE" == server ]]; then
    group "2. the init: no failed step, assertions (nothing allow-listed)"
    failed_log_empty "first boot"
    vm_ssh root 'grep -h "done, all steps ok\|done with failures" /var/log/cloud-init-output.log | tail -2' | sed 's/^/  init: /' || true
    vm_ssh root 'grep -q "done, all steps ok" /var/log/cloud-init-output.log' && pass "server-init reported 'done, all steps ok'" || fail "server-init did not report 'done, all steps ok' in cloud-init-output.log"
    # copy the repo in (not .git, not outputs, not the image cache) and run the same assertions the container test runs
    tar -C "$CI_ROOT" --exclude=./.git --exclude=./ci-out --exclude=./.vm-cache -czf - . | timeout 300 ssh "${SSH_BASE[@]}" root@127.0.0.1 'rm -rf /root/ci-repo && mkdir -p /root/ci-repo && tar -xzf - -C /root/ci-repo'
    local a_rc=0
    timeout 600 ssh "${SSH_BASE[@]}" root@127.0.0.1 "ASSERT_MODE=cloud-init bash /root/ci-repo/tools/ci/server-assert.sh ${VM_KIND} ''" > "$W/assert.log" 2>&1 || a_rc=$?
    ci_redact_file "$W/assert.log"; cat "$W/assert.log"
    if ! grep -q '^ASSERT-DONE$' "$W/assert.log"; then fail "server-assert.sh did not run to the end (exit ${a_rc})"
    elif grep -q '^  FAIL  ' "$W/assert.log" || (( a_rc != 0 )); then fail "server-assert.sh failed (exit ${a_rc})"
    else pass "server-assert.sh (no allow-list)"; fi
    endgroup
  fi

  group "3. the machine as booted: swap, sysctl, Docker, firewall, fail2ban, timers"
  guest_checks first
  [[ "$VM_ROLE" == server ]] && ops_check "first boot"
  endgroup

  group "4. reboot, then the same machine again"
  if reboot_vm; then
    vm_wait_ssh 300
    timeout 600 ssh "${SSH_BASE[@]}" root@127.0.0.1 'cloud-init status --wait' >/dev/null 2>&1 || true
    guest_checks reboot
    [[ "$VM_ROLE" == server ]] && ops_check "after reboot"
    [[ "$VM_ROLE" == server ]] && failed_log_empty "after reboot"
  fi
  endgroup

  if [[ "$VM_ROLE" == server ]]; then
    group "5. server-init.sh again: idempotent"
    snapshot > "$W/state-1.txt"
    local r_rc=0
    timeout 900 ssh "${SSH_BASE[@]}" root@127.0.0.1 '/usr/local/sbin/server-init.sh' > "$W/rerun.log" 2>&1 || r_rc=$?
    ci_redact_file "$W/rerun.log"; tail -15 "$W/rerun.log"
    expect_eq "server-init.sh rerun exit code" "$r_rc" 0
    grep -q 'done, all steps ok' "$W/rerun.log" && pass "rerun: all steps ok" || fail "rerun: not 'done, all steps ok'"
    failed_log_empty "after the rerun"
    snapshot > "$W/state-2.txt"
    if diff -u "$W/state-1.txt" "$W/state-2.txt" > "$W/state.diff"; then pass "rerun changed no managed file, firewall rule or swap ($(wc -l < "$W/state-1.txt") entries compared)"
    else head -30 "$W/state.diff"; fail "rerun changed managed files (diff above)"; fi
    guest_checks after-rerun
    endgroup
  fi

  finish
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
