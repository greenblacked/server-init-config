#!/usr/bin/env bash
# Image catalogue for the real-VM tests (tools/ci/vm-e2e.sh): which official cloud image boots with which cloud-init file,
# and how to download it and verify it. The ONLY place with image URLs: when a distro moves its images, change them here.
#   tools/ci/vm-images.sh list                  one key per line
#   tools/ci/vm-images.sh info KEY              the catalogue entry as shell assignments (VM_*)
#   tools/ci/vm-images.sh fetch KEY DIR         download into DIR, verify against the distro's checksum file, print the image path
#   tools/ci/vm-images.sh parse SUMS NAME LEN   print the expected hash of NAME from a checksum file (LEN 64 = SHA-256, 128 = SHA-512)
# Trust: every download is HTTPS only and is checked against the distro's own checksum file, fetched over HTTPS from the same
# official site at the same moment. Raw digests are not pinned here because the images are rebuilt all the time. The checksum
# files are not GPG-verified: that would need a pinned distro key per site, and TLS to the official host is the root of trust
# for both files (the same trust level as the package mirrors the cloud-init files use).
# Use "latest" names where the distro has them; Fedora and openSUSE do not, so the name is resolved from the official
# directory listing (highest version that matches a fixed pattern).
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VM_KEYS=(rocky10 alma10 centos10 fedora44 debian13 ubuntu2604 opensuse16 runner-rocky10 runner-debian13)

# vm_catalogue KEY: sets
#   VM_ROLE      server | runner
#   VM_USERDATA  the cloud-init file, repo-relative, used as user-data UNCHANGED
#   VM_KIND      server-assert.sh kind: el10 | fedora | debian | opensuse (runner: rocky | debian)
#   VM_BASE      HTTPS directory of the image and its checksum file
#   VM_FILE      image file name; empty = resolve with VM_LIST_RE from the listing of VM_BASE
#   VM_LIST_RE   ERE the whole file name must match (only when VM_FILE is empty); ";" separates alternatives tried in order
#   VM_SUMS      checksum file name; "<image>" suffixes mean "image name + suffix"; empty = resolve with VM_SUMS_RE
#   VM_SUMS_RE   ERE for the checksum file name in the listing
#   VM_ALGO      sha256 | sha512
#   VM_SINGLE    1 = the checksum file belongs to this one image: a lone hash in it is accepted even if the name inside differs
#   VM_BOOT      bios | uefi
# shellcheck disable=SC2034 # the VM_* variables are read by the callers
vm_catalogue() {
  VM_ROLE=server VM_FILE="" VM_LIST_RE="" VM_SUMS="" VM_SUMS_RE="" VM_ALGO=sha256 VM_SINGLE=0 VM_BOOT=bios
  case "$1" in
    rocky10 | runner-rocky10)
      VM_BASE=https://dl.rockylinux.org/pub/rocky/10/images/x86_64/
      VM_FILE=Rocky-10-GenericCloud-Base.latest.x86_64.qcow2
      # Both Rocky 10 jobs ended with a silent console under SeaBIOS (-nodefaults removes the VGA card SeaBIOS prints to, so a
      # disk the BIOS cannot boot looks the same); UEFI is the other path this hybrid image supports.
      VM_SUMS="<image>.CHECKSUM" VM_SINGLE=1 VM_BOOT=uefi VM_KIND=el10 VM_USERDATA=server/cloud-init/server-el10.yaml ;;
    alma10)
      VM_BASE=https://repo.almalinux.org/almalinux/10/cloud/x86_64/images/
      VM_FILE=AlmaLinux-10-GenericCloud-latest.x86_64.qcow2
      VM_SUMS=CHECKSUM VM_KIND=el10 VM_USERDATA=server/cloud-init/server-el10.yaml ;;
    centos10)
      VM_BASE=https://cloud.centos.org/centos/10-stream/x86_64/images/
      VM_FILE=CentOS-Stream-GenericCloud-10-latest.x86_64.qcow2
      VM_SUMS="<image>.SHA256SUM" VM_SINGLE=1 VM_KIND=el10 VM_USERDATA=server/cloud-init/server-el10.yaml ;;
    fedora44)
      # No "latest" name: the releases/44 directory holds one build, e.g. Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2
      # with Fedora-Cloud-44-1.7-x86_64-CHECKSUM beside it.
      VM_BASE=https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/
      VM_LIST_RE='Fedora-Cloud-Base-Generic-44-[0-9.]+\.x86_64\.qcow2'
      VM_SUMS_RE='Fedora-Cloud-44-[0-9.]+-x86_64-CHECKSUM' VM_KIND=fedora VM_USERDATA=server/cloud-init/server-fedora.yaml ;;
    debian13 | runner-debian13)
      VM_BASE=https://cloud.debian.org/images/cloud/trixie/latest/
      VM_FILE=debian-13-genericcloud-amd64.qcow2
      VM_SUMS=SHA512SUMS VM_ALGO=sha512 VM_KIND=debian VM_USERDATA=server/cloud-init/server-debian.yaml ;;
    ubuntu2604)
      # The README uses server-debian.yaml for Ubuntu 26.04 too. The directory redirects to .../resolute/release/.
      VM_BASE=https://cloud-images.ubuntu.com/releases/26.04/release/
      VM_FILE=ubuntu-26.04-server-cloudimg-amd64.img
      VM_SUMS=SHA256SUMS VM_KIND=debian VM_USERDATA=server/cloud-init/server-debian.yaml ;;
    opensuse16)
      # Leap 16.0 minimal cloud VM. Resolved from the listing: the unversioned name if present, else the highest build.
      VM_BASE=https://download.opensuse.org/distribution/leap/16.0/appliances/
      # Patterns are tried in this order (";" separates them), the first one that matches the listing wins: a cloud-init
      # enabled "Cloud" image, any other x86_64 file with "Cloud" in its name, and last the plain kvm image.
      VM_LIST_RE='Leap-16\.0-Minimal-VM\.x86_64-Cloud(-Build[0-9.]+)?\.qcow2;Leap-16\.0-[^/]*x86_64[^/]*-Cloud[^/]*\.qcow2;Leap-16\.0-Minimal-VM\.x86_64-kvm[^/]*\.qcow2'
      VM_SUMS="<image>.sha256" VM_SINGLE=1 VM_BOOT=uefi VM_KIND=opensuse VM_USERDATA=server/cloud-init/server-opensuse.yaml ;;
    *) return 1 ;;
  esac
  case "$1" in
    runner-rocky10) VM_ROLE=runner VM_KIND=rocky VM_USERDATA=runner/cloud-init/rocky-x86.yaml ;;
    runner-debian13) VM_ROLE=runner VM_KIND=debian VM_USERDATA=runner/cloud-init/debian-x86.yaml ;;
  esac
  return 0
}

