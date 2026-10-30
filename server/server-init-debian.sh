#!/usr/bin/env bash
# Base setup for a general (non-runner) server on Ubuntu 26.04 (also 24.04) or Debian 13, x86_64 or ARM64:
# SSH keys only, admin user with sudo, ufw, fail2ban for SSH, automatic security updates,
# Docker Engine + Compose, swap + sysctl, journald limit, time sync, admin tools, shell history.
# Also safe on Hetzner Apps images (Ubuntu 24.04 with Coolify, Docker CE, GitLab CE, Jitsi Meet, Owncast,
# PhotoPrism, Prometheus Grafana or RustDesk preinstalled): existing Docker, firewall rules and app
# configuration are never touched, only the app's own ports are added to ufw.
# Root keeps login by SSH key on port 22, so nothing here can lock you out.
#
# Self-contained and idempotent: it writes its own config files, so it runs the same from a paste
# or from a copy of the repo. Rerun as root any time: /usr/local/sbin/server-init.sh
# Settings live in /etc/server-init.conf (created on first run from the environment or defaults).
# Every step after SSH hardening is non-fatal: a failed step is logged and the next one still runs.
set -Eeuo pipefail

FAILED_LOG=/var/log/server-init-failed.log
CONF_FILE=/etc/server-init.conf
(( EUID == 0 )) || { echo "run as root" >&2; exit 1; }
# shellcheck source=/dev/null
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:24.04 | ubuntu:26.04) DOCKER_DISTRO=ubuntu; CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" ;;
  debian:13) DOCKER_DISTRO=debian; CODENAME="${VERSION_CODENAME:-}" ;;
  # return when sourced into an interactive shell by mistake, so the shell is not closed
  *) echo "this script is for Ubuntu 26.04 / Ubuntu 24.04 / Debian 13, found ${PRETTY_NAME:-unknown}" >&2; return 1 2>/dev/null || exit 1 ;;
esac
# No prompts from apt, dpkg or needrestart, and wait for the apt lock that cloud-init or unattended-upgrades may hold.
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

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
# Hetzner Apps image: auto detects it, none ignores it, or name it: coolify docker-ce gitlab jitsi lamp
# nextcloud owncast photoprism prometheus-grafana rustdesk wireguard wordpress. A detected app gets its
# own ports opened in ufw. On a wireguard image ufw is left off (its nftables.service flushes the ruleset).
APP=${APP:-auto}
CONF
fi
# shellcheck source=/dev/null
. "$CONF_FILE"
ADMIN_USER="${ADMIN_USER:-ops}"
EXTRA_PORTS="${EXTRA_PORTS:-}"
INSTALL_DOCKER="${INSTALL_DOCKER:-1}"
INSTALL_SWAP="${INSTALL_SWAP:-1}"
TIMEZONE="${TIMEZONE:-Europe/Kyiv}"
APP="${APP:-auto}"
FAILED_STEPS=()

log()  { echo "[$(date +%H:%M:%S)] $*"; }
fail() { log "WARN: $*"; echo "$(date -Is) $*" >> "$FAILED_LOG"; }
step() {
  local name="$1"; shift
  log "step: ${name}"
  if "$@"; then log "ok: ${name}"; else fail "step failed: ${name}"; FAILED_STEPS+=("$name"); fi
}

apt_get() {
  apt-get -y -q -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}
pkg_installed() { [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == installed ]]; }

packages() {
  apt_get update >/dev/null || return 1
  # Required: ufw, fail2ban (+ python3-systemd for the journal backend, nftables for its bans), unattended-upgrades, curl.
  # Ubuntu 26.04 ships sudo-rs as its sudo; the sudo package is added only when no sudo command exists.
  local required=(openssh-server ufw nftables fail2ban python3-systemd unattended-upgrades curl ca-certificates gnupg)
  command -v sudo >/dev/null && command -v visudo >/dev/null || required+=(sudo)
  apt_get install "${required[@]}" >/dev/null || return 1
  local p
  for p in git jq tmux htop btop ncdu iotop mtr-tiny bind9-dnsutils tcpdump vim nano rsync wget unzip tar bash-completion mc fzf fd-find ripgrep; do
    pkg_installed "$p" || apt_get install "$p" >/dev/null || fail "optional package not installed: $p"
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
  # The journal backend is needed because Debian 13 has no /var/log/auth.log. Bans go through nftables,
  # which works whether or not ufw is active (ufw uses its own chains). Both are also the package defaults.
  # The jail must watch the port sshd really listens on (bootstrap --port), not only the default 22.
  sshd_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' | sort -un | paste -sd, -) || true
  put /etc/fail2ban/jail.d/50-sshd.local 0644 <<EOF
[DEFAULT]
banaction = nftables
banaction_allports = nftables[type=allports]

[sshd]
enabled  = true
port     = ${sshd_ports:-ssh}
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
  # Security updates only, never an automatic reboot. #clear drops the distro's wider default origin list.
  put /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  if [[ "$DOCKER_DISTRO" == ubuntu ]]; then
    put /etc/apt/apt.conf.d/52server-init-unattended 0644 <<'EOF'
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  else
    put /etc/apt/apt.conf.d/52server-init-unattended 0644 <<'EOF'
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  fi
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
  # Docker settings are only seeded on a server without Docker; an existing install (for example a
  # Hetzner Apps image) and an existing daemon.json are never touched.
  if (( INSTALL_DOCKER == 1 )) && ! command -v docker >/dev/null && [[ ! -f /etc/docker/daemon.json ]]; then
    put /etc/docker/daemon.json 0644 <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
EOF
  fi
}

