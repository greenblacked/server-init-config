#!/usr/bin/env bash
# Security tools to audit, test and scan YOUR OWN servers. Use them only on systems you own or are authorized to test.
# No option = --audit --network --scan. Groups:
#   --audit    lynis, OpenSCAP (EL/Fedora, evaluation only, never --remediate), auditd with a minimal ruleset, ssh-audit, testssl.sh, debsums (Debian)
#   --network  nmap, tcpdump, tshark, iperf3, socat, ncat, whois, dig, lsof, mtr, traceroute, iftop, nethogs, bmon
#   --scan     trivy, gitleaks, hadolint, cosign, osv-scanner, trufflehog, dockle: official release binaries at pinned versions, checked against the checksums file of the same release
# Opt-in (not part of the default, they use RAM, disk IO or are noisy): --aide --clamav --rkhunter --chkrootkit --arp-scan --grype --syft --k8s
#   --kali     the `kali` helper (Kali in a Docker container; nothing offensive is installed on the host)
#   --audit-timer  weekly systemd timer: lynis, oscap, aide --check, rkhunter (whatever is installed) into /var/log/security-audit
# Every package is installed on its own: one that is missing on this release is logged and skipped. Safe to rerun.
# Supported: CentOS Stream / Rocky / AlmaLinux 10, Fedora 44, Debian 13, Ubuntu 26.04.
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

# --- pinned versions of the release binaries (override with the same-named environment variable) -----------------
# Each is downloaded from the project's GitHub release page and compared with the checksums file published in the same
# release. That catches corrupt or truncated downloads; it does not protect against a replaced release, because the
# checksums come from the same place as the binary.
: "${TRIVY_VERSION:=0.76.1}"
: "${GRYPE_VERSION:=0.121.0}"
: "${SYFT_VERSION:=1.55.0}"
: "${GITLEAKS_VERSION:=8.30.1}"
: "${HADOLINT_VERSION:=2.14.0}"
: "${DOCKLE_VERSION:=0.4.15}"
: "${COSIGN_VERSION:=3.1.4}"
: "${OSV_SCANNER_VERSION:=2.7.0}"
: "${TRUFFLEHOG_VERSION:=3.99.7}"
: "${KUBESCAPE_VERSION:=4.0.17}"
: "${KUBE_BENCH_VERSION:=0.16.0}"
# ssh-audit from PyPI into /opt/ssh-audit (only when the distro has no package); the wheel hash is checked by pip.
: "${SSH_AUDIT_VERSION:=3.9.0}"
: "${SSH_AUDIT_WHEEL_SHA256:=3dad48d4678e0de31f6332cc7674f9d7dd1805f86babf3796f41c2fd879cb812}"
# testssl.sh: distro package where there is one; otherwise a git checkout of the tag, accepted only when the commit
# is the pinned one (a commit id is a content hash of the whole tree).
: "${TESTSSL_VERSION:=3.2.4}"
: "${TESTSSL_COMMIT:=97763a411c525720a5f9bd9d2cded416b10f210a}"

SEC_STATE=/var/lib/security-tools
AUDIT_LOG_DIR=/var/log/security-audit

WANT_AUDIT=0 WANT_NETWORK=0 WANT_SCAN=0 WANT_KALI=0 WANT_TIMER=0
WANT_AIDE=0 WANT_CLAMAV=0 WANT_RKHUNTER=0 WANT_CHKROOTKIT=0 WANT_ARP=0 WANT_GRYPE=0 WANT_SYFT=0 WANT_K8S=0

