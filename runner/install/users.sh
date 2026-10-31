#!/usr/bin/env bash
# Users and SSH access for the runner host. Self-contained (no lib.sh) so cloud-init can embed it.
#
#   admin          ops (ADMIN_USER): SSH by key, sudo without password, not in the docker group
#   gitlab-runner  service account: no shell, no password, no SSH; the runner service runs as this user
#                  with access to Docker through the docker group (root-equivalent, needed by the executor)
#   monitoring     service account: no shell, no password, no SSH; owns the monitoring and logging containers
#
# SSH: keys only, only members of ssh-users, port SSH_PORT (default 22; remembered from the existing drop-in), no agent or X11 forwarding,
# local port forwarding kept for tunnels.
# Root keeps SSH by key until --lock-root, which refuses to run while the admin has no key. With another
# SSH_PORT, sshd listens on 22 and SSH_PORT until --lock-root, which then closes 22. A locked server stays
# locked on rerun unless --unlock-root is given. Safe to rerun.
set -Eeuo pipefail

ADMIN_USER="${ADMIN_USER:-ops}"
MON_USER="${MON_USER:-monitoring}"
RUNNER_USER=gitlab-runner
SSH_GROUP="${SSH_GROUP:-ssh-users}"
DROPIN=/etc/ssh/sshd_config.d/00-ci-hardening.conf
# SSH_PORT from the environment wins; otherwise the port written by the previous run is kept, so a rerun,
# --lock-root and --unlock-root never fall back to 22 on a host that listens elsewhere.
if [[ -z "${SSH_PORT:-}" ]]; then
  SSH_PORT=$(awk 'tolower($1) == "port" && $2 != 22 { p = $2 } END { print p }' "$DROPIN" 2>/dev/null || true)
fi
SSH_PORT="${SSH_PORT:-22}"
RUNNER_DROPIN=/etc/systemd/system/gitlab-runner.service.d/10-service-user.conf
RUNNER_CFG=/etc/gitlab-runner/config.toml
LOCK_ROOT=0
UNLOCK_ROOT=0
RELOAD=1

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 [--lock-root | --unlock-root] [--no-reload]

Creates the admin user (ADMIN_USER, default ops), the service
accounts (${MON_USER}, ${RUNNER_USER} if installed), the ${SSH_GROUP} group and the SSH drop-in ${DROPIN}.
The admin gets the keys from /root/.ssh/authorized_keys.

  --lock-root    close root SSH (and port 22 when SSH_PORT is another port). Run it only after
                 "ssh ADMIN@server sudo -n true" works from your laptop.
  --unlock-root  undo --lock-root (root by key again)
  --no-reload    write the config but do not reload sshd or restart gitlab-runner

Env: ADMIN_USER, MON_USER (default monitoring), SSH_GROUP (default ssh-users),
     SSH_PORT (default 22, or the port already in ${DROPIN}; give it once, reruns keep it)
Rollback: delete ${DROPIN} and ${RUNNER_DROPIN}, then: systemctl reload sshd; systemctl daemon-reload; systemctl restart gitlab-runner
USAGE
}

while (( $# )); do
  case "$1" in
    --lock-root) LOCK_ROOT=1 ;;
    --unlock-root) UNLOCK_ROOT=1 ;;
    --no-reload) RELOAD=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "run as root (sudo $0)"