ssh_hardening() {
  # sshd -t needs the privilege separation directory, which the service normally creates.
  command -v sshd >/dev/null || { fail "sshd is not installed; hardening not applied"; return 1; }
  [[ -d /run/sshd ]] || install -d -m 0755 /run/sshd
  if sshd -t; then
    # Ubuntu may start sshd through ssh.socket: a running ssh.service is reloaded, otherwise the
    # next connection starts a new sshd that reads the drop-in anyway.
    if systemctl is-active --quiet ssh; then systemctl reload ssh; else log "ssh.service is not running (socket activation or no systemd); the drop-in applies to the next connection"; fi
  else
    rm -f /etc/ssh/sshd_config.d/00-hardening.conf
    fail "sshd rejected 00-hardening.conf; removed it, defaults kept"
  fi
}

admin_user() {
  [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { fail "invalid ADMIN_USER: $ADMIN_USER"; return 1; }
  id "$ADMIN_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo "$ADMIN_USER" || return 1
  usermod -aG sudo "$ADMIN_USER" || return 1
  if [[ -s /root/.ssh/authorized_keys ]]; then
    install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/${ADMIN_USER}/.ssh" || return 1
    install -m 0600 -o "$ADMIN_USER" -g "$ADMIN_USER" /root/.ssh/authorized_keys "/home/${ADMIN_USER}/.ssh/authorized_keys" || return 1
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
  # Keep the time sync that is already running (systemd-timesyncd or chrony); install chrony only if neither is.
  if systemctl is-active --quiet systemd-timesyncd; then log "time sync: systemd-timesyncd (kept)"
  elif systemctl is-active --quiet chrony; then log "time sync: chrony (kept)"
  else
    pkg_installed chrony || apt_get install chrony >/dev/null || return 1
    systemctl enable --now chrony
  fi
}

# Hetzner Apps (https://github.com/hetznercloud/apps, apps/hetzner/<app>): all are built on Ubuntu 24.04
# (template.pkr.hcl, hcloud_image). The images ship no ufw rules; the ports below are the ones the
# image itself serves or publishes. APP_PORTS and APP_NAME are set by detect_app.
APP_NAME=""
APP_PORTS=""
# Set to 1 for an app whose image owns the firewall (ufw must not be enabled).
APP_OWN_FW=0
APP_BAD=0   # 1 when APP in the config names no known app (a typo): firewall() then leaves ufw alone
app_ports() {
  case "$1" in
    # coolify/test.sh checks the dashboard on http://localhost:8000; the rest is set up by Coolify's
    # own installer on first login and is not documented in the repo (add it to EXTRA_PORTS if needed).
    coolify) APP_PORTS="8000/tcp" ;;
    # docker-ce/scripts/docker.sh only installs Docker; no port is opened.
    docker-ce) APP_PORTS="" ;;
    # gitlab/files/etc/apache2/sites-available/000-default.conf serves port 80 until GitLab is enabled;
    # gitlab/README.md enables HTTPS (external_url https, Let's Encrypt) afterwards.
    gitlab) APP_PORTS="80/tcp 443/tcp" ;;
    # jitsi/files/etc/nginx/sites-available/hetzner listens on 80; jitsi/files/opt/hcloud/jitsi_setup.sh
    # sets up the nginx site with a certificate (443). jitsi-videobridge2 takes media on 10000/udp
    # (Jitsi quick-install guide); coturn (3478/udp, 5349/tcp) is added in firewall() when installed.
    jitsi) APP_PORTS="80/tcp 443/tcp 10000/udp" ;;
    # lamp, wordpress and nextcloud run the native Apache of the image (/opt/hcloud/{lamp,wp,nextcloud}_setup.sh).
    lamp|wordpress|nextcloud) APP_PORTS="80/tcp 443/tcp" ;;
    # wireguard: wg on WGUI_SERVER_LISTEN_PORT=51820/udp plus Caddy on 80/443 for the UI. Its
    # /etc/nftables.conf starts with "flush ruleset" and nftables.service is enabled, so the image owns the
    # firewall: firewall() does not enable ufw here.
    wireguard) APP_PORTS="51820/udp 80/tcp 443/tcp"; APP_OWN_FW=1 ;;
    # apps/hetzner/<app>/files/opt/containers/<app>/docker-compose.yml, "ports:" of traefik/caddy/services.
    owncast) APP_PORTS="80/tcp 443/tcp 1935/tcp" ;;
    photoprism) APP_PORTS="80/tcp 443/tcp 2342/tcp" ;;
    prometheus-grafana) APP_PORTS="80/tcp 443/tcp" ;;
    rustdesk) APP_PORTS="21115/tcp 21116/tcp 21116/udp 21117/tcp 21118/tcp 21119/tcp" ;;
    *) return 1 ;;
  esac
}