usage() {
  cat <<USAGE
Usage: $0 [--audit] [--network] [--scan] [opt-in tools] [--kali] [--audit-timer]

Installs security tools for testing and auditing systems you own or are authorized to test.
No option = --audit --network --scan. Any option given = only what you name.

  --audit        lynis, OpenSCAP (EL/Fedora; audit only, never remediates: CIS remediation breaks Docker forwarding),
                 auditd with a small ruleset (sudoers, sshd_config, runner config, docker; no execve; ~200 MB log cap),
                 ssh-audit, testssl.sh, debsums (Debian family)
  --network      nmap, tcpdump, tshark (nobody is added to the wireshark group), iperf3, socat, ncat, whois, dig,
                 lsof, mtr, traceroute, iftop, nethogs, bmon
  --scan         trivy ${TRIVY_VERSION}, gitleaks ${GITLEAKS_VERSION}, hadolint ${HADOLINT_VERSION}, cosign ${COSIGN_VERSION}, osv-scanner ${OSV_SCANNER_VERSION},
                 trufflehog ${TRUFFLEHOG_VERSION}, dockle ${DOCKLE_VERSION} (release binaries, SHA256 verified; a mismatch is refused)

Opt-in, because they cost RAM, IO or produce noise:
  --aide         AIDE file integrity, scoped to /etc /usr/local /boot /usr/bin /usr/sbin; the baseline scan runs at idle IO priority
  --clamav       clamscan on demand + a daily freshclam timer. Never the clamd daemon: a loaded signature set needs
                 ~1.2 GB RAM (clamscan needs about as much while it runs), a lot on a 4 GB runner host
  --rkhunter     rkhunter; baseline refreshed after package updates (apt hook; dnf action on EL). Noisy on Docker hosts
  --chkrootkit   chkrootkit. Overlaps with rkhunter, false positives on Docker hosts are common
  --arp-scan     arp-scan (little use on Hetzner's routed network)
  --grype --syft grype ${GRYPE_VERSION}, syft ${SYFT_VERSION} (trivy already does vulnerability scans and SBOMs)
  --k8s          kubescape ${KUBESCAPE_VERSION}, kube-bench ${KUBE_BENCH_VERSION} (only useful where you run Kubernetes)

  --kali         the 'kali' helper: Kali Linux in a Docker container, built on first use (2-3 GB); needs Docker
  --audit-timer  weekly timer (idle priority): lynis, oscap, aide --check, rkhunter, reports in ${AUDIT_LOG_DIR}
  --all          --audit --network --scan --kali and every opt-in tool except --audit-timer

Supported: CentOS Stream / Rocky / AlmaLinux 10, Fedora 44, Debian 13, Ubuntu 26.04.
USAGE
}

ANY=0
while (( $# )); do
  ANY=1
  case "$1" in
    --audit) WANT_AUDIT=1 ;;
    --network) WANT_NETWORK=1 ;;
    --scan) WANT_SCAN=1 ;;
    --kali) WANT_KALI=1 ;;
    --audit-timer) WANT_TIMER=1 ;;
    --aide) WANT_AIDE=1 ;;
    --clamav) WANT_CLAMAV=1 ;;
    --rkhunter) WANT_RKHUNTER=1 ;;
    --chkrootkit) WANT_CHKROOTKIT=1 ;;
    --arp-scan) WANT_ARP=1 ;;
    --grype) WANT_GRYPE=1 ;;
    --syft) WANT_SYFT=1 ;;
    --k8s) WANT_K8S=1 ;;
    --all) WANT_AUDIT=1 WANT_NETWORK=1 WANT_SCAN=1 WANT_KALI=1 WANT_AIDE=1 WANT_CLAMAV=1 WANT_RKHUNTER=1 WANT_CHKROOTKIT=1 WANT_ARP=1 WANT_GRYPE=1 WANT_SYFT=1 WANT_K8S=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done
if (( ANY == 0 )); then
  WANT_AUDIT=1 WANT_NETWORK=1 WANT_SCAN=1
fi
require_root

# --- OS ----------------------------------------------------------------------------------------------------------
[[ -r /etc/os-release ]] || die "/etc/os-release missing, cannot detect the OS"
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}:${VERSION_ID%%.*}" in
  centos:10|rocky:10|almalinux:10|rhel:10) FAMILY=el ;;
  fedora:44)                                FAMILY=fedora ;;
  debian:13|ubuntu:26)                      FAMILY=debian ;;
  *) die "unsupported OS ${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-}}: this script supports CentOS Stream/Rocky/AlmaLinux 10, Fedora 44, Debian 13, Ubuntu 26.04" ;;
esac
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *)             ARCH="" ;;
esac

INSTALLED=() PRESENT=() MISSING=() SKIPPED=()
CHECKSUM_FAIL=0
DL_TRIED=0   # downloads attempted in this run: release binaries, the testssl git clone, the ssh-audit pip install (tools already present are not counted)
DL_FAILED=0  # of those, how many were not installed (a scan run with no usable curl or architecture counts as one failure)

have_systemd() { [[ -d /run/systemd/system ]]; }