# cmp (diffutils) is missing on minimal hosts; this script is self-contained, so it installs it itself.
if ! command -v cmp >/dev/null 2>&1; then { dnf -y -q install diffutils || apt-get install -y -q diffutils; } >/dev/null 2>&1 || die "cmp missing and diffutils not installable"; fi
(( LOCK_ROOT && UNLOCK_ROOT )) && die "--lock-root and --unlock-root exclude each other"
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then die "invalid SSH_PORT: ${SSH_PORT}"; fi
[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid ADMIN_USER: '${ADMIN_USER}'"
[[ "$ADMIN_USER" != root && "$ADMIN_USER" != "$MON_USER" && "$ADMIN_USER" != "$RUNNER_USER" ]] || die "ADMIN_USER must be a separate user"

NOLOGIN=$(command -v nologin || true)
[[ -n "$NOLOGIN" ]] || NOLOGIN=/sbin/nologin
if getent group wheel >/dev/null; then
  SUDO_GROUP=wheel
elif getent group sudo >/dev/null; then
  SUDO_GROUP=sudo
else
  die "neither wheel nor sudo group exists"
fi
command -v visudo >/dev/null || die "sudo is not installed"

# --- admin -------------------------------------------------------------------------------------
getent group "$SSH_GROUP" >/dev/null || groupadd -r "$SSH_GROUP"
if id "$ADMIN_USER" >/dev/null 2>&1; then
  usermod -aG "${SUDO_GROUP},${SSH_GROUP}" "$ADMIN_USER"
else
  useradd -m -s /bin/bash -G "${SUDO_GROUP},${SSH_GROUP}" -c "server admin" "$ADMIN_USER"
  log "created admin user ${ADMIN_USER}"
fi
# "!" (locked) can block key logins when sshd runs without PAM; "*" means no password, key login allowed.
if [[ "$(getent shadow "$ADMIN_USER" | cut -d: -f2)" == !* ]]; then
  usermod -p '*' "$ADMIN_USER"
fi
if id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx docker; then
  gpasswd -d "$ADMIN_USER" docker >/dev/null
  log "removed ${ADMIN_USER} from the docker group (root-equivalent); use sudo docker"
fi

sudoers="/etc/sudoers.d/90-${ADMIN_USER}"
tmp=$(mktemp)
# secure_path: the Rocky default can leave out /usr/local/bin, where health and the cleanup scripts live.
printf '%s ALL=(ALL) NOPASSWD:ALL\nDefaults:%s secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n' \
  "$ADMIN_USER" "$ADMIN_USER" > "$tmp"
visudo -cqf "$tmp" || { rm -f "$tmp"; die "generated sudoers file is invalid"; }
install -m 0440 -o root -g root "$tmp" "$sudoers"
rm -f "$tmp"

home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
group=$(id -gn "$ADMIN_USER")
ak="${home}/.ssh/authorized_keys"
install -d -m 0700 -o "$ADMIN_USER" -g "$group" "${home}/.ssh"
touch "$ak"
if [[ -f /root/.ssh/authorized_keys ]]; then
  # Plain key lines only: lines with options (for example cloud-init's "Please login as" command=) are skipped.
  while IFS= read -r line; do
    grep -qxF -- "$line" "$ak" || printf '%s\n' "$line" >> "$ak"
  done < <(grep -E '^(ssh-(ed25519|rsa)|ecdsa-sha2-|sk-)' /root/.ssh/authorized_keys || true)
fi
chown "$ADMIN_USER:$group" "$ak"
chmod 0600 "$ak"
if [[ -f /root/.tmux.conf && ! -f "${home}/.tmux.conf" ]]; then
  install -m 0644 -o "$ADMIN_USER" -g "$group" /root/.tmux.conf "${home}/.tmux.conf"
fi
if command -v restorecon >/dev/null 2>&1; then restorecon -R "${home}/.ssh" || true; fi
keys=$(grep -cE '^(ssh-|ecdsa-|sk-)' "$ak" || true)
log "admin ${ADMIN_USER}: groups $(id -nG "$ADMIN_USER" | tr ' ' ','), ${keys:-0} SSH key(s), sudo without password"

# --- service accounts --------------------------------------------------------------------------
if ! id "$MON_USER" >/dev/null 2>&1; then
  useradd -r -U -M -d /nonexistent -s "$NOLOGIN" -c "monitoring and logging containers" "$MON_USER"
  log "created service user ${MON_USER}"
fi
usermod -s "$NOLOGIN" "$MON_USER" >/dev/null 2>&1 || true
log "service ${MON_USER}: uid $(id -u "$MON_USER"), gid $(id -g "$MON_USER"), shell ${NOLOGIN}"

if id "$RUNNER_USER" >/dev/null 2>&1; then
  usermod -s "$NOLOGIN" "$RUNNER_USER" >/dev/null 2>&1 || true
  usermod -L "$RUNNER_USER" 2>/dev/null || true
  getent group docker >/dev/null && usermod -aG docker "$RUNNER_USER"
  install -d -m 0755 "$(dirname "$RUNNER_DROPIN")"
  cat > "${RUNNER_DROPIN}.new" <<'EOF'
# Run the runner service as its own user instead of root. Docker access comes from the docker group.
[Service]
User=gitlab-runner
Group=gitlab-runner
SupplementaryGroups=docker
ExecStart=
ExecStart=/usr/bin/gitlab-runner run --working-directory /home/gitlab-runner --config /etc/gitlab-runner/config.toml --service gitlab-runner
EOF
  changed=0
  if ! cmp -s "${RUNNER_DROPIN}.new" "$RUNNER_DROPIN" 2>/dev/null; then
    mv "${RUNNER_DROPIN}.new" "$RUNNER_DROPIN"
    chmod 0644 "$RUNNER_DROPIN"
    changed=1
  else
    rm -f "${RUNNER_DROPIN}.new"
  fi
  # The service reads and rewrites config.toml (token, system id), so it owns /etc/gitlab-runner and its home.
  install -d -m 0700 -o "$RUNNER_USER" -g "$RUNNER_USER" /etc/gitlab-runner
  chown -R "$RUNNER_USER:$RUNNER_USER" /etc/gitlab-runner
  if [[ -f "$RUNNER_CFG" ]]; then chmod 0600 "$RUNNER_CFG"; fi
  install -d -m 0750 -o "$RUNNER_USER" -g "$RUNNER_USER" "/home/${RUNNER_USER}"
  chown -R "$RUNNER_USER:$RUNNER_USER" "/home/${RUNNER_USER}"
  if command -v restorecon >/dev/null 2>&1; then restorecon -R /etc/gitlab-runner "$(dirname "$RUNNER_DROPIN")" || true; fi
  if (( RELOAD )); then
    systemctl daemon-reload
    restart=0
    if (( changed )) || [[ "$(ps -o user= -p "$(systemctl show -p MainPID --value gitlab-runner)" 2>/dev/null | tr -d ' ')" != "$RUNNER_USER" ]]; then
      restart=1
    fi
    if (( restart )); then
      main_pid=$(systemctl show -p MainPID --value gitlab-runner)
      if [[ "${main_pid:-0}" == 0 ]]; then
        # Stopped service: nothing to interrupt, and the idle gate would only block the start.
        systemctl start gitlab-runner
        sleep 3
      elif ! job_ids=$(docker ps -q --filter "label=com.gitlab.gitlab-runner.managed=true" 2>/dev/null); then
        # A docker failure is not "0 jobs": restarting could kill running CI jobs.
        log "WARN: cannot confirm that no CI job is running (docker does not answer), gitlab-runner not restarted; check with: docker ps --filter label=com.gitlab.gitlab-runner.managed=true, then: systemctl restart gitlab-runner"
      elif [[ -n "$job_ids" ]]; then
        log "WARN: $(wc -w <<<"$job_ids") CI job(s) running, gitlab-runner not restarted; run: systemctl restart gitlab-runner"
      else
        systemctl restart gitlab-runner
        sleep 3
      fi
    fi
    pid=$(systemctl show -p MainPID --value gitlab-runner)
    if [[ "${pid:-0}" != 0 ]]; then
      log "service ${RUNNER_USER}: runner process runs as $(ps -o user= -p "$pid" | tr -d ' ') (groups: $(ps -o supgrp= -p "$pid" | tr -d ' '))"
    else
      log "WARN: gitlab-runner is not running: journalctl -u gitlab-runner -n 30"
    fi
  fi
else
  log "${RUNNER_USER} not installed yet, rerun this script after installing GitLab Runner"
fi

# --- SSH ---------------------------------------------------------------------------------------
# A server that is already locked stays locked, so a rerun never reopens root or port 22 by accident.
if (( ! LOCK_ROOT && ! UNLOCK_ROOT )) && grep -qsx 'PermitRootLogin no' "$DROPIN"; then
  LOCK_ROOT=1
  log "keeping the existing root lock (use --unlock-root to undo it)"
fi
if (( LOCK_ROOT )) && (( ${keys:-0} == 0 )); then
  die "--lock-root refused: ${ADMIN_USER} has no SSH key, root would be the only way in"
fi
if (( LOCK_ROOT )); then
  root_login=no
  allow="AllowGroups ${SSH_GROUP}"
  ports="Port ${SSH_PORT}"
else
  root_login=prohibit-password
  allow="AllowGroups ${SSH_GROUP} root"
  ports="Port 22"
  if [[ "$SSH_PORT" != 22 ]]; then ports+=$'\n'"Port ${SSH_PORT}"; fi
fi

# SELinux only lets sshd bind ports labeled ssh_port_t; firewalld (if active) must allow the port too.
if [[ "$SSH_PORT" != 22 ]] && command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; then
  command -v semanage >/dev/null 2>&1 || die "semanage missing: install policycoreutils-python-utils"
  if ! semanage port -l | awk '$1 == "ssh_port_t" { for (i = 3; i <= NF; i++) print $i }' | tr -d ',' | grep -qx "$SSH_PORT"; then
    semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" 2>/dev/null || semanage port -m -t ssh_port_t -p tcp "$SSH_PORT"
    log "SELinux: port ${SSH_PORT} labeled ssh_port_t"
  fi
fi
if systemctl is-active --quiet firewalld 2>/dev/null; then
  if [[ "$SSH_PORT" == 22 ]] && firewall-cmd -q --permanent --zone=public --query-service=ssh; then
    log "firewalld: port 22 is covered by the ssh service"   # no extra 22/tcp rule: it would differ from the first run
  else
    firewall-cmd -q --permanent --add-port="${SSH_PORT}/tcp" && firewall-cmd -q --reload
    log "firewalld: port ${SSH_PORT}/tcp allowed"
  fi
fi
# Debian runner hosts get ufw from host-firewall.sh: the new port must be open there too, or sshd listens on a port the
# firewall drops (and --lock-root, which closes port 22, would then lock you out).
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow "${SSH_PORT}/tcp" >/dev/null || die "cannot allow ${SSH_PORT}/tcp in ufw"
  log "ufw: port ${SSH_PORT}/tcp allowed"
fi
# Add this port to the fail2ban sshd jail written by host-firewall.sh.
JAIL_FILE="${JAIL_FILE:-/etc/fail2ban/jail.d/50-sshd.local}"
if [[ -f "$JAIL_FILE" ]] && grep -q '^port ' "$JAIL_FILE" && ! grep -E '^port ' "$JAIL_FILE" | tr -c '0-9\n' ' ' | tr ' ' '\n' | grep -qx "$SSH_PORT"; then
  sed -i -E "s/^(port[[:space:]]*=[[:space:]]*.*)\$/\1,${SSH_PORT}/" "$JAIL_FILE"
  systemctl reload fail2ban >/dev/null 2>&1 || systemctl restart fail2ban >/dev/null 2>&1 || true
  log "fail2ban: sshd jail now also watches port ${SSH_PORT}"
fi
# Never write a config that leaves SSH only on a port the running host firewall drops.
if [[ "$SSH_PORT" != 22 ]]; then
  if systemctl is-active --quiet firewalld 2>/dev/null && ! firewall-cmd --query-port="${SSH_PORT}/tcp" >/dev/null 2>&1; then
    die "firewalld does not allow ${SSH_PORT}/tcp in the running rules; sshd config left unchanged"
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active' \
     && ! ufw status 2>/dev/null | grep -qE "^${SSH_PORT}/tcp([[:space:]]+\(v6\))?[[:space:]]+(ALLOW|LIMIT)"; then
    die "ufw does not allow ${SSH_PORT}/tcp in the running rules; sshd config left unchanged"
  fi
fi
[[ -d /etc/ssh/sshd_config.d ]] || die "/etc/ssh/sshd_config.d missing (OpenSSH too old for drop-ins?)"
grep -qiE '^\s*Include\s+/etc/ssh/sshd_config.d/' /etc/ssh/sshd_config || die "/etc/ssh/sshd_config does not include sshd_config.d"

new="${DROPIN}.new"
cat > "$new" <<EOF
# Managed by runner/install/users.sh. First match wins in sshd, so this file is named 00- to load first.
${ports}
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin ${root_login}
${allow}
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding local
PermitTunnel no
EOF
chmod 0600 "$new"
old_backup=""
if [[ -f "$DROPIN" ]] && cmp -s "$new" "$DROPIN"; then
  rm -f "$new"   # same content: no backup, no rewrite, a rerun leaves the managed state untouched
else
  if [[ -f "$DROPIN" ]]; then
    old_backup="${DROPIN}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$DROPIN" "$old_backup"
  fi
  mv "$new" "$DROPIN"
fi
legacy=/etc/ssh/sshd_config.d/60-ci-hardening.conf
[[ -f "$legacy" ]] && mv "$legacy" "${legacy}.disabled"
if command -v restorecon >/dev/null 2>&1; then restorecon /etc/ssh/sshd_config.d/* 2>/dev/null || true; fi

sshd_bin=$(command -v sshd || echo /usr/sbin/sshd)
if ! "$sshd_bin" -t; then
  if [[ -n "$old_backup" ]]; then mv "$old_backup" "$DROPIN"; else rm -f "$DROPIN"; fi
  [[ -f "${legacy}.disabled" ]] && mv "${legacy}.disabled" "$legacy"
  die "sshd rejected the new config, previous config restored"
fi
if (( RELOAD )); then
  if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    # Socket activation (Ubuntu, some Debian setups): the socket generator reads Port from sshd_config.
    systemctl daemon-reload
    systemctl restart ssh.socket
  elif systemctl cat sshd >/dev/null 2>&1; then
    systemctl reload sshd
  else
    systemctl reload ssh
  fi
fi
effective=$("$sshd_bin" -T 2>/dev/null | grep -Ei '^(port|permitrootlogin|passwordauthentication|allowgroups|allowtcpforwarding) ' | tr '\n' ';' || true)
log "sshd: ${effective}"

port_opt=""
if [[ "$SSH_PORT" != 22 ]]; then port_opt="-p ${SSH_PORT} "; fi
if (( LOCK_ROOT )); then
  log "OK: root SSH closed. Log in as: ssh ${port_opt}${ADMIN_USER}@<server>"
else
  if [[ -n "$port_opt" ]]; then log "OK: allow TCP ${SSH_PORT} in the Hetzner Firewall first"; fi
  log "OK: test from your laptop:  ssh ${port_opt}${ADMIN_USER}@<server> 'sudo -n true && echo sudo works'"
  log "    then lock root:         sudo $0 --lock-root"
fi