detect_app() {
  APP_NAME=""; APP_PORTS=""; APP_OWN_FW=0; APP_BAD=0
  case "$APP" in
    none) return 0 ;;
    auto) ;;
    *) if app_ports "$APP"; then APP_NAME="$APP"; return 0; fi
       fail "unknown APP in $CONF_FILE: $APP"; APP_PORTS=""; APP_BAD=1; return 0 ;;
  esac
  local a
  # Markers: the compose project the image copies to /opt/containers/<app>, the first-login script
  # /opt/hcloud/<app>_setup.sh (appended to /root/.bashrc by files/var/lib/cloud/scripts/per-instance/001_onboot),
  # the gitlab-ce / jitsi-meet packages, and /data/coolify from Coolify's installer.
  for a in owncast photoprism prometheus-grafana rustdesk; do
    [[ -f "/opt/containers/${a}/docker-compose.yml" ]] && { APP_NAME="$a"; break; }
  done
  if [[ -z "$APP_NAME" ]]; then
    if pkg_installed gitlab-ce || [[ -f /opt/hcloud/gitlab_setup.sh ]]; then APP_NAME=gitlab
    elif pkg_installed jitsi-meet || [[ -f /opt/hcloud/jitsi_setup.sh ]]; then APP_NAME=jitsi
    elif [[ -f /opt/hcloud/lamp_setup.sh ]]; then APP_NAME=lamp
    elif [[ -f /opt/hcloud/wp_setup.sh ]]; then APP_NAME=wordpress
    elif [[ -f /opt/hcloud/nextcloud_setup.sh ]]; then APP_NAME=nextcloud
    elif [[ -f /opt/hcloud/wireguard_setup.sh || -f /etc/default/wireguard-ui ]]; then APP_NAME=wireguard
    elif [[ -d /data/coolify || -f /opt/hcloud/coolify_setup.sh ]]; then APP_NAME=coolify
    elif [[ -f /etc/apt/preferences.d/docker-ce.pref && -f /etc/apt/sources.list.d/docker.list ]]; then APP_NAME=docker-ce
    fi
  fi
  [[ -z "$APP_NAME" ]] || app_ports "$APP_NAME"
  return 0
}

# The output is captured first: grep -q closing a pipe early would fail the pipeline under pipefail.
ufw_is_active() { local o; o=$(ufw status 2>/dev/null) || return 1; grep -q '^Status: active' <<<"$o"; }
# True when the saved rules (active or not) allow SSH on 22.
ufw_ssh_saved() { local o; o=$(ufw show added 2>/dev/null) || return 1; grep -qE '^ufw (allow|limit) (in )?(22(/tcp)?|ssh|OpenSSH)([[:space:]]|$)' <<<"$o"; }
# True when the running firewall lists SSH as allowed.
ufw_ssh_live() { local o; o=$(ufw status 2>/dev/null) || return 1; grep -qE '^(22(/tcp)?|OpenSSH|ssh)([[:space:]]+\(v6\))?[[:space:]]+(ALLOW|LIMIT)' <<<"$o"; }

# A port range in ufw is written 6000:6007/tcp.
ufw_open() { ufw allow "${1/-/:}" >/dev/null || { fail "could not open $1"; return 1; }; }