if [[ $FAMILY == debian ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q >/dev/null || log "WARN: apt-get update failed, package lists may be stale"
  pm_installed() { [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == "install ok installed" ]]; }
  pm_install() { apt-get install -y -q --no-install-recommends "$1" >/dev/null 2>&1; }
else
  pm_installed() { rpm -q --quiet "$1"; }
  pm_install() { dnf -y -q install "$1" >/dev/null 2>&1; }
fi

# pkg_ensure NAME: 0 when installed (already or now), 1 when not available. Records the result.
pkg_ensure() {
  if pm_installed "$1"; then PRESENT+=("$1"); return 0; fi
  if pm_install "$1"; then INSTALLED+=("$1"); return 0; fi
  return 1
}

# want SPEC...: SPEC is a package or alternatives "a|b" (the first one that installs wins). Unavailable ones are logged at the end.
want() {
  local spec alt ok
  for spec in "$@"; do
    ok=0
    for alt in ${spec//|/ }; do
      if pkg_ensure "$alt"; then ok=1; break; fi
    done
    if (( ok == 0 )); then MISSING+=("${spec//|/ or }"); fi
  done
}

if [[ $FAMILY == el ]] && (( WANT_AUDIT || WANT_NETWORK || WANT_AIDE || WANT_CLAMAV || WANT_RKHUNTER || WANT_CHKROOTKIT || WANT_ARP )); then
  dnf -y -q install epel-release >/dev/null 2>&1 || log "WARN: epel-release not available, EPEL tools will be missing"
  # some EPEL packages need CRB; enabling it is the documented companion of EPEL
  if command -v crb >/dev/null 2>&1; then
    crb enable >/dev/null 2>&1 || log "WARN: could not enable CRB"
  else
    dnf -y -q config-manager --set-enabled crb >/dev/null 2>&1 || log "WARN: could not enable CRB (dnf config-manager)"
  fi
fi

# --- audit -------------------------------------------------------------------------------------------------------
AIDE_DIR=/var/lib/security-tools/aide
AIDE_CONF=/etc/security-tools/aide.conf

# Own AIDE config, scoped to the places that matter. The distro default (whole filesystem, daily run) is not used.
setup_aide() {
  command -v aide >/dev/null 2>&1 || return 0
  install -d -m 0750 /etc/security-tools "$AIDE_DIR"
  cat > "$AIDE_CONF" <<EOF
# Managed by common/security-tools.sh (scoped baseline: no containers, no CI caches, no home directories)
database_in=file:${AIDE_DIR}/aide.db.gz
database_out=file:${AIDE_DIR}/aide.db.new.gz
gzip_dbout=yes
report_url=stdout
NORMAL = p+i+n+u+g+s+m+c+sha256
/etc NORMAL
/etc/gitlab-runner NORMAL
/usr/local NORMAL
/boot NORMAL
/usr/bin NORMAL
/usr/sbin NORMAL
!/etc/mtab
!/etc/resolv.conf
!/etc/adjtime
!/etc/security-tools
!/usr/local/share/man
!/var/lib/docker
!/home/gitlab-runner
!/srv/ci-cache
!/opt/[^/]+/data
EOF
  chmod 600 "$AIDE_CONF"
  # Debian's own daily AIDE check would run the default whole-filesystem config
  if have_systemd; then
    systemctl disable --now dailyaidecheck.timer >/dev/null 2>&1 || true
  fi
  if [[ -s "${AIDE_DIR}/aide.db.gz" ]]; then
    log "aide: baseline already present (${AIDE_DIR}/aide.db.gz)"
    return 0
  fi
  log "aide: creating the baseline (idle IO priority, a few minutes)"
  nice -n 19 ionice -c3 aide --config "$AIDE_CONF" --init >/dev/null 2>&1 || true
  if [[ -s "${AIDE_DIR}/aide.db.new.gz" ]]; then
    mv -f "${AIDE_DIR}/aide.db.new.gz" "${AIDE_DIR}/aide.db.gz"
    chmod 600 "${AIDE_DIR}/aide.db.gz"
    log "aide: baseline ready; check with: aide --config ${AIDE_CONF} --check. After planned changes run --update and replace the database"
  else
    log "WARN: aide --init produced no database; run it by hand: aide --config ${AIDE_CONF} --init"
  fi
}

# Minimal ruleset: configuration that decides who can get in. No execve logging (volume), no -e 2 (stays reloadable).
setup_auditd() {
  command -v auditctl >/dev/null 2>&1 || return 0
  local f=/etc/audit/rules.d/60-security-tools.rules rules conf=/etc/audit/auditd.conf
  rules='# Managed by common/security-tools.sh. Not immutable (no -e 2). Paths that did not exist at install time are left out.
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd'
  # rerun this script after adding Docker or the runner to pick their paths up
  if [[ -d /etc/gitlab-runner ]]; then rules+=$'\n''-w /etc/gitlab-runner/ -p wa -k gitlab-runner'; fi
  if [[ -S /run/docker.sock ]]; then rules+=$'\n''-w /run/docker.sock -p rwa -k docker-sock'; fi
  install -d /etc/audit/rules.d
  if [[ "$(cat "$f" 2>/dev/null || true)" != "$rules" ]]; then
    printf '%s\n' "$rules" > "$f"
    chmod 640 "$f"
    log "auditd: wrote ${f}"
  fi
  # about 200 MB at most: 4 logs of 50 MB, rotated
  if [[ -f "$conf" ]]; then
    sed -i -E 's/^max_log_file[[:space:]]*=.*/max_log_file = 50/; s/^num_logs[[:space:]]*=.*/num_logs = 4/; s/^max_log_file_action[[:space:]]*=.*/max_log_file_action = ROTATE/' "$conf"
  fi
  if have_systemd; then
    systemctl enable --now auditd >/dev/null 2>&1 || log "WARN: could not enable auditd"
    augenrules --load >/dev/null 2>&1 || log "WARN: could not load the audit rules now (they apply at the next start of auditd)"
  else
    log "auditd: no systemd here, rules are written and load when auditd starts"
  fi
}

# clamscan on demand; signatures refreshed by a daily timer. The clamd daemon and the packaged freshclam daemon stay off.
setup_clamav() {
  command -v clamscan >/dev/null 2>&1 || return 0
  # EL/Fedora ship freshclam.conf with 'Example', which makes freshclam refuse to run
  if [[ -f /etc/freshclam.conf ]] && grep -q '^Example' /etc/freshclam.conf; then
    sed -i -E 's/^Example/#Example/' /etc/freshclam.conf
  fi
  command -v freshclam >/dev/null 2>&1 || return 0
  if have_systemd; then
    systemctl disable --now clamav-freshclam.service clamav-daemon.service clamd@scan.service >/dev/null 2>&1 || true
  fi
  if ! compgen -G '/var/lib/clamav/*.c[lv]d' >/dev/null; then
    log "clamav: fetching signatures (freshclam)"
    timeout 300 freshclam --quiet >/dev/null 2>&1 || log "WARN: freshclam failed, run it by hand before 'clamscan'"
  fi
  local u
  for u in security-freshclam.service security-freshclam.timer; do
    install -m 0644 "$REPO_ROOT/common/systemd/$u" "/etc/systemd/system/$u"
    restorecon_if "/etc/systemd/system/$u"
  done
  if have_systemd; then
    systemctl daemon-reload
    systemctl enable --now security-freshclam.timer >/dev/null 2>&1 || log "WARN: could not enable security-freshclam.timer"
  fi
}

# rkhunter compares file hashes with a baseline; without a refresh after package updates every update is a warning.
setup_rkhunter() {
  command -v rkhunter >/dev/null 2>&1 || return 0
  if [[ ! -s /var/lib/rkhunter/db/rkhunter.dat ]]; then
    rkhunter --propupd >/dev/null 2>&1 || log "WARN: rkhunter --propupd failed"
  fi
  if [[ $FAMILY == debian ]]; then
    if [[ -f /etc/default/rkhunter ]]; then
      sed -i -E 's/^#?APT_AUTOGEN=.*/APT_AUTOGEN="true"/; s/^#?CRON_DAILY_RUN=.*/CRON_DAILY_RUN="false"/' /etc/default/rkhunter
    fi
  elif [[ $FAMILY == el ]]; then
    pkg_ensure python3-dnf-plugin-post-transaction-actions || true
    if [[ -d /etc/dnf/plugins/post-transaction-actions.d ]]; then
      echo '*:any:/usr/bin/rkhunter --propupd' > /etc/dnf/plugins/post-transaction-actions.d/rkhunter.action
    else
      log "WARN: dnf post-transaction-actions plugin missing: run 'rkhunter --propupd' after package updates"
    fi
  else
    log "rkhunter: run 'rkhunter --propupd' after package updates (no dnf hook is installed on Fedora)"
  fi
}

setup_ssh_audit() {
  if command -v ssh-audit >/dev/null 2>&1 && [[ ! -x /opt/ssh-audit/venv/bin/ssh-audit ]]; then
    PRESENT+=(ssh-audit); return 0
  fi
  if [[ ! -x /opt/ssh-audit/venv/bin/ssh-audit ]] && pkg_ensure ssh-audit; then return 0; fi
  if [[ -f "${SEC_STATE}/ssh-audit.version" && "$(cat "${SEC_STATE}/ssh-audit.version")" == "$SSH_AUDIT_VERSION" ]]; then
    PRESENT+=("ssh-audit ${SSH_AUDIT_VERSION}"); return 0
  fi
  command -v python3 >/dev/null 2>&1 || pkg_ensure python3 || { MISSING+=("ssh-audit (no package, no python3)"); return 0; }
  [[ $FAMILY == debian ]] && { pkg_ensure python3-venv || true; }
  local req
  DL_TRIED=$((DL_TRIED + 1))
  req=$(mktemp)
  printf 'ssh-audit==%s --hash=sha256:%s\n' "$SSH_AUDIT_VERSION" "$SSH_AUDIT_WHEEL_SHA256" > "$req"
  if rm -rf /opt/ssh-audit/venv && install -d /opt/ssh-audit && python3 -m venv /opt/ssh-audit/venv >/dev/null 2>&1 \
     && /opt/ssh-audit/venv/bin/pip install -q --no-cache-dir --require-hashes --only-binary :all: --no-deps -r "$req" >/dev/null 2>&1; then
    printf '#!/bin/sh\nexec /opt/ssh-audit/venv/bin/ssh-audit "$@"\n' > /usr/local/bin/ssh-audit
    chmod 755 /usr/local/bin/ssh-audit
    restorecon_if /usr/local/bin/ssh-audit
    install -d "$SEC_STATE"
    echo "$SSH_AUDIT_VERSION" > "${SEC_STATE}/ssh-audit.version"
    INSTALLED+=("ssh-audit ${SSH_AUDIT_VERSION} (venv)")
  else
    DL_FAILED=$((DL_FAILED + 1))
    MISSING+=("ssh-audit (pip install failed)")
  fi
  rm -f "$req"
}

setup_testssl() {
  if command -v testssl >/dev/null 2>&1 \
     || { [[ -x /opt/testssl/testssl.sh ]] && [[ "$(cat "${SEC_STATE}/testssl.version" 2>/dev/null || true)" == "$TESTSSL_VERSION" ]]; }; then
    PRESENT+=(testssl); return 0
  fi
  if pkg_ensure testssl.sh || pkg_ensure testssl; then
    if ! command -v testssl >/dev/null 2>&1 && command -v testssl.sh >/dev/null 2>&1; then
      ln -sfn "$(command -v testssl.sh)" /usr/local/bin/testssl
    fi
    return 0
  fi
  command -v git >/dev/null 2>&1 || pkg_ensure git || { SKIPPED+=("testssl.sh (no package, no git)"); return 0; }
  local tmp
  DL_TRIED=$((DL_TRIED + 1))
  tmp=$(mktemp -d)
  if ! git clone -q --depth 1 --branch "v${TESTSSL_VERSION}" https://github.com/testssl/testssl.sh.git "$tmp/t" 2>/dev/null; then
    DL_FAILED=$((DL_FAILED + 1))
    SKIPPED+=("testssl.sh ${TESTSSL_VERSION} (git clone failed)")
  elif [[ "$(git -C "$tmp/t" rev-parse HEAD)" != "$TESTSSL_COMMIT" ]]; then
    log "ERROR: testssl.sh v${TESTSSL_VERSION} is not commit ${TESTSSL_COMMIT}, refusing to install"
    CHECKSUM_FAIL=1
  else
    rm -rf /opt/testssl
    install -d /opt/testssl
    rm -rf "$tmp/t/.git"
    cp -a "$tmp/t/." /opt/testssl/
    printf '#!/bin/sh\nexec /opt/testssl/testssl.sh "$@"\n' > /usr/local/bin/testssl
    chmod 755 /usr/local/bin/testssl
    restorecon_if /usr/local/bin/testssl
    install -d "$SEC_STATE"
    echo "$TESTSSL_VERSION" > "${SEC_STATE}/testssl.version"
    INSTALLED+=("testssl ${TESTSSL_VERSION}")
  fi
  rm -rf "$tmp"
}

fetch() { curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 900 -o "$2" "$1"; }

install_audit() {
  log "=== audit tools ==="
  local pk=(lynis)
  if [[ $FAMILY == debian ]]; then
    pk+=(auditd debsums)
  else
    pk+=(audit openscap-scanner scap-security-guide)
  fi
  want "${pk[@]}"
  setup_auditd
  setup_ssh_audit
  setup_testssl
  local ds
  ds=$(compgen -G '/usr/share/xml/scap/ssg/content/ssg-*-ds.xml' | head -1 || true)
  if [[ -n "$ds" ]]; then log "openscap: datastream ${ds} (profiles: oscap info ${ds}); evaluation only, never --remediate"; fi
}

install_optional() {
  log "=== opt-in tools ==="
  if (( WANT_AIDE )); then want aide; setup_aide; fi
  if (( WANT_CLAMAV )); then
    if [[ $FAMILY == debian ]]; then want clamav clamav-freshclam; else want clamav "clamav-freshclam|clamav-update"; fi
    setup_clamav
  fi
  if (( WANT_RKHUNTER )); then want rkhunter; setup_rkhunter; fi
  if (( WANT_CHKROOTKIT )); then want chkrootkit; fi
  if (( WANT_ARP )); then want arp-scan; fi
}

# --- network -----------------------------------------------------------------------------------------------------
install_network() {
  log "=== network tools ==="
  if [[ $FAMILY == debian ]]; then
    # tshark asks whether non-root users may capture; answer no without a prompt
    if command -v debconf-set-selections >/dev/null 2>&1; then
      echo 'wireshark-common wireshark-common/install-setuid boolean false' | debconf-set-selections || true
    fi
    want nmap tcpdump tshark iperf3 socat "ncat|netcat-openbsd" whois dnsutils lsof "mtr|mtr-tiny" traceroute iftop nethogs "bmon|nload"
  else
    want nmap tcpdump wireshark-cli iperf3 socat nmap-ncat whois bind-utils lsof mtr traceroute iftop nethogs "bmon|nload"
  fi
}

# --- release binaries --------------------------------------------------------------------------------------------
# release_tool NAME VERSION REPO ASSET SUMS_FILES MODE [BIN]
#   ASSET: file name of the release asset for this arch (empty: no build for this arch)
#   SUMS_FILES: candidate names of the checksums file in the same release
#   MODE: tar (binary inside a tarball), bin (the asset is the binary), tarcfg (tarball with config dir, kept in /opt/NAME)
# Returns 0 on success or skip, 2 on checksum mismatch; the asset is never installed unless its SHA256 matches.
release_tool() {
  local name="$1" ver="$2" repo="$3" asset="$4" sums_list="$5" mode="$6" bin="${7:-$1}"
  local marker="${SEC_STATE}/${name}.version" tmp rc=0
  if [[ -z "$asset" ]]; then
    SKIPPED+=("${name} (no ${ARCH:-$(uname -m)} build)")
    return 0
  fi
  if [[ "$(cat "$marker" 2>/dev/null || true)" == "$ver" && -x "/usr/local/bin/${bin}" ]]; then
    PRESENT+=("${name} ${ver}")
    return 0
  fi
  DL_TRIED=$((DL_TRIED + 1))
  tmp=$(mktemp -d)
  release_fetch_install "$tmp" "$name" "$ver" "$repo" "$asset" "$sums_list" "$mode" "$bin" || rc=$?
  rm -rf "$tmp"
  case "$rc" in
    0) INSTALLED+=("${name} ${ver}"); install -d "$SEC_STATE"; echo "$ver" > "$marker" ;;
    2) CHECKSUM_FAIL=1; DL_FAILED=$((DL_FAILED + 1)); SKIPPED+=("${name} ${ver} (CHECKSUM MISMATCH, not installed)") ;;
    *) DL_FAILED=$((DL_FAILED + 1)); SKIPPED+=("${name} ${ver} (not downloaded)") ;;
  esac
  return 0
}

