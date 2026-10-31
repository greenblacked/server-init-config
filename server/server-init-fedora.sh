#!/usr/bin/env bash
# Base setup for a general (non-runner) Fedora 44 server, x86_64 or ARM64:
# SSH keys only, admin user with sudo, firewalld, fail2ban for SSH, automatic security updates,
# Docker Engine + Compose, swap + sysctl, journald limit, chrony, admin tools, weekly cleanup.
# Root keeps login by SSH key on port 22, so nothing here can lock you out.
#
# Self-contained and idempotent: it writes its own config files, so it runs the same from a paste
# (server/README.md) or from a copy of the repo. Rerun as root any time: /usr/local/sbin/server-init.sh
# Settings live in /etc/server-init.conf (created on first run from the environment or defaults).
# Every step after SSH hardening is non-fatal: a failed step is logged and the next one still runs.
set -Eeuo pipefail

FAILED_LOG=/var/log/server-init-failed.log
CONF_FILE=/etc/server-init.conf
(( EUID == 0 )) || { echo "run as root" >&2; exit 1; }
# shellcheck source=/dev/null
. /etc/os-release
case "${ID:-}:${VERSION_ID%%.*}" in
  fedora:44) ;;
  # return when sourced into an interactive shell by mistake, so the shell is not closed
  *) echo "this script is for Fedora 44, found ${PRETTY_NAME:-unknown}" >&2; return 1 2>/dev/null || exit 1 ;;
esac

# First run: save the settings given in the environment (or defaults) so reruns use the same values.
if [[ ! -f "$CONF_FILE" ]]; then
  install -m 0644 /dev/null "$CONF_FILE"
  cat > "$CONF_FILE" <<CONF
# Read by /usr/local/sbin/server-init.sh. Edit, then rerun the script as root.
ADMIN_USER=${ADMIN_USER:-ops}
# Extra open ports, space separated, e.g. "80/tcp 443/tcp". SSH (22/tcp) is always open.
EXTRA_PORTS="${EXTRA_PORTS:-}"
# Set to 0 to skip a component.
INSTALL_DOCKER=${INSTALL_DOCKER:-1}
INSTALL_SWAP=${INSTALL_SWAP:-1}
TIMEZONE=${TIMEZONE:-Europe/Kyiv}
# Weekly cleanup (server-cleanup). INSTALL_CLEANUP=0 turns it off; CLEAN_SCHEDULE is a systemd OnCalendar value.
INSTALL_CLEANUP=${INSTALL_CLEANUP:-1}
CLEAN_SCHEDULE=${CLEAN_SCHEDULE:-weekly}
CLEAN_JOURNAL_TIME=${CLEAN_JOURNAL_TIME:-1month}
CLEAN_JOURNAL_SIZE=${CLEAN_JOURNAL_SIZE:-500M}
CLEAN_AUTOREMOVE=${CLEAN_AUTOREMOVE:-0}
CLEAN_DOCKER_UNUSED_IMAGES=${CLEAN_DOCKER_UNUSED_IMAGES:-0}
CONF
fi
# shellcheck source=/dev/null
. "$CONF_FILE"
ADMIN_USER="${ADMIN_USER:-ops}"
EXTRA_PORTS="${EXTRA_PORTS:-}"
INSTALL_DOCKER="${INSTALL_DOCKER:-1}"
INSTALL_SWAP="${INSTALL_SWAP:-1}"
TIMEZONE="${TIMEZONE:-Europe/Kyiv}"
INSTALL_CLEANUP="${INSTALL_CLEANUP:-1}"
CLEAN_SCHEDULE="${CLEAN_SCHEDULE:-weekly}"
FAILED_STEPS=()

log()  { echo "[$(date +%H:%M:%S)] $*"; }
fail() { log "WARN: $*"; echo "$(date -Is) $*" >> "$FAILED_LOG"; }
step() {
  local name="$1"; shift
  log "step: ${name}"
  if "$@"; then log "ok: ${name}"; else fail "step failed: ${name}"; FAILED_STEPS+=("$name"); fi
}

