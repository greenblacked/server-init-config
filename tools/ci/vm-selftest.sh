#!/usr/bin/env bash
# Offline checks of the pieces of the VM tests that need no VM and no KVM: the checksum parser, the directory-listing picker,
# the catalogue, the NoCloud seed (user-data byte for byte, label cidata, keys in meta-data) and the argument handling.
# vm.yml runs it before the images are downloaded. Usage: tools/ci/vm-selftest.sh   (SELFTEST_NETWORK=1 also parses a real
# checksum file from cloud-images.ubuntu.com)
set -Eeuo pipefail
# shellcheck source=vm-e2e.sh
source "$(dirname "${BASH_SOURCE[0]}")/vm-e2e.sh"
cd "$CI_ROOT"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

H256a=$(printf 'a%.0s' {1..64}); H256b=$(printf 'b%.0s' {1..64}); H512=$(printf 'c%.0s' {1..128})
group "checksum parser"
printf 'SHA256 (Other.qcow2) = %s\nSHA256 (Img-1.qcow2) = %s\n' "$H256b" "$H256a" > "$T/bsd"
expect_eq "BSD line, picks by name" "$(vm_expected_hash "$T/bsd" Img-1.qcow2 64)" "$H256a"
printf '%s *other.img\n%s *img.img\n' "$H256b" "$H256a" > "$T/gnu"
expect_eq "GNU line with *" "$(vm_expected_hash "$T/gnu" img.img 64)" "$H256a"
printf '%s  ./x.qcow2\r\n' "${H256a^^}" > "$T/gnu2"
expect_eq "GNU line, ./ prefix, CRLF, upper case" "$(vm_expected_hash "$T/gnu2" x.qcow2 64)" "$H256a"
printf '%s  debian-13-genericcloud-amd64.qcow2\n' "$H512" > "$T/s512"
expect_eq "SHA-512 line" "$(vm_expected_hash "$T/s512" debian-13-genericcloud-amd64.qcow2 128)" "$H512"
expect_eq "SHA-512 hash is not taken for SHA-256" "$(vm_expected_hash "$T/s512" debian-13-genericcloud-amd64.qcow2 64 || true)" ""
printf '%s\n' "$H256a" > "$T/lone"
expect_eq "lone hash is refused without SINGLE" "$(vm_expected_hash "$T/lone" img 64 || true)" ""
expect_eq "lone hash is accepted with SINGLE" "$(vm_expected_hash "$T/lone" img 64 1)" "$H256a"
printf 'SHA256 (Dated-20260101.qcow2) = %s\n' "$H256a" > "$T/dated"
expect_eq "per-image file with another name inside, SINGLE" "$(vm_expected_hash "$T/dated" Rocky.latest.qcow2 64 1)" "$H256a"
printf '%s a\n%s b\n' "$H256a" "$H256b" > "$T/two"
expect_eq "two hashes, no name match: refused even with SINGLE" "$(vm_expected_hash "$T/two" img 64 1 || true)" ""
expect_eq "a name that is only a prefix does not match" "$(vm_expected_hash "$T/bsd" Img-1 64 || true)" ""
endgroup