release_fetch_install() {
  local tmp="$1" name="$2" ver="$3" repo="$4" asset="$5" sums_list="$6" mode="$7" bin="$8"
  local base="https://github.com/${repo}/releases/download/v${ver}" s got="" want_sum have_sum src
  if ! fetch "${base}/${asset}" "${tmp}/${asset}"; then
    log "WARN: ${name} ${ver}: cannot download ${base}/${asset}"
    return 1
  fi
  for s in $sums_list; do
    if fetch "${base}/${s}" "${tmp}/sums" 2>/dev/null; then got=1; break; fi
  done
  if [[ -z "$got" ]]; then
    log "WARN: ${name} ${ver}: no checksums file (${sums_list}) in the release, refusing to install unverified"
    return 1
  fi
  want_sum=$(awk -v f="$asset" '{ n = $2; sub(/^\*/, "", n); if (n == f) print $1 }' "${tmp}/sums")
  if [[ -z "$want_sum" && "$(grep -c . "${tmp}/sums")" -eq 1 ]]; then
    want_sum=$(awk '{ print $1 }' "${tmp}/sums")   # single-asset .sha256 file
  fi
  if [[ ! "$want_sum" =~ ^[0-9a-fA-F]{64}$ ]]; then
    log "WARN: ${name} ${ver}: ${asset} has no usable entry in the checksums file, refusing to install"
    return 1
  fi
  have_sum=$(sha256sum "${tmp}/${asset}" | awk '{ print $1 }')
  if [[ "${have_sum,,}" != "${want_sum,,}" ]]; then
    log "ERROR: ${name} ${ver}: SHA256 MISMATCH for ${asset} (published ${want_sum}, got ${have_sum}); refusing to install"
    return 2
  fi
  case "$mode" in
    bin)
      install -m 0755 "${tmp}/${asset}" "/usr/local/bin/${bin}"
      ;;
    tar)
      install -d "${tmp}/x"
      tar -xzf "${tmp}/${asset}" -C "${tmp}/x"
      src=$(find "${tmp}/x" -type f -name "$bin" | head -1)
      [[ -n "$src" ]] || { log "WARN: ${name}: ${bin} not found in ${asset}"; return 1; }
      install -m 0755 "$src" "/usr/local/bin/${bin}"
      ;;
    tarcfg)
      install -d "${tmp}/x"
      tar -xzf "${tmp}/${asset}" -C "${tmp}/x"
      [[ -f "${tmp}/x/${bin}" ]] || { log "WARN: ${name}: ${bin} not found in ${asset}"; return 1; }
      rm -rf "/opt/${name}"
      install -d "/opt/${name}"
      cp -a "${tmp}/x/." "/opt/${name}/"
      chmod 755 "/opt/${name}/${bin}"
      printf '#!/bin/sh\nexec /opt/%s/%s --config-dir /opt/%s/cfg --config /opt/%s/cfg/config.yaml "$@"\n' \
        "$name" "$bin" "$name" "$name" > "/usr/local/bin/${bin}"
      chmod 755 "/usr/local/bin/${bin}"
      ;;
  esac
  restorecon_if "/usr/local/bin/${bin}"
  return 0
}