packages() {
  dnf -y -q install diffutils tzdata firewalld fail2ban-server fail2ban-firewalld chrony curl ca-certificates || return 1
  local p
  for p in git jq tmux htop btop ncdu iotop mtr bind-utils tcpdump vim-enhanced nano rsync wget unzip tar bash-completion mc fzf fd-find ripgrep; do
    rpm -q --whatprovides "$p" >/dev/null 2>&1 || dnf -y -q install "$p" || fail "optional package not installed: $p"
  done
}

# Write a file only when its content changes; prints nothing.
put() {
  local path="$1" mode="$2" tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; return 0; fi
  install -D -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
}

write_configs() {
  put /etc/ssh/sshd_config.d/00-hardening.conf 0600 <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
X11Forwarding no
MaxAuthTries 4
LoginGraceTime 30
EOF
  put /etc/systemd/journald.conf.d/50-size.conf 0644 <<'EOF'
[Journal]
SystemMaxUse=500M
MaxRetentionSec=1month
EOF
  put /etc/sysctl.d/90-server.conf 0644 <<'EOF'
vm.swappiness = 10
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.rp_filter = 2
-kernel.kptr_restrict = 2
-kernel.dmesg_restrict = 1
-kernel.yama.ptrace_scope = 1
-fs.protected_fifos = 2
-fs.protected_regular = 2
net.ipv4.conf.all.log_martians = 1
EOF
  # No core dumps: they can hold keys and tokens.
  put /etc/security/limits.d/50-nocore.conf 0644 <<'EOF'
* hard core 0
EOF
  put /etc/systemd/coredump.conf.d/50-off.conf 0644 <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF
  # The jail must watch the port sshd really listens on (bootstrap --port), not only the default 22.
  sshd_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -un | paste -sd, -) || true
  put /etc/fail2ban/jail.d/50-sshd.local 0644 <<EOF
[sshd]
enabled  = true
port     = ${sshd_ports:-ssh}
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
  # Same text as common/shell-history.sh (keep identical; tools/test-cloud-init.py checks it).
  put /etc/profile.d/90-server-shell.sh 0644 <<'EOF'
# shellcheck shell=bash
# Shell history and fzf key bindings for interactive bash (Ctrl+R history search, Ctrl+T file search).
# Installed as /etc/profile.d/90-shell-history.sh (runner hosts) or 90-server-shell.sh (plain servers).
# The same text is embedded in the server/server-init-*.sh scripts (they must stay self-contained):
# keep all copies identical, tools/test-cloud-init.py checks that.
[ -n "${BASH_VERSION-}" ] || return 0
[[ $- == *i* ]] || return 0

__shell_history_vars() {
  HISTSIZE=100000
  HISTFILESIZE=200000
  HISTTIMEFORMAT='%F %T  '
  HISTCONTROL=ignoreboth:erasedups
}
__shell_history_vars
shopt -s histappend cmdhist

# Run before each prompt: append the last command to the history file so parallel sessions share history.
# On Debian and Ubuntu the user's ~/.bashrc runs after this file and lowers the limits, so the first
# prompt applies them again (a later change by hand in a session is kept).
__shell_history_prompt() {
  history -a
  if [[ -z "${__shell_history_done-}" ]]; then
    __shell_history_done=1
    __shell_history_vars
  fi
}
# Keeps an existing PROMPT_COMMAND (string or array) and is safe to source twice.
# When PROMPT_COMMAND is still empty (Fedora/EL login shells read profile.d before /etc/bashrc, which sets
# the terminal title only if PROMPT_COMMAND is empty), use an array with an empty first element: /etc/bashrc
# then fills element 0 with its title command and the hook stays in element 1 (bash 5.1+ runs every element).
if [[ -z "${PROMPT_COMMAND-}" && "$(declare -p PROMPT_COMMAND 2>/dev/null)" != "declare -a"* ]] && (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )); then
  unset PROMPT_COMMAND
  PROMPT_COMMAND=('' '__shell_history_prompt')