group "listing picker"
cat > "$T/list" <<'LST'
<a href="?C=N;O=D">Name</a><a href="/pub/">Parent</a>
<a href="Fedora-Cloud-Base-Generic-44-1.6.x86_64.qcow2">x</a>
<a href="Fedora-Cloud-Base-Generic-44-1.10.x86_64.qcow2">x</a>
<a href="Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2.sig">x</a>
<a href="Fedora-Cloud-44-1.10-x86_64-CHECKSUM">x</a>
<a href="Leap-16.0-Minimal-VM.x86_64-Cloud-Build1.2.qcow2">x</a>
<a href="Leap-16.0-Minimal-VM.x86_64-Cloud-Build1.10.qcow2">x</a>
<a href="Leap-16.0-Minimal-VM.x86_64-Cloud.qcow2.sha256">x</a>
LST
vm_catalogue fedora44
expect_eq "Fedora: highest version, not string order" "$(vm_pick "$T/list" "$VM_LIST_RE")" Fedora-Cloud-Base-Generic-44-1.10.x86_64.qcow2
expect_eq "Fedora: checksum file" "$(vm_pick "$T/list" "$VM_SUMS_RE")" Fedora-Cloud-44-1.10-x86_64-CHECKSUM
vm_catalogue opensuse16
expect_eq "openSUSE: highest build when no unversioned name" "$(vm_pick_any "$T/list" "$VM_LIST_RE")" Leap-16.0-Minimal-VM.x86_64-Cloud-Build1.10.qcow2
echo '<a href="Leap-16.0-Minimal-VM.x86_64-Cloud.qcow2">x</a>' >> "$T/list"
expect_eq "openSUSE: unversioned name wins" "$(vm_pick_any "$T/list" "$VM_LIST_RE")" Leap-16.0-Minimal-VM.x86_64-Cloud.qcow2
cat > "$T/list2" <<'LST'
<a href="/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.aarch64-Cloud.qcow2">x</a>
<a href="/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.x86_64-kvm-and-xen.qcow2">x</a>
<a href="/distribution/leap/16.0/appliances/Leap-16.0-Minimal-VM.x86_64-kvm-and-xen.qcow2.sha256">x</a>
<a href="/distribution/leap/16.0/appliances/Leap-16.0-Base-Cloud.x86_64-Cloud-Build2.1.qcow2">x</a>
<a href="/distribution/leap/16.0/appliances/">dir</a>
LST
expect_eq "openSUSE: absolute hrefs, a wider Cloud name beats kvm, other arch ignored" "$(vm_pick_any "$T/list2" "$VM_LIST_RE")" Leap-16.0-Base-Cloud.x86_64-Cloud-Build2.1.qcow2
sed -i '/Base-Cloud/d' "$T/list2"
expect_eq "openSUSE: kvm image is the last resort" "$(vm_pick_any "$T/list2" "$VM_LIST_RE")" Leap-16.0-Minimal-VM.x86_64-kvm-and-xen.qcow2
sed -i '/kvm/d' "$T/list2"
expect_eq "openSUSE: nothing usable, nothing picked" "$(vm_pick_any "$T/list2" "$VM_LIST_RE" || true)" ""
endgroup