install_scan() {
  log "=== scanners (release binaries, SHA256 verified) ==="
  if [[ -z "$ARCH" ]]; then
    DL_TRIED=$((DL_TRIED + 1)); DL_FAILED=$((DL_FAILED + 1))
    SKIPPED+=("scan tools (unsupported architecture $(uname -m))")
    return 0
  fi
  command -v curl >/dev/null 2>&1 || pkg_ensure curl || { DL_TRIED=$((DL_TRIED + 1)); DL_FAILED=$((DL_FAILED + 1)); SKIPPED+=("scan tools (curl missing)"); return 0; }
  local a="$ARCH" big small x
  if [[ $ARCH == amd64 ]]; then big=64bit; small=x86_64; x=x64; else big=ARM64; small=arm64; x=arm64; fi
  if (( WANT_SCAN )); then
    release_tool trivy "$TRIVY_VERSION" aquasecurity/trivy "trivy_${TRIVY_VERSION}_Linux-${big}.tar.gz" \
      "trivy_${TRIVY_VERSION}_checksums.txt" tar
    release_tool gitleaks "$GITLEAKS_VERSION" gitleaks/gitleaks "gitleaks_${GITLEAKS_VERSION}_linux_${x}.tar.gz" \
      "gitleaks_${GITLEAKS_VERSION}_checksums.txt" tar
    release_tool hadolint "$HADOLINT_VERSION" hadolint/hadolint "hadolint-linux-${small}" \
      "hadolint-linux-${small}.sha256" bin
    release_tool cosign "$COSIGN_VERSION" sigstore/cosign "cosign-linux-${a}" \
      "cosign_checksums.txt" bin cosign
    release_tool osv-scanner "$OSV_SCANNER_VERSION" google/osv-scanner "osv-scanner_linux_${a}" \
      "osv-scanner_SHA256SUMS" bin
    release_tool trufflehog "$TRUFFLEHOG_VERSION" trufflesecurity/trufflehog "trufflehog_${TRUFFLEHOG_VERSION}_linux_${a}.tar.gz" \
      "trufflehog_${TRUFFLEHOG_VERSION}_checksums.txt" tar
    release_tool dockle "$DOCKLE_VERSION" goodwithtech/dockle "dockle_${DOCKLE_VERSION}_Linux-${big}.tar.gz" \
      "dockle_${DOCKLE_VERSION}_checksums.txt" tar
  fi
  if (( WANT_GRYPE )); then
    release_tool grype "$GRYPE_VERSION" anchore/grype "grype_${GRYPE_VERSION}_linux_${a}.tar.gz" \
      "grype_${GRYPE_VERSION}_checksums.txt" tar
  fi
  if (( WANT_SYFT )); then
    release_tool syft "$SYFT_VERSION" anchore/syft "syft_${SYFT_VERSION}_linux_${a}.tar.gz" \
      "syft_${SYFT_VERSION}_checksums.txt" tar
  fi
  if (( WANT_K8S )); then
    release_tool kubescape "$KUBESCAPE_VERSION" kubescape/kubescape "kubescape_${KUBESCAPE_VERSION}_linux_${a}.tar.gz" \
      "checksums.sha256 kubescape_${KUBESCAPE_VERSION}_checksums.txt checksums.txt" tar
    release_tool kube-bench "$KUBE_BENCH_VERSION" aquasecurity/kube-bench "kube-bench_${KUBE_BENCH_VERSION}_linux_${a}.tar.gz" \
      "kube-bench_${KUBE_BENCH_VERSION}_checksums.txt checksums.txt" tarcfg
  fi
}