fi
case "$(declare -p PROMPT_COMMAND 2>/dev/null)" in
  "declare -a"*)
    [[ " ${PROMPT_COMMAND[*]} " == *" __shell_history_prompt "* ]] || PROMPT_COMMAND+=('__shell_history_prompt')
    ;;
  *)
    if [[ "${PROMPT_COMMAND-}" != *__shell_history_prompt* ]]; then
      __pc="${PROMPT_COMMAND-}"
      while [[ "$__pc" == *[[:space:]\;] ]]; do __pc="${__pc%?}"; done
      # shellcheck disable=SC2178
      PROMPT_COMMAND="${__pc:+$__pc;}__shell_history_prompt"
      unset __pc
    fi
    ;;
esac

# Debian and Ubuntu install fd as fdfind.
if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
  alias fd=fdfind
  __fd=fdfind
elif command -v fd >/dev/null 2>&1; then
  __fd=fd
fi
if [[ -n "${__fd-}" ]]; then
  export FZF_DEFAULT_COMMAND="${FZF_DEFAULT_COMMAND:-$__fd --type f --hidden --follow --exclude .git}"
  export FZF_CTRL_T_COMMAND="${FZF_CTRL_T_COMMAND:-$FZF_DEFAULT_COMMAND}"
  export FZF_ALT_C_COMMAND="${FZF_ALT_C_COMMAND:-$__fd --type d --hidden --follow --exclude .git}"
fi
unset __fd

if command -v fzf >/dev/null 2>&1; then
  for __f in /usr/share/fzf/shell/key-bindings.bash /usr/share/doc/fzf/examples/key-bindings.bash; do
    if [[ -r "$__f" ]]; then
      # shellcheck source=/dev/null
      . "$__f"
      __fzf_done=1
      break
    fi
  done
  # fzf 0.48+ can print its own bindings when the package ships no file.
  if [[ -z "${__fzf_done-}" ]] && __fzf_b=$(fzf --bash 2>/dev/null); then
    eval "$__fzf_b"
  fi
  unset __f __fzf_done __fzf_b
fi
EOF
  # Docker settings are only seeded; an existing daemon.json is never overwritten.
  [[ -f /etc/docker/daemon.json ]] || put /etc/docker/daemon.json 0644 <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
}

ssh_hardening() {
  if sshd -t; then
    systemctl reload sshd
  else
    rm -f /etc/ssh/sshd_config.d/00-hardening.conf
    fail "sshd rejected 00-hardening.conf; removed it, defaults kept"
  fi
}