# vm_expected_hash SUMS_FILE NAME LEN [SINGLE]: the hash of NAME. Understands BSD lines "SHA256 (name) = hash" (Rocky, Fedora,
# Alma) and GNU lines "hash  name" / "hash *name" (Debian, Ubuntu, CentOS). With SINGLE=1 a file holding exactly one hash
# is accepted whatever name it carries.
vm_expected_hash() {
  local f=$1 name=$2 len=$3 single=${4:-0} h
  h=$(awk -v n="$name" -v len="$len" '
    { line = $0; sub(/\r$/, "", line) }
    line ~ /^SHA(256|512) \(.*\) = [0-9A-Fa-f]+$/ {
      s = line; sub(/^SHA(256|512) \(/, "", s); f = s; sub(/\) = .*$/, "", f); v = s; sub(/^.*\) = /, "", v)
      if (f == n && length(v) == len) { print tolower(v); exit }
      next
    }
    line ~ /^[0-9A-Fa-f]+[ \t]+\*?[^ \t]+$/ {
      v = line; sub(/[ \t].*$/, "", v); f = line; sub(/^[0-9A-Fa-f]+[ \t]+\*?/, "", f); sub(/^\.\//, "", f)
      if (f == n && length(v) == len) { print tolower(v); exit }
    }' "$f")
  if [[ -z "$h" && "$single" == 1 ]]; then
    h=$(grep -Eio "(^|[^0-9A-Fa-f])[0-9A-Fa-f]{${len}}([^0-9A-Fa-f]|\$)" "$f" | grep -Eio "[0-9A-Fa-f]{${len}}" | tr 'A-F' 'a-f' | sort -u)
    [[ $(wc -l <<<"$h") -eq 1 ]] || h=""
  fi
  [[ -n "$h" ]] && echo "$h"
}

# vm_hrefs LISTING_FILE: the file names linked from an HTML directory listing (any path prefix and query dropped, directories
# left out), one per line. Mirror listings link either the bare name or an absolute path.
vm_hrefs() {
  grep -Eo 'href="[^"?#]+"' "$1" | sed -e 's/^href="//' -e 's/"$//' | grep -v '/$' | sed 's#.*/##' | grep -v '^$' || true
}

# vm_pick LISTING_FILE ERE: the best file name in an HTML directory listing whose whole name matches ERE. The unversioned
# spelling wins when it is there, otherwise the highest version (sort -V).
vm_pick() {
  vm_hrefs "$1" | grep -E "^(${2})\$" | sort -uV | awk '{ a[NR] = $0 } END { for (i = NR; i >= 1; i--) if (a[i] !~ /-Build[0-9]/) { print a[i]; exit } if (NR) print a[NR] }' || true
}

# vm_pick_any LISTING_FILE "ERE;ERE...": vm_pick with each alternative in turn; the first one that finds a file decides.
vm_pick_any() {
  local re found
  while IFS= read -r re; do
    [[ -n "$re" ]] || continue
    found=$(vm_pick "$1" "$re")
    if [[ -n "$found" ]]; then echo "$found"; return 0; fi
  done <<<"${2//;/$'\n'}"
  return 1
}

CURL=(curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --retry 5 --retry-delay 5 --retry-connrefused --connect-timeout 20)

# vm_fetch KEY DIR: prints the verified image path on stdout, everything else on stderr.
vm_fetch() {
  local key=$1 dir=$2 file sums list algo_cmd want have
  vm_catalogue "$key" || die "unknown image key: $key (known: ${VM_KEYS[*]})"
  mkdir -p "$dir"
  file=$VM_FILE
  if [[ -z "$file" || -z "$VM_SUMS" ]]; then
    list=$(mktemp)
    "${CURL[@]}" -o "$list" "$VM_BASE" || die "cannot read the directory listing ${VM_BASE}"
    if [[ -z "$file" ]]; then
      file=$(vm_pick_any "$list" "$VM_LIST_RE" || true)
      if [[ -n "$file" && "$VM_KIND" == opensuse && "$file" != *Cloud* ]]; then
        echo "WARN: ${file} is not a Cloud image; without cloud-init the run ends in an ssh timeout, not a clear error" >&2
      fi
      if [[ -z "$file" ]]; then
        # Show what the directory does hold, so the next run says which name to add to the catalogue.
        echo "image files in ${VM_BASE}: $(vm_hrefs "$list" | grep -Ei '\.(qcow2|img|raw)(\.[a-z0-9]+)?$' | sort -u | tr '\n' ' ')" >&2
        echo "listing: $(wc -c < "$list") bytes, $(vm_hrefs "$list" | wc -l) links; first lines:" >&2
        head -n 15 "$list" | cut -c1-200 >&2
        die "no file matching ${VM_LIST_RE} in ${VM_BASE}"
      fi
    fi
    sums=$VM_SUMS
    if [[ -z "$sums" ]]; then
      sums=$(vm_pick "$list" "$VM_SUMS_RE")
      [[ -n "$sums" ]] || die "no checksum file matching ${VM_SUMS_RE} in ${VM_BASE}"
    fi
    rm -f "$list"
  else
    sums=$VM_SUMS
  fi
  sums=${sums//<image>/$file}
  log "image ${key}: ${VM_BASE}${file}; checksums: ${sums} (${VM_ALGO})" >&2

  "${CURL[@]}" -o "$dir/$key.sums" "${VM_BASE}${sums}" || die "cannot download ${VM_BASE}${sums}"
  want=$(vm_expected_hash "$dir/$key.sums" "$file" "$([[ $VM_ALGO == sha512 ]] && echo 128 || echo 64)" "$VM_SINGLE") \
    || die "no ${VM_ALGO} hash for ${file} in ${sums}"
  algo_cmd="${VM_ALGO}sum"
  # The download is kept next to its checksum file; a copy that already verifies is reused (a re-run, a cache hit).
  if [[ -f "$dir/$file" ]] && [[ $("$algo_cmd" "$dir/$file" | cut -d' ' -f1) == "$want" ]]; then
    log "cached ${file} verifies" >&2
  else
    "${CURL[@]}" -o "$dir/$file.part" "${VM_BASE}${file}" || die "cannot download ${VM_BASE}${file}"
    have=$("$algo_cmd" "$dir/$file.part" | cut -d' ' -f1)
    if [[ "$have" != "$want" ]]; then
      rm -f "$dir/$file.part"
      die "${VM_ALGO} mismatch for ${file}: downloaded ${have}, the distro's ${sums} says ${want}"
    fi
    mv -f "$dir/$file.part" "$dir/$file"
  fi
  log "verified ${file} ${VM_ALGO}:${want}" >&2
  echo "$dir/$file"
}

vm_images_main() {
  case "${1:-}" in
    list) printf '%s\n' "${VM_KEYS[@]}" ;;
    info)
      vm_catalogue "${2:?usage: $0 info KEY}" || die "unknown image key: ${2}"
      local v
      for v in VM_ROLE VM_USERDATA VM_KIND VM_BASE VM_FILE VM_LIST_RE VM_SUMS VM_SUMS_RE VM_ALGO VM_SINGLE VM_BOOT; do printf '%s=%q\n' "$v" "${!v}"; done ;;
    fetch) vm_fetch "${2:?usage: $0 fetch KEY DIR}" "${3:?usage: $0 fetch KEY DIR}" ;;
    parse) vm_expected_hash "${2:?usage: $0 parse SUMS NAME LEN}" "${3:?name}" "${4:?len}" "${5:-0}" ;;
    -h | --help | "") sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown command: $1" ;;
  esac
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then vm_images_main "$@"; fi
