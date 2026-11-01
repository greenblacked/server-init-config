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
# local-hostname stays in the seed on purpose: Hetzner's datasource is a local-stage one too (DEP_FILESYSTEM, sets local-hostname
# from the metadata), so a real server makes the same early hostname attempt. If Fedora ends "degraded done" because of it,
# that is a finding, not a seed to adjust; vm_collect records the hostnamectl/bus evidence.
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
  log "host: $(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1), qemu $(qemu-system-x86_64 --version | sed -n '1s/.*version //p'), kernel $(uname -r), guest cpu ${VM_CPU:-host}"
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
  # vm_collect runs from cleanup(), after the reboot phase, so a plain `journalctl -b` is the LAST boot. The failures of interest (cloud-init
  # local stage, hostnamectl without a bus) happen on the FIRST boot, so select it by boot id: the oldest line of --list-boots. If the journal
  # is volatile the first boot is gone and this falls back to the current one (the listing printed below shows which).
  local fb='FB=$(journalctl --list-boots --no-pager 2>/dev/null | grep -oE -m1 "[0-9a-f]{32}"); B="-b ${FB:-0}"'
  mkdir -p "$g"
  vm_alive || return 0
  for f in /var/log/cloud-init.log /var/log/cloud-init-output.log /var/log/server-init-failed.log /var/log/server-init-docker.log /var/log/ci-bootstrap-failed.log /etc/server-init.conf; do
    timeout 60 ssh "${SSH_BASE[@]}" "root@127.0.0.1" "cat $f" > "$g/$(basename "$f")" 2>/dev/null || rm -f "$g/$(basename "$f")"
  done
  timeout 120 ssh "${SSH_BASE[@]}" "root@127.0.0.1" "$fb"'
    echo "--- cloud-init status"; cloud-init status --long 2>&1
    echo "--- failed units"; systemctl --failed --no-pager 2>&1
    echo "--- swap"; cat /proc/swaps; free -m
    echo "--- listening"; ss -ltn 2>&1
    echo "--- firewall"; { ufw status verbose; firewall-cmd --list-all; nft list ruleset | head -80; iptables -S | head -60; } 2>&1
    echo "--- docker"; docker ps -a 2>&1 | head -20
    echo "--- hostname"; hostname; hostnamectl 2>&1 | head -12; systemctl status systemd-hostnamed --no-pager 2>&1 | head -15
    echo "--- boots in the journal (the first one is used below; cleanup runs after the reboot phase, so -b alone would be the last boot)"
    journalctl --list-boots --no-pager 2>&1 | cut -c1-200; echo "first boot id: ${FB:-none (volatile journal: current boot used)}"
    echo "--- hostname and bus in the journal of the FIRST boot with monotonic time (what hostnamectl printed in the cloud-init local stage, and whether D-Bus was up yet)"
    journalctl $B -o short-monotonic --no-pager -u systemd-hostnamed -u dbus -u dbus-broker -u dbus.socket -u cloud-init-main -u cloud-init-local -u cloud-init -g "hostname|bus|D-Bus|Failed to set" -n 120 2>&1 | cut -c1-400
    echo "--- journal, warnings and worse, this boot"; journalctl -b -p warning --no-pager -n 300 2>&1
    echo "--- journal of the key units"; journalctl -b --no-pager -n 200 -u cloud-init-main -u cloud-init-local -u cloud-init -u cloud-config -u cloud-final -u ssh -u sshd -u docker -u firewalld -u fail2ban 2>&1' \
    > "$g/diagnostics.txt" 2>&1 || true
  [[ -f "$W/serial.log" ]] && cp "$W/serial.log" "$g/serial.log"
  for f in "$W"/qemu*.log; do [[ -f "$f" ]] && cp "$f" "$g/"; done
  for f in "$g"/*; do [[ -f "$f" ]] && ci_redact_file "$f"; done
  if [[ -f "$g/cloud-init.log" ]] && grep -qi 'hostname' "$g/cloud-init.log"; then
    echo "--- hostname lines of cloud-init.log (with the command's stderr that follows a failure)"; grep -i -A6 'hostname' "$g/cloud-init.log" | cut -c1-400 | head -n 120
    # Why the local stage had no system bus. Since cloud-init 24.3 every stage runs in cloud-init-main.service (cloud-init-local.service is
    # only a shim), so its After/Requires on dbus.socket is what matters; the unit timings come from the journal of the FIRST boot (the
    # unit properties of a running system only describe the last boot).
    echo "--- versions and boot ordering (cloud-init-main against dbus and hostnamed)"
    timeout 60 ssh "${SSH_BASE[@]}" "root@127.0.0.1" "$fb"'
      echo "first boot id: ${FB:-none (volatile journal: current boot used)}"
      rpm -q cloud-init systemd dbus-broker dbus-daemon 2>&1 | head -6
      for u in cloud-init-main cloud-init-local; do echo "# systemctl cat $u.service"; systemctl cat $u.service 2>&1 | grep -E "^(#|\[|Description|DefaultDependencies|After|Before|Wants|Requires|ExecStart)" | head -20; done
      systemctl show cloud-init-main.service cloud-init-local.service dbus.socket dbus-broker.service dbus.service systemd-hostnamed.service -p Id -p After -p Requires -p Wants 2>&1 | cut -c1-300 | head -60
      echo "# current boot: system bus socket"; ls -ld /run/dbus /run/dbus/system_bus_socket 2>&1
      echo "# first boot: unit start order with monotonic time"
      journalctl $B -o short-monotonic --no-pager -g "Starting cloud-init|Listening on D-Bus|Started D-Bus|dbus|D-Bus|hostnamed|Cloud-init: Local|Finished cloud-init" -n 40 2>&1 | cut -c1-240' 2>&1 | ci_redact || true
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
  else
    # the whole file, one entry per line (a one-line summary cut off the dockerd error that mattered)
    echo "--- /var/log/server-init-failed.log ($1)"; vm_ssh root 'cat /var/log/server-init-failed.log' 2>&1 | cut -c1-400 | head -n 120 | ci_redact || true
    fail "$1: /var/log/server-init-failed.log has entries (listed above): $(vm_ssh root 'head -n 3 /var/log/server-init-failed.log' 2>&1 | tr '\n' '|' | cut -c1-300)"
  fi
}

# The Docker start log of the init (server-init-docker.log, written only when a start attempt failed), shown whenever it exists:
# a reboot may have cured Docker, the log still says what failed.
show_docker_log() { # DESC
  if vm_ssh root 'test -s /var/log/server-init-docker.log'; then
    warn "$1: Docker did not start on a try (log below); a reboot or retry may have cured it"
    echo "--- /var/log/server-init-docker.log ($1): Docker did not start on a try"
    vm_ssh root 'cat /var/log/server-init-docker.log' 2>&1 | cut -c1-300 | head -n 300 | ci_redact || true
  fi
}

# Known Fedora 44 image issue, allowed narrowly. cloud-init's LOCAL stage runs `hostnamectl set-hostname <local-hostname>` before the
# D-Bus system bus exists ("Failed to connect to system scope bus"), logs "Will retry in network stage", and the retry succeeds, but
# cloud-init then reports "degraded done" (exit 2) with one recoverable WARNING. That stage runs before user-data is consumed, so
# nothing in the cloud-init file can prevent it. The allowance holds only when ALL of these are true; anything else still fails:
# Fedora, status done / extended_status exactly "degraded done", no errors, the only recoverable error is exactly the hostname
# WARNING for the seed's local-hostname, cloud-init.log shows the bus failure and the retry, and the live hostname is correct.
# Args: OS_ID LOCAL_HOSTNAME STATUS_TEXT_FILE STATUS_JSON_FILE CLOUD_INIT_LOG_FILE LIVE_HOSTNAME [STATIC_HOSTNAME]
vm_hostname_race_allowed() {
  local osid=$1 want=$2 st=$3 js=$4 lg=$5 live=$6 stat=${7:-$6}
  [[ "$osid" == fedora && -n "$want" ]] || return 1
  grep -qx 'status: done' "$st" && grep -qx 'extended_status: degraded done' "$st" || return 1
  python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1])); want = sys.argv[2]
r = d.get("recoverable_errors") or {}
msg = "Failed to set the hostname to %s (%s)" % (want, want)
ok = (not d.get("errors")) and list(r) == ["WARNING"] and r["WARNING"] == [msg]
sys.exit(0 if ok else 1)' "$js" "$want" 2>/dev/null || return 1
  grep -q 'Failed to connect to system scope bus' "$lg" && grep -q 'Will retry in network stage' "$lg" || return 1
  [[ "$live" == "$want" && "$stat" == "$want" ]]
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
  # sshd comes up while cloud-init still runs; the wait can be cut by an sshd reload or restart, or by the one reboot the EL10
  # init or the Rocky runner file does at the end of the first boot when a new kernel was installed, so it is retried.
  for i in 1 2 3 4 5; do
    ci_rc=0
    timeout 1200 ssh "${SSH_BASE[@]}" root@127.0.0.1 'cloud-init status --wait --long' > "$ci_out" 2>&1 || ci_rc=$?
    (( ci_rc == 255 )) || break
    log "ssh dropped while waiting for cloud-init (try ${i}), retrying"; vm_wait_ssh 180
  done
  cat "$ci_out"
  # --wait prints progress dots without a newline, so the first line is ".....status: done"; strip them before matching. The
  # extended status must be a plain "done" too ("degraded done" means a module reported a recoverable error).
  local ci_txt; ci_txt=$(sed 's/^\.*//' "$ci_out")
  local js errs race=0
  js=$(vm_ssh root 'cloud-init status --format json' 2>/dev/null || true)
  if [[ "${key}" == fedora44 && -n "$js" ]] && grep -qx 'extended_status: degraded done' <<<"$ci_txt"; then
    local live stat osid
    printf '%s\n' "$ci_txt" > "$W/ci-status.txt"; printf '%s\n' "$js" > "$W/ci-status.json"
    vm_ssh root 'cat /var/log/cloud-init.log' > "$W/ci-race.log" 2>/dev/null || : > "$W/ci-race.log"
    live=$(vm_ssh root 'hostname' 2>/dev/null || true)
    stat=$(vm_ssh root 'hostnamectl --static 2>/dev/null || hostname' 2>/dev/null || true)
    osid=$(vm_ssh root '. /etc/os-release; echo "$ID"' 2>/dev/null || true)
    vm_hostname_race_allowed "$osid" "ci-${key}" "$W/ci-status.txt" "$W/ci-status.json" "$W/ci-race.log" "$live" "$stat" && race=1
  fi
  if (( race )) && (( ci_rc == 2 )); then
    pass "cloud-init status --wait exit code is 2 (degraded done, see below)"
  else expect_eq "cloud-init status --wait exit code" "$ci_rc" 0; fi
  if (( race )); then
    pass "cloud-init done (known Fedora 44 image issue: local-stage hostname before D-Bus, retried OK, hostname correct)"
    warn "Fedora 44: cloud-init reports 'degraded done' only because its local stage ran hostnamectl before D-Bus; retried in the network stage, hostname is ci-${key}"
  else
    grep -qx 'status: done' <<<"$ci_txt" && pass "cloud-init status is done" || fail "cloud-init status is not 'done'"
    grep -qx 'extended_status: done' <<<"$ci_txt" && pass "cloud-init extended status is done" || fail "cloud-init extended status is not 'done' ($(grep -m1 '^extended_status:' <<<"$ci_txt"))"
    if [[ -n "$js" ]]; then
      errs=$(python3 -I -c 'import json,sys; d=json.load(sys.stdin); r=d.get("recoverable_errors") or {}; print(len(d.get("errors") or []) + sum(len(v) for v in r.values()))' <<<"$js" 2>/dev/null || echo "?")
      expect_eq "cloud-init reports no errors" "$errs" 0
    else warn "cloud-init status --format json is not available on this version"; fi
  fi
  if vm_ssh root 'cloud-init schema --help >/dev/null 2>&1'; then
    local sc_rc=0 sc
    sc=$(vm_ssh root 'cloud-init schema --system' 2>&1) || sc_rc=$?
    echo "$sc" | head -20
    if (( sc_rc == 0 )); then pass "cloud-init schema --system is clean"; else fail "cloud-init schema --system exit ${sc_rc}"; fi
  else warn "cloud-init schema is not available on this version"; fi
  endgroup

  if [[ "$VM_ROLE" == server ]]; then
    group "2. the init: no failed step, assertions (nothing allow-listed)"
    local docker_reboot=0 init_ok=0
    # EL10: Docker could not start on the first-boot kernel, the init rebooted once and printed "done, reboot pending for docker".
    # That is not a clean run: say so, and require Docker to be up afterwards (the init's drop-in then clears its failed-log entry).
    if vm_ssh root 'grep -q "done, reboot pending for docker" /var/log/cloud-init-output.log'; then
      docker_reboot=1
      warn "first boot: Docker did not start on the first-boot kernel; the init rebooted once into the upgraded kernel (EL10 Docker workaround fired)"
      vm_ssh root 'for i in $(seq 60); do systemctl is-active --quiet docker && exit 0; sleep 2; done; exit 1' || true
    fi
    failed_log_empty "first boot"
    show_docker_log "first boot"
    vm_ssh root 'grep -h "done, all steps ok\|done, reboot pending for docker\|done with failures" /var/log/cloud-init-output.log | tail -2' | sed 's/^/  init: /' || true
    vm_ssh root 'grep -q "done, all steps ok" /var/log/cloud-init-output.log' && init_ok=1
    if (( init_ok )); then pass "server-init reported 'done, all steps ok'"
    elif (( docker_reboot )) && vm_ssh root 'systemctl is-active --quiet docker && ! grep -qs docker-reboot-pending /var/log/server-init-failed.log'; then
      pass "server-init reported 'done, reboot pending for docker'; after the reboot Docker is active and its pending entry is gone"
    else fail "server-init did not report 'done, all steps ok' in cloud-init-output.log"; fi
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
  # Runner on Rocky: the cloud-init file rebooted once at its end because Docker could not start on the image's old kernel and
  # wrote what docker said to ci-docker-reboot.log. The checks below still require Docker, the isolation rules and the cache.
  if [[ "$VM_ROLE" == runner ]] && vm_ssh root 'test -s /var/log/ci-docker-reboot.log'; then
    warn "first boot: Docker did not start on the image's kernel; the cloud-init file rebooted once into the upgraded kernel (log below)"
    vm_ssh root 'cat /var/log/ci-docker-reboot.log; uname -r' 2>&1 | cut -c1-300 | head -n 40 | ci_redact || true
  fi
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