# --- kali helper -------------------------------------------------------------------------------------------------
install_kali() {
  log "=== kali helper (container only) ==="
  install -m 0755 "$REPO_ROOT/common/kali" /usr/local/bin/kali
  install -d -m 0755 /usr/local/share/kali-tools
  install -m 0644 "$REPO_ROOT/common/security/kali/Dockerfile" /usr/local/share/kali-tools/Dockerfile
  restorecon_if /usr/local/bin/kali /usr/local/share/kali-tools/Dockerfile
  INSTALLED+=("kali helper")
  command -v docker >/dev/null 2>&1 || log "WARN: docker is not installed; 'kali' needs it (this script does not install Docker)"
}

# --- audit timer -------------------------------------------------------------------------------------------------
install_timer() {
  log "=== weekly audit timer ==="
  install -d -m 0750 "$AUDIT_LOG_DIR"
  install -m 0755 "$REPO_ROOT/common/security-audit-run.sh" /usr/local/sbin/security-audit-run
  local u
  for u in security-audit.service security-audit.timer; do
    install -m 0644 "$REPO_ROOT/common/systemd/$u" "/etc/systemd/system/$u"
    restorecon_if "/etc/systemd/system/$u"
  done
  restorecon_if /usr/local/sbin/security-audit-run
  if have_systemd; then
    systemctl daemon-reload
    systemctl enable --now security-audit.timer >/dev/null
    systemctl list-timers security-audit.timer --no-pager | head -3
  else
    log "WARN: no systemd here, timer files installed but not enabled"
  fi
}