# True for a Hetzner Apps image this script has no port list for.
unknown_hetzner_app() {
  local f
  for f in /opt/hcloud/*_setup.sh /var/lib/cloud/scripts/per-instance/001_onboot; do [[ -e "$f" ]] && return 0; done
  return 1
}

firewall() {
  local was_active=0 p ssh_ports=""
  detect_app
  if (( APP_BAD )); then
    fail "unknown APP=${APP}: the app's ports are unknown, so ufw was not enabled (fix APP in $CONF_FILE, or use APP=none and EXTRA_PORTS, then rerun)"
    return 1
  fi
  if [[ "$APP" == auto && -z "$APP_NAME" ]] && unknown_hetzner_app; then
    fail "unrecognised Hetzner Apps image: its ports are unknown, so ufw was not enabled (set APP=<name> or APP=none and EXTRA_PORTS in $CONF_FILE, then rerun)"
    return 1
  fi
  if (( APP_OWN_FW )); then
    log "Hetzner app: ${APP_NAME}; its image manages the firewall (nftables), so ufw is not enabled. Ports it serves: ${APP_PORTS}"
    return 0
  fi
  ufw_is_active && was_active=1
  ufw_ssh_saved || ufw allow 22/tcp >/dev/null || return 1
  # sshd may listen on another port than 22 (bootstrap --port): that port is allowed too.
  for p in $(sshd -T 2>/dev/null | awk '$1 == "port" && $2 != 22 { print $2 }'); do
    ufw allow "${p}/tcp" >/dev/null || return 1
    ssh_ports+=" $p"
  done
  # Lockout guard: never enable the firewall unless SSH is in the saved rules.
  ufw_ssh_saved || { fail "22/tcp missing from saved ufw rules; ufw left as it was"; return 1; }
  local o
  for p in $ssh_ports; do
    o=$(ufw show added 2>/dev/null) || true
    grep -qE "^ufw (allow|limit) (in )?${p}/tcp([[:space:]]|\$)" <<<"$o" || { fail "ssh port ${p} missing from saved ufw rules; ufw left as it was"; return 1; }
  done
  # Defaults are set only when ufw is switched on for the first time; an active ufw keeps what it has.
  if (( ! was_active )); then
    ufw default deny incoming >/dev/null || return 1
    ufw default allow outgoing >/dev/null || return 1
  fi
  for p in $EXTRA_PORTS; do
    if [[ "$p" =~ ^[0-9]{1,5}(-[0-9]{1,5})?/(tcp|udp)$ ]]; then ufw_open "$p" || true; else fail "ignored invalid EXTRA_PORTS entry: $p"; fi
  done
  if [[ -n "$APP_NAME" ]]; then
    [[ "$APP_NAME" != jitsi ]] || ! pkg_installed coturn || APP_PORTS="$APP_PORTS 3478/udp 5349/tcp"
    log "Hetzner app: ${APP_NAME}; opening its ports: ${APP_PORTS:-none}"
    for p in $APP_PORTS; do ufw_open "$p" || true; done
  fi
  if (( ! was_active )); then
    ufw --force enable >/dev/null || return 1
    systemctl enable ufw >/dev/null 2>&1 || true
  fi
  # A rule added to an active ufw applies at once; here SSH must still be allowed.
  local live=1
  ufw_ssh_live || live=0
  o=$(ufw status 2>/dev/null) || true
  for p in $ssh_ports; do grep -qE "^${p}/tcp([[:space:]]+\(v6\))?[[:space:]]+(ALLOW|LIMIT)" <<<"$o" || live=0; done
  if (( ! live )); then
    if (( was_active )); then fail "ssh not allowed in running ufw"; else ufw disable >/dev/null 2>&1 || true; fail "ssh not allowed after enabling ufw; ufw disabled again"; fi
    return 1
  fi
  log "ufw: $(ufw status | head -1)"
}

fail2ban() {
  systemctl enable --now fail2ban || return 1
  systemctl restart fail2ban || return 1
}

auto_updates() {
  pkg_installed unattended-upgrades || apt_get install unattended-upgrades >/dev/null || return 1
  # The apt.conf.d files are written by write_configs; the daily timers run the upgrade.
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
}

# pin_repo_key URL FINGERPRINT DEST: download an armored key, install only the key with that primary
# fingerprint (anything else in the file is dropped). Needs gpg.
pin_repo_key() {
  local url="$1" want="$2" dest="$3" tmp home ok=1
  command -v gpg >/dev/null || apt_get install gnupg >/dev/null || return 1
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

docker_engine() {
  (( INSTALL_DOCKER == 1 )) || { log "Docker disabled in /etc/server-init.conf"; return 0; }
  if command -v docker >/dev/null; then
    # Already installed (own earlier run or a Hetzner Apps image): keep its repo, packages and daemon.json.
    log "Docker present ($(docker --version 2>/dev/null)); not reinstalled or reconfigured"
    systemctl is-active --quiet docker || systemctl enable --now docker || return 1
    docker info >/dev/null
    return
  fi
  local arch repo_ok=0 src compose_pkg=docker-compose
  # Compose v2 is docker-compose-v2 on Ubuntu but docker-compose on Debian.
  [[ "$DOCKER_DISTRO" != ubuntu ]] || compose_pkg=docker-compose-v2
  arch=$(dpkg --print-architecture)
  src="https://download.docker.com/linux/${DOCKER_DISTRO}"
  # Docker publishes a repo per codename; use it only when the index exists for this architecture.
  # Only a definite 404 means "no repo"; a DNS or network error must not downgrade the host to docker.io for good.
  if [[ -n "$CODENAME" ]]; then
    local code=""
    for _ in 1 2 3; do
      code=$(curl -sSI -o /dev/null -w '%{http_code}' --max-time 20 "${src}/dists/${CODENAME}/stable/binary-${arch}/Packages" 2>/dev/null || true)
      [[ "$code" == 200 || "$code" == 404 ]] && break
      sleep 5
    done
    case "$code" in
      200) repo_ok=1 ;;
      404) ;;
      *) log "cannot reach download.docker.com (HTTP ${code:-none}); Docker not installed now, rerun later"; return 1 ;;
    esac
  fi
  if (( repo_ok )); then
    install -m 0755 -d /etc/apt/keyrings || return 1
    # Trust the key only if it is Docker's: fingerprint of "Docker Release (CE deb)", checked before it is installed.
    pin_repo_key "${src}/gpg" 9DC858229FC7DD38854AE2D88D81803C0EBFCD88 /etc/apt/keyrings/docker.asc || return 1
    put /etc/apt/sources.list.d/docker.sources 0644 <<EOF
Types: deb
URIs: ${src}
Suites: ${CODENAME}
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt_get update >/dev/null || return 1
    apt_get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null || return 1
    log "Docker source: download.docker.com (${DOCKER_DISTRO} ${CODENAME}, ${arch})"
  else
    log "download.docker.com has no repo for ${DOCKER_DISTRO} ${CODENAME:-unknown} ${arch}; using the distro packages"
    apt_get install docker.io "$compose_pkg" >/dev/null || return 1
    log "Docker source: distro packages docker.io + ${compose_pkg}"
  fi
  systemctl enable --now docker || return 1
  docker info >/dev/null
}

swap() {
  (( INSTALL_SWAP == 1 )) || { log "swap disabled in /etc/server-init.conf"; return 0; }
  # Add a disk swap file only when there is no swap at all.
  if [[ -n "$(swapon --noheadings --show=NAME)" ]]; then log "swap already present: $(swapon --noheadings --show=NAME | tr '\n' ' ')"; return 0; fi
  local mem_mb size_mb
  mem_mb=$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)
  size_mb=$(( mem_mb < 1024 ? 1024 : (mem_mb > 4096 ? 4096 : mem_mb) ))
  if [[ ! -f /swapfile ]]; then
    if [[ "$(findmnt -no FSTYPE /)" == btrfs ]]; then
      btrfs filesystem mkswapfile --size "${size_mb}m" /swapfile || return 1
    else
      # fallocate is fine on ext4 (the default); dd is the fallback if it fails or the file is rejected as swap.
      if fallocate -l "${size_mb}M" /swapfile 2>/dev/null; then
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null || return 1
        swapon /swapfile 2>/dev/null || { swapoff /swapfile 2>/dev/null || true; rm -f /swapfile; }
      else
        rm -f /swapfile
      fi
      if [[ ! -f /swapfile ]]; then
        dd if=/dev/zero of=/swapfile bs=1M count="$size_mb" status=none || return 1
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null || return 1
      fi
    fi
  fi
  [[ "$(swapon --noheadings --show=NAME)" == *"/swapfile"* ]] || swapon /swapfile || return 1
  grep -qE '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap defaults 0 0' >> /etc/fstab
}

log "start (${PRETTY_NAME:-$ID $VERSION_ID})"
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
log "open in firewall: $(ufw status 2>/dev/null | awk 'NR > 4 && NF && !/\(v6\)/ { printf "%s ", $1 }')"
if (( ${#FAILED_STEPS[@]} )); then
  log "done with failures: ${FAILED_STEPS[*]} (details: $FAILED_LOG)"
  exit 1
fi
log "done, all steps ok"