group "catalogue"
declare -A KIND_OF_FILE=([server/cloud-init/server-el10.yaml]=el10 [server/cloud-init/server-fedora.yaml]=fedora [server/cloud-init/server-debian.yaml]=debian [server/cloud-init/server-opensuse.yaml]=opensuse)
for k in "${VM_KEYS[@]}"; do
  vm_catalogue "$k" || { fail "catalogue entry $k"; continue; }
  [[ -f "$VM_USERDATA" ]] && pass "$k: $VM_USERDATA exists" || fail "$k: $VM_USERDATA missing"
  [[ "$VM_BASE" == https://* ]] && pass "$k: base URL is https" || fail "$k: base URL is not https"
  [[ -n "$VM_FILE" || -n "$VM_LIST_RE" ]] && pass "$k: image name or pattern set" || fail "$k: no image name"
  [[ -n "$VM_SUMS" || -n "$VM_SUMS_RE" ]] && pass "$k: checksum file set" || fail "$k: no checksum file"
  if [[ "$VM_ROLE" == server ]]; then
    expect_eq "$k: assert kind matches the cloud-init file" "$VM_KIND" "${KIND_OF_FILE[$VM_USERDATA]}"
  fi
done
vm_catalogue ubuntu2604; expect_eq "Ubuntu 26.04 uses the Debian file (README)" "$VM_USERDATA" server/cloud-init/server-debian.yaml
grep -q 'server/cloud-init/server-debian.yaml' README.md && pass "README names server-debian.yaml for Ubuntu" || fail "README does not name server-debian.yaml"
vm_catalogue rocky10; expect_eq "Rocky 10 boots with UEFI" "$VM_BOOT" uefi
vm_catalogue alma10; expect_eq "Alma 10 boots with BIOS" "$VM_BOOT" bios
vm_catalogue debian13; expect_eq "Debian 13 boots with UEFI (it loops on GRUB under SeaBIOS)" "$VM_BOOT" uefi
vm_catalogue runner-debian13; expect_eq "runner Debian 13 boots with UEFI" "$VM_BOOT" uefi
! vm_catalogue nonsense && pass "unknown key is refused" || fail "unknown key accepted"
endgroup

group "Fedora hostname-race allowance"
printf 'status: done\nextended_status: degraded done\nerrors: []\n' > "$T/rs"
printf '{"errors": [], "recoverable_errors": {"WARNING": ["Failed to set the hostname to ci-fedora44 (ci-fedora44)"]}}' > "$T/rj"
printf 'stderr: Failed to connect to system scope bus via local transport\nWill retry in network stage\n' > "$T/rl"
race() { vm_hostname_race_allowed "${1:-fedora}" ci-fedora44 "${2:-$T/rs}" "${3:-$T/rj}" "${4:-$T/rl}" "${5:-ci-fedora44}" "${6:-ci-fedora44}"; }
race && pass "race: exact known case allowed" || fail "race: known case refused"
race debian && fail "race: other distro allowed" || pass "race: other distro refused"
printf 'status: done\nextended_status: done\n' > "$T/rs2"; race fedora "$T/rs2" && fail "race: plain done allowed" || pass "race: plain done refused (not degraded)"
printf 'status: error\nextended_status: degraded done\n' > "$T/rs3"; race fedora "$T/rs3" && fail "race: status error allowed" || pass "race: status not done refused"
printf '{"errors": ["boom"], "recoverable_errors": {"WARNING": ["Failed to set the hostname to ci-fedora44 (ci-fedora44)"]}}' > "$T/rj2"; race fedora "$T/rs" "$T/rj2" && fail "race: errors allowed" || pass "race: non-empty errors refused"
# the real shape seen on Fedora 44 (cloud-init 26.1-1.fc44, job 124847616256): the one warning four times, `errors` empty
W='"Failed to set the hostname to ci-fedora44 (ci-fedora44)"'
printf '{"boot_status_code": "enabled-by-generator", "datasource": "nocloud", "detail": "DataSourceNoCloud [seed=/dev/vdb]", "errors": [], "extended_status": "degraded done", "recoverable_errors": {"WARNING": [%s, %s, %s, %s]}, "status": "done"}' "$W" "$W" "$W" "$W" > "$T/rjr"
printf 'status: done\nextended_status: degraded done\nboot_status_code: enabled-by-generator\ndetail: DataSourceNoCloud [seed=/dev/vdb]\nerrors: []\nrecoverable_errors:\nWARNING:\n\t- Failed to set the hostname to ci-fedora44 (ci-fedora44)\n' > "$T/rsr"
printf '2026-11-01 12:26:10,483 - log_util.py[WARNING]: Failed to set the hostname to ci-fedora44 (ci-fedora44)\nStderr: Failed to connect to system scope bus via local transport: No such file or directory\nFailed setting hostname in local stage. Will retry in network stage. Error: x\n' > "$T/rlr"
race fedora "$T/rsr" "$T/rjr" "$T/rlr" && pass "race: real 26.1 output (warning listed 4 times) allowed" || fail "race: real 26.1 output refused"
printf '{"errors": [], "recoverable_errors": {"WARNING": [%s, %s, %s, "other"]}}' "$W" "$W" "$W" > "$T/rjr2"; race fedora "$T/rsr" "$T/rjr2" "$T/rlr" && fail "race: 3 known + 1 other warning allowed" || pass "race: repeated warning plus one other refused"
printf '{"errors": [], "recoverable_errors": {"WARNING": []}}' > "$T/rjr3"; race fedora "$T/rsr" "$T/rjr3" "$T/rlr" && fail "race: empty warning list allowed" || pass "race: no warning at all refused"
printf '{"errors": [], "recoverable_errors": {"WARNING": [%s], "ERROR": ["x"]}}' "$W" > "$T/rjr4"; race fedora "$T/rsr" "$T/rjr4" "$T/rlr" && fail "race: extra ERROR level allowed" || pass "race: known warning plus an ERROR level refused"
printf '{"errors": [], "recoverable_errors": {"WARNING": [%s, "other"]}}' "$W" > "$T/rj3"; race fedora "$T/rs" "$T/rj3" && fail "race: extra warning allowed" || pass "race: extra warning refused"
printf '{"errors": [], "recoverable_errors": {"WARNING": ["Failed to set the hostname to x (x)"]}}' > "$T/rj4"; race fedora "$T/rs" "$T/rj4" && fail "race: other hostname allowed" || pass "race: warning for another hostname refused"
printf '{"errors": [], "recoverable_errors": {"ERROR": ["Failed to set the hostname to ci-fedora44 (ci-fedora44)"]}}' > "$T/rj5"; race fedora "$T/rs" "$T/rj5" && fail "race: ERROR level allowed" || pass "race: wrong level refused"
printf 'Will retry in network stage\n' > "$T/rl2"; race fedora "$T/rs" "$T/rj" "$T/rl2" && fail "race: no bus evidence allowed" || pass "race: missing bus evidence refused"
printf 'Failed to connect to system scope bus\n' > "$T/rl3"; race fedora "$T/rs" "$T/rj" "$T/rl3" && fail "race: no retry evidence allowed" || pass "race: missing retry evidence refused"
race fedora "$T/rs" "$T/rj" "$T/rl" localhost ci-fedora44 && fail "race: wrong live hostname allowed" || pass "race: wrong live hostname refused"
race fedora "$T/rs" "$T/rj" "$T/rl" ci-fedora44 localhost && fail "race: wrong static hostname allowed" || pass "race: wrong static hostname refused"
endgroup

group "NoCloud seed"
if need genisoimage || need xorriso; then
  ssh-keygen -q -t ed25519 -N '' -C selftest -f "$T/id" <<<y >/dev/null 2>&1 || true
  vm_make_seed "$T/seed.iso" "$T/id.pub" server/cloud-init/server-debian.yaml debian13
  if need isoinfo; then
    isoinfo -d -i "$T/seed.iso" | grep -q 'Volume id: cidata' && pass "volume label is cidata" || fail "volume label is not cidata"
    isoinfo -R -i "$T/seed.iso" -x /user-data > "$T/ud" 2>/dev/null
    cmp -s "$T/ud" server/cloud-init/server-debian.yaml && pass "user-data is the repo file, byte for byte" || fail "user-data differs from the repo file"
    isoinfo -R -i "$T/seed.iso" -x /meta-data > "$T/md" 2>/dev/null
    grep -q '^instance-id: iid-ci-debian13-' "$T/md" && grep -q '^local-hostname: ci-debian13$' "$T/md" && grep -qF -- "$(cat "$T/id.pub")" "$T/md" && pass "meta-data: instance-id, local-hostname, public key" || fail "meta-data incomplete: $(cat "$T/md")"
    python3 -I -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); assert d["public-keys"][0].startswith("ssh-ed25519 ")' "$T/md" 2>/dev/null && pass "meta-data is valid YAML" || warn "meta-data YAML not checked (PyYAML missing?)"
    isoinfo -R -i "$T/seed.iso" -x /vendor-data 2>/dev/null | grep -q '^disable_root: false$' && pass "vendor-data lifts disable_root" || fail "vendor-data missing disable_root: false"
  else
    if in_ci; then fail "isoinfo missing: the seed content cannot be checked"; else warn "isoinfo missing, seed content not checked"; fi
  fi
else
  if in_ci; then fail "genisoimage/xorriso missing"; else warn "genisoimage/xorriso missing, seed not built"; fi
fi
endgroup

group "argument handling"
out=$(bash tools/ci/vm-e2e.sh 2>&1 || true); [[ "$out" == *"usage:"* ]] && pass "no argument: usage" || fail "no argument printed no usage"
out=$(ALLOW_LOCAL=1 bash tools/ci/vm-e2e.sh nonsense 2>&1 || true); [[ "$out" == *"unknown image key"* ]] && pass "unknown key refused" || fail "unknown key: $out"
if ! in_ci; then
  out=$(env -u GITHUB_ACTIONS -u CI bash tools/ci/vm-e2e.sh rocky10 2>&1 || true); [[ "$out" == *"ALLOW_LOCAL=1"* ]] && pass "refuses to run locally without ALLOW_LOCAL=1" || fail "no ALLOW_LOCAL refusal: $out"
fi
out=$(bash tools/ci/vm-images.sh list); [[ "$(wc -l <<<"$out")" -eq "${#VM_KEYS[@]}" ]] && pass "vm-images.sh list" || fail "vm-images.sh list"
out=$(bash tools/ci/vm-images.sh fetch nonsense "$T" 2>&1 || true); [[ "$out" == *"unknown image key"* ]] && pass "fetch of an unknown key refused" || fail "fetch unknown key: $out"
endgroup

if [[ "${SELFTEST_NETWORK:-0}" == 1 ]]; then
  group "real checksum file (network)"
  curl -fsSL --proto '=https' -o "$T/ubuntu.sums" https://cloud-images.ubuntu.com/releases/26.04/release/SHA256SUMS
  h=$(vm_expected_hash "$T/ubuntu.sums" ubuntu-26.04-server-cloudimg-amd64.img 64 || true)
  [[ "$h" =~ ^[0-9a-f]{64}$ ]] && pass "Ubuntu SHA256SUMS parsed: $h" || fail "could not parse the Ubuntu SHA256SUMS"
  endgroup
fi
finish