(( WANT_AUDIT ))   && install_audit
(( WANT_AIDE || WANT_CLAMAV || WANT_RKHUNTER || WANT_CHKROOTKIT || WANT_ARP )) && install_optional
(( WANT_NETWORK )) && install_network
(( WANT_SCAN || WANT_GRYPE || WANT_SYFT || WANT_K8S )) && install_scan
(( WANT_KALI ))    && install_kali
(( WANT_TIMER ))   && install_timer

log "installed now (${#INSTALLED[@]}): ${INSTALLED[*]:-}"
log "already present (${#PRESENT[@]}): ${PRESENT[*]:-}"
if (( ${#MISSING[@]} )); then log "WARN: not available on this release (${#MISSING[@]}): ${MISSING[*]}"; fi
if (( ${#SKIPPED[@]} )); then log "WARN: skipped (${#SKIPPED[@]}): ${SKIPPED[*]}"; fi
for c in lynis rkhunter chkrootkit aide auditctl clamscan oscap ssh-audit testssl nmap tcpdump tshark iperf3 socat ncat \
         trivy grype syft gitleaks hadolint dockle cosign osv-scanner trufflehog kubescape kube-bench kali; do
  if command -v "$c" >/dev/null 2>&1; then printf '  %-12s ok\n' "$c"; fi
done
log "Use these tools only on systems you own or are authorized to test."
if (( CHECKSUM_FAIL )); then
  die "at least one download failed its SHA256 check and was not installed (see ERROR lines above)"
fi
if (( DL_TRIED > 0 && DL_FAILED == DL_TRIED )); then
  die "every download failed (${DL_FAILED} of ${DL_TRIED}), nothing was installed (see WARN lines above)"
fi
if (( DL_FAILED > 0 )); then
  log "WARN: ${DL_FAILED} of ${DL_TRIED} downloads failed, the others were installed"
fi
log "OK"