admin_user() {
  [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { fail "invalid ADMIN_USER: $ADMIN_USER"; return 1; }
  id "$ADMIN_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G wheel "$ADMIN_USER" || return 1
  usermod -aG wheel "$ADMIN_USER" || return 1
  # useradd leaves "!" (locked); use "*" (no password, keys only) like runner/install/users.sh.
  if [[ "$(getent shadow "$ADMIN_USER" | cut -d: -f2)" == '!'* ]]; then usermod -p '*' "$ADMIN_USER" || return 1; fi
  if [[ -s /root/.ssh/authorized_keys ]]; then
    install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/${ADMIN_USER}/.ssh" || return 1
    install -m 0600 -o "$ADMIN_USER" -g "$ADMIN_USER" /root/.ssh/authorized_keys "/home/${ADMIN_USER}/.ssh/authorized_keys" || return 1
    restorecon -R "/home/${ADMIN_USER}/.ssh" 2>/dev/null || true
  else
    fail "root has no authorized_keys; ${ADMIN_USER} created without SSH keys"
  fi
  local sudoers="/etc/sudoers.d/90-${ADMIN_USER}"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ADMIN_USER" > "${sudoers}.tmp" || return 1
  chmod 0440 "${sudoers}.tmp"
  if visudo -cf "${sudoers}.tmp" >/dev/null; then mv -f "${sudoers}.tmp" "$sudoers"; else rm -f "${sudoers}.tmp"; return 1; fi
}

system_tuning() {
  timedatectl set-timezone "$TIMEZONE" || fail "unknown TIMEZONE: $TIMEZONE"
  systemctl restart systemd-journald || return 1
  sysctl --system >/dev/null || return 1
  systemctl enable --now chronyd
}

# Permanent firewalld change: live (firewall-cmd --permanent) when firewalld runs, offline otherwise.
fw_perm() {
  if systemctl is-active --quiet firewalld; then firewall-cmd --permanent "$@"; else firewall-offline-cmd "$@"; fi
}

# firewalld answers D-Bus a moment after systemctl returns: wait for it, then check ssh.
fw_ok() { local _; for _ in $(seq 30); do firewall-cmd --zone=public --query-service=ssh >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
fw_diag() { local c; { for c in --state --get-default-zone --get-active-zones "--zone=public --list-all" "--permanent --zone=public --list-all"; do echo "# $c"; firewall-cmd $c; done; systemctl status firewalld --no-pager; journalctl -u firewalld --no-pager -n 25; } 2>&1 | sed 's/^/firewalld: /' >> "$FAILED_LOG"; }

firewall() {
  local running=0 zone p ssh_ports=""
  systemctl is-active --quiet firewalld && running=1
  if (( running )); then zone=$(firewall-cmd --get-default-zone) || return 1; else zone=$(firewall-offline-cmd --get-default-zone) || return 1; fi
  if [[ "$zone" != public ]]; then
    if (( running )); then firewall-cmd --set-default-zone=public >/dev/null || return 1
    else firewall-offline-cmd --set-default-zone=public >/dev/null || return 1; fi
  fi
  fw_perm --zone=public --query-service=ssh >/dev/null 2>&1 || fw_perm --zone=public --add-service=ssh >/dev/null || return 1
  # sshd may listen on another port than 22 (bootstrap --port): that port is allowed too.
  for p in $(sshd -T 2>/dev/null | awk '$1 == "port" && $2 != 22 { print $2 }'); do
    fw_perm --zone=public --query-port="${p}/tcp" >/dev/null 2>&1 || fw_perm --zone=public --add-port="${p}/tcp" >/dev/null || return 1
    ssh_ports+=" $p"
  done
  # Lockout guard: never start or reload the firewall unless SSH is in the saved rules.
  fw_perm --zone=public --query-service=ssh >/dev/null 2>&1 || { fail "ssh missing from saved public zone; firewall left as it was"; return 1; }
  for p in $ssh_ports; do
    fw_perm --zone=public --query-port="${p}/tcp" >/dev/null 2>&1 || { fail "ssh port ${p} missing from saved public zone; firewall left as it was"; return 1; }
  done
  if (( running )); then firewall-cmd --reload >/dev/null || return 1; else systemctl enable --now firewalld || return 1; fi
  fw_ok || { fw_diag; systemctl stop firewalld; fail "ssh not allowed after start; firewalld stopped"; return 1; }
  for p in $ssh_ports; do
    firewall-cmd --zone=public --query-port="${p}/tcp" >/dev/null || { systemctl stop firewalld; fail "ssh port ${p} not allowed after start; firewalld stopped"; return 1; }
  done

  # Everything else is changed through the running daemon: firewall-offline-cmd rejects
  # --zone with --remove-service ("Can't use lokkit options with other options").
  local changed=0
  # The default public zone opens cockpit (and mdns on some images); a cloud server needs neither.
  for p in cockpit mdns; do
    if firewall-cmd --permanent --zone=public --query-service="$p" >/dev/null 2>&1; then
      if firewall-cmd --permanent --zone=public --remove-service="$p" >/dev/null; then changed=1; else fail "could not remove $p from public zone"; fi
    fi
  done
  for p in $EXTRA_PORTS; do
    if [[ "$p" =~ ^[0-9]{1,5}(-[0-9]{1,5})?/(tcp|udp)$ ]]; then
      if ! firewall-cmd --permanent --zone=public --query-port="$p" >/dev/null 2>&1; then
        if firewall-cmd --permanent --zone=public --add-port="$p" >/dev/null; then changed=1; else fail "could not open $p"; fi
      fi
    else
      fail "ignored invalid EXTRA_PORTS entry: $p"
    fi
  done
  if (( changed )); then firewall-cmd --reload >/dev/null || return 1; fi
  firewall-cmd --zone=public --query-service=ssh >/dev/null || { fail "ssh not allowed after reload"; return 1; }
}

fail2ban() {
  systemctl enable --now fail2ban || return 1
  systemctl restart fail2ban || return 1
}

auto_updates() {
  # Fedora 41+ ships dnf5; the automatic plugin is dnf5-plugin-automatic.
  rpm -q dnf5-plugin-automatic >/dev/null 2>&1 || dnf -y -q install dnf5-plugin-automatic || dnf -y -q install dnf-automatic || return 1
  install -d /etc/dnf
  cat > /etc/dnf/automatic.conf <<'CONF'
[commands]
upgrade_type = security
download_updates = yes
apply_updates = yes
reboot = never
[emitters]
emit_via = stdio
CONF
  # server-update.timer (server/install-tools.sh) replaces dnf-automatic: running both would race on the dnf lock.
  if systemctl is-enabled --quiet server-update.timer 2>/dev/null; then log "server-update.timer is enabled, dnf-automatic stays off"; return 0; fi
  systemctl enable --now dnf5-automatic.timer 2>/dev/null || systemctl enable --now dnf-automatic.timer 2>/dev/null
}

# pin_repo_key URL FINGERPRINT DEST: download an armored key, install only the key with that primary
# fingerprint (anything else in the file is dropped). Needs gpg.
pin_repo_key() {
  local url="$1" want="$2" dest="$3" tmp home ok=1
  command -v gpg >/dev/null || dnf -y -q install gnupg2 >/dev/null || return 1
  tmp=$(mktemp) && home=$(mktemp -d) || return 1
  if curl -fsSL "$url" -o "$tmp" \
     && GNUPGHOME="$home" gpg --batch --quiet --import "$tmp" 2>/dev/null \
     && GNUPGHOME="$home" gpg --batch --with-colons --list-keys 2>/dev/null \
        | awk -F: '$1 == "pub" { g = 1; next } $1 == "fpr" && g { print $10; g = 0 }' | grep -qx "$want" \
     && GNUPGHOME="$home" gpg --batch --export --armor "$want" > "$tmp.out" 2>/dev/null && [[ -s "$tmp.out" ]]; then
    install -D -m 0644 "$tmp.out" "$dest" && ok=0
  else
    fail "key from ${url} does not have the expected fingerprint ${want}; not installed"
  fi
  rm -rf "$tmp" "$tmp.out" "$home"
  return "$ok"
}

# The repo file is written here and trusts only the pinned Docker rpm key (no vendor .repo file, no key fetched by dnf).
docker_repo() {
  pin_repo_key "https://download.docker.com/linux/fedora/gpg" 060A61C51B558A7F742B77AAC52FEB6B621E9F35 /etc/pki/rpm-gpg/docker-ce.asc || return 1
  cat > /etc/yum.repos.d/docker-ce.repo <<'REPO'
[docker-ce-stable]
name=Docker CE Stable
baseurl=https://download.docker.com/linux/fedora/$releasever/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/docker-ce.asc
REPO
}

docker_engine() {
  (( INSTALL_DOCKER == 1 )) || { log "Docker disabled in /etc/server-init.conf"; return 0; }
  if ! command -v docker >/dev/null; then
    if ! dnf repolist --enabled 2>/dev/null | grep -q '^docker-ce-stable'; then
      docker_repo || return 1
    fi
    dnf -y -q install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
  fi
  systemctl enable --now docker || return 1
  docker info >/dev/null
}

swap() {
  (( INSTALL_SWAP == 1 )) || { log "swap disabled in /etc/server-init.conf"; return 0; }
  # Fedora enables zram swap by default; add a disk swap file only when there is no swap at all.
  if [[ -n "$(swapon --noheadings --show=NAME)" ]]; then log "swap already present: $(swapon --noheadings --show=NAME | tr '\n' ' ')"; return 0; fi
  local mem_mb size_mb
  mem_mb=$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)
  size_mb=$(( mem_mb < 1024 ? 1024 : (mem_mb > 4096 ? 4096 : mem_mb) ))
  if [[ ! -f /swapfile ]]; then
    if [[ "$(findmnt -no FSTYPE /)" == btrfs ]]; then
      btrfs filesystem mkswapfile --size "${size_mb}m" /swapfile || return 1
    else
      { fallocate -l "${size_mb}M" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none; } || return 1
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null || return 1
    fi
  fi
  restorecon /swapfile 2>/dev/null || true
  swapon /swapfile || return 1
  grep -qE '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap defaults 0 0' >> /etc/fstab
}

# Same text as server/server-cleanup.sh (keep identical; tools/test-cloud-init.py checks it).
cleanup() {
  if (( INSTALL_CLEANUP != 1 )); then
    log "cleanup disabled in /etc/server-init.conf"
    if systemctl cat server-cleanup.timer >/dev/null 2>&1; then systemctl disable --now server-cleanup.timer || return 1; fi
    return 0
  fi
  put /usr/local/sbin/server-cleanup 0755 <<'EOF'
#!/usr/bin/env bash
# server-cleanup: safe cleanup for a general server (journal, package cache, Docker leftovers, rotated logs,
# temp files, core dumps). Never touches /home, /root, /srv, /opt, Docker volumes, databases or repos.
# Same text is embedded in the server/server-init-*.sh scripts that install it (they must stay
# self-contained): keep all copies identical, tools/test-cloud-init.py checks that.
# Settings come from /etc/server-init.conf (CLEAN_JOURNAL_TIME, CLEAN_JOURNAL_SIZE, CLEAN_AUTOREMOVE,
# CLEAN_DOCKER_UNUSED_IMAGES); missing keys use the defaults below.
set -uo pipefail
CONF=${SERVER_INIT_CONF:-/etc/server-init.conf}
STATE=${SERVER_CLEANUP_STATE:-/var/lib/server-cleanup}
DRY=0

usage() {
  cat <<'USAGE'
Usage: server-cleanup [--dry-run] [--help]

Safe cleanup, each part skipped when its tool is missing:
  journald     journalctl --vacuum-time/--vacuum-size (CLEAN_JOURNAL_TIME, CLEAN_JOURNAL_SIZE)
  packages     dnf clean packages (installonly_limit=3 if unset), apt-get clean or zypper clean;
               dnf/apt-get autoremove only with CLEAN_AUTOREMOVE=1
  docker       dangling images, build cache and stopped containers older than 7d; never volumes;
               CLEAN_DOCKER_UNUSED_IMAGES=1 also prunes unused images older than 30d
  temp         systemd-tmpfiles --clean for /tmp and /var/tmp (the system's own age rules)
  logs         /var/log/*.gz and *.[0-9] older than 30d
  core dumps   /var/lib/systemd/coredump older than 7d; crash dirs (/var/crash, /var/spool/abrt) older than 30d
  --dry-run    print what would be done, change nothing
Logs to stdout and syslog (tag server-cleanup). Exit: 0 ok, 1 not root, 2 bad option, 3 an action failed.
USAGE
}
for a in "$@"; do
  case "$a" in
    -n|--dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "server-cleanup: unknown option: $a" >&2; usage >&2; exit 2 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo "server-cleanup: run as root (sudo server-cleanup)" >&2; exit 1; }
# shellcheck source=/dev/null
[[ -r $CONF ]] && . "$CONF"
J_TIME=${CLEAN_JOURNAL_TIME:-1month}
J_SIZE=${CLEAN_JOURNAL_SIZE:-500M}
ERRORS=0

log() {
  local lvl=$1; shift
  printf 'ts=%s level=%s msg="%s"\n' "$(date -Is)" "$lvl" "$*"
  (( DRY )) || ! command -v logger >/dev/null 2>&1 || logger -t server-cleanup -- "level=$lvl msg=\"$*\"" || true
}
have() { command -v "$1" >/dev/null 2>&1; }
skip() { log info "skip $1: $2"; }
[[ $J_TIME =~ ^[0-9]+[a-z]*$ ]] || { log warn "bad CLEAN_JOURNAL_TIME '$J_TIME', using 1month"; J_TIME=1month; }
[[ $J_SIZE =~ ^[0-9]+[KMGT]?$ ]] || { log warn "bad CLEAN_JOURNAL_SIZE '$J_SIZE', using 500M"; J_SIZE=500M; }

run() {
  if (( DRY )); then log info "would run: $*"; return 0; fi
  local out rc l
  out=$("$@" 2>&1); rc=$?
  log info "ran: $* (exit $rc)"
  if [[ -n $out ]]; then
    while IFS= read -r l; do log info "  $l"; done < <(tail -n 5 <<<"$out")
  fi
  (( rc == 0 )) || { log warn "failed (exit $rc): $*"; ERRORS=$((ERRORS + 1)); }
  return 0
}

# prune_old DESC DAYS DIR [find tests...]: delete regular files older than DAYS under DIR, same filesystem.
prune_old() {
  local desc=$1 days=$2 dir=$3 n kb; shift 3
  case $dir in /|/home*|/root*|/srv*|/opt*|/var/lib/docker*) log error "refusing protected path $dir"; ERRORS=$((ERRORS + 1)); return 0 ;; esac
  [[ -d $dir ]] || { skip "$desc" "$dir not present"; return 0; }
  read -r n kb < <(find "$dir" -xdev -type f "$@" -mtime +"$days" -printf '%s\n' 2>/dev/null | awk '{ n++; s += $1 } END { print n + 0, int(s / 1024) }')
  if (( n == 0 )); then log info "$desc: nothing older than ${days}d in $dir"; return 0; fi
  if (( DRY )); then log info "would delete $desc: $n files, ${kb} KiB in $dir (older than ${days}d)"; return 0; fi
  find "$dir" -xdev -type f "$@" -mtime +"$days" -delete 2>/dev/null
  [[ $dir == /var/log ]] || find "$dir" -xdev -mindepth 1 -type d -empty -mtime +"$days" -delete 2>/dev/null
  log info "deleted $desc: $n files, ${kb} KiB in $dir (older than ${days}d)"
  return 0
}

avail_mb() { df -Pk / | awk 'NR == 2 { print int($4 / 1024) }'; }
disk() { df -Pk / | awk 'NR == 2 { printf "used=%dMiB avail=%dMiB use=%s", $3 / 1024, $4 / 1024, $5 }'; }

if (( ! DRY )); then
  exec 9>/run/server-cleanup.lock
  if have flock && ! flock -n 9; then log info "another server-cleanup is running, exit"; exit 0; fi
fi
before=$(avail_mb)
log info "start dry_run=$DRY disk_before: $(disk)"

if have journalctl; then
  log info "journal: $(journalctl --disk-usage 2>&1 | head -n1)"
  run journalctl --vacuum-time="$J_TIME" --vacuum-size="$J_SIZE"
else skip journald "journalctl not found"; fi

if have dnf; then
  run dnf clean packages
  if [[ -f /etc/dnf/dnf.conf ]] && ! grep -q '^installonly_limit' /etc/dnf/dnf.conf; then
    if (( DRY )); then log info "would set installonly_limit=3 in /etc/dnf/dnf.conf"
    elif grep -q '^\[main\]' /etc/dnf/dnf.conf; then sed -i '/^\[main\]/a installonly_limit=3' /etc/dnf/dnf.conf && log info "set installonly_limit=3 in /etc/dnf/dnf.conf (old kernels are removed by dnf, never the running one)"
    else log warn "no [main] section in /etc/dnf/dnf.conf, installonly_limit left unset"; fi
  fi
  if [[ ${CLEAN_AUTOREMOVE:-0} == 1 ]]; then run dnf -y autoremove; else skip autoremove "CLEAN_AUTOREMOVE is not 1"; fi
elif have apt-get; then
  run apt-get clean
  if [[ ${CLEAN_AUTOREMOVE:-0} == 1 ]]; then run apt-get -y autoremove; else skip autoremove "CLEAN_AUTOREMOVE is not 1"; fi
elif have zypper; then
  run zypper --non-interactive clean
else skip packages "dnf, apt-get and zypper not found"; fi

if have docker && systemctl is-active --quiet docker 2>/dev/null; then
  run docker container prune -f --filter until=168h
  run docker image prune -f
  run docker builder prune -f --filter until=168h
  if [[ ${CLEAN_DOCKER_UNUSED_IMAGES:-0} == 1 ]]; then run docker image prune -a -f --filter until=720h; fi
else skip docker "docker is not installed or not active"; fi

if have systemd-tmpfiles; then run systemd-tmpfiles --clean --prefix=/tmp --prefix=/var/tmp
else skip temp "systemd-tmpfiles not found"; fi
prune_old "rotated logs" 30 /var/log \( -name '*.gz' -o -name '*.[0-9]' \)
prune_old "core dumps" 7 /var/lib/systemd/coredump
prune_old "crash reports" 30 /var/crash
prune_old "abrt reports" 30 /var/spool/abrt

after=$(avail_mb)
log info "done dry_run=$DRY errors=$ERRORS freed=$(( after - before ))MiB disk_after: $(disk)"
if (( ! DRY )); then
  mkdir -p "$STATE" && chmod 0755 "$STATE" && date +%s > "$STATE/last-run" && chmod 0644 "$STATE/last-run"
  if (( ERRORS == 0 )); then echo ok > "$STATE/last-result"; else echo failed > "$STATE/last-result"; fi
  if [[ -z ${SERVER_CLEANUP_QUIET:-} && -x /usr/local/sbin/server-notify ]]; then
    res="done"; (( ERRORS == 0 )) || res="finished with $ERRORS error(s)"
    /usr/local/sbin/server-notify cleanup "cleanup ${res}: freed $(( after - before )) MiB, $(disk)" || true
  fi
fi
(( ERRORS == 0 )) || exit 3
exit 0
EOF
  local sched="$CLEAN_SCHEDULE"
  if command -v systemd-analyze >/dev/null 2>&1 && ! systemd-analyze calendar "$sched" >/dev/null 2>&1; then fail "invalid CLEAN_SCHEDULE '$sched', using weekly"; sched=weekly; fi
  put /etc/systemd/system/server-cleanup.service 0644 <<'EOF'
[Unit]
Description=Server cleanup (journal, package cache, Docker leftovers, old logs and temp files)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/server-cleanup
Nice=19
IOSchedulingClass=idle
ProtectHome=read-only
NoNewPrivileges=yes
EOF
  # PrivateTmp stays off on purpose: the job cleans the real /tmp through systemd-tmpfiles.
  put /etc/systemd/system/server-cleanup.timer 0644 <<EOF
[Unit]
Description=Weekly server cleanup

[Timer]
OnCalendar=${sched}
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload || return 1
  systemctl enable --now server-cleanup.timer
}

log "start"
step packages packages
step configs write_configs
step ssh-hardening ssh_hardening
step admin-user admin_user
step system-tuning system_tuning
step firewall firewall
step fail2ban fail2ban
step auto-updates auto_updates
step docker docker_engine
step swap swap
step cleanup cleanup
log "open in firewall: $(firewall-cmd --zone=public --list-services 2>/dev/null) $(firewall-cmd --zone=public --list-ports 2>/dev/null)"
if (( ${#FAILED_STEPS[@]} )); then
  log "done with failures: ${FAILED_STEPS[*]} (details: $FAILED_LOG)"
  exit 1
fi
log "done, all steps ok"
