#!/usr/bin/env bash
# Admin tools for the runner host: htop, btop, ncdu, iotop, mtr, network and disk tools, editors, restic, skopeo.
# Each package is installed on its own, so one that is missing on this release doesn't stop the rest.
# Also installs the shell aliases and, if there is none yet, the tmux config from the init. Safe to rerun.
set -Eeuo pipefail
# shellcheck source=install/lib.sh
source "$(dirname "$0")/lib.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0  installs admin tools (htop, btop, ncdu, iotop, mtr, dig, tcpdump, restic, skopeo, ...), aliases and tmux config"
  exit 0
fi
require_root

if command -v dnf >/dev/null 2>&1; then
  dnf -y -q install epel-release >/dev/null 2>&1 || log "WARN: epel-release not available, EPEL tools will be missing"
  PKGS=(htop btop ncdu iotop mtr nano vim-enhanced rsync wget unzip tar bash-completion skopeo restic dnf-utils
        bind-utils lsof sysstat tcpdump traceroute nmap-ncat jq git tmux curl)
  pkg_one() { dnf -y -q install "$1" >/dev/null 2>&1; }
elif command -v apt-get >/dev/null 2>&1; then
  apt-get update -q >/dev/null
  PKGS=(htop btop ncdu iotop mtr-tiny nano vim rsync wget unzip tar bash-completion skopeo restic
        dnsutils lsof sysstat tcpdump traceroute netcat-openbsd jq git tmux curl)
  pkg_one() { DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$1" >/dev/null 2>&1; }
else
  die "no supported package manager"
fi

installed=()
missing=()
for p in "${PKGS[@]}"; do
  if pkg_one "$p"; then
    installed+=("$p")
  else
    missing+=("$p")
  fi
done

if [[ -f /etc/default/sysstat ]]; then
  sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
fi
if systemctl cat sysstat >/dev/null 2>&1; then
  systemctl enable --now sysstat >/dev/null 2>&1 || log "WARN: could not enable sysstat collection"
fi

cat > /etc/profile.d/ci-runner.sh <<'EOF'
alias health='sudo /usr/local/bin/health'
alias runner-logs='sudo journalctl -u gitlab-runner -f'
alias runner-errors='sudo journalctl -u gitlab-runner --since "-30min" --no-pager | grep -Ei "error|warn|bottleneck"'
alias runner-jobs='sudo docker ps --filter label=com.gitlab.gitlab-runner.managed=true --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"'
alias runner-metrics='curl -s 127.0.0.1:9252/metrics | grep "^gitlab_runner_"'
alias dfd='df -h / ; sudo docker system df'
alias dstats='sudo docker stats --no-stream'
EOF
chmod 644 /etc/profile.d/ci-runner.sh
restorecon_if /etc/profile.d/ci-runner.sh

# root and every admin in the ssh-users group (install/users.sh) get the tmux config if they have none
homes=(/root)
while IFS= read -r u; do
  [[ -n "$u" ]] && homes+=("$(getent passwd "$u" | cut -d: -f6)")
done < <(getent group ssh-users | cut -d: -f4 | tr ',' '\n')
for home in "${homes[@]}"; do
  [[ -d "$home" ]] || continue
  if [[ -f "${home}/.tmux.conf" ]]; then
    log "kept existing ${home}/.tmux.conf"
    continue
  fi
  cat > "${home}/.tmux.conf" <<'EOF'
set -g mouse on
set -g history-limit 50000
set -g base-index 1
set -g status-right '#H  %H:%M'
EOF
  chown "$(stat -c '%U:%G' "$home")" "${home}/.tmux.conf"
  chmod 644 "${home}/.tmux.conf"
done

log "installed or already present (${#installed[@]}): ${installed[*]}"
if (( ${#missing[@]} )); then
  log "WARN: not available on this release (${#missing[@]}): ${missing[*]}"
fi
for c in htop btop ncdu iotop mtr dig tcpdump restic skopeo sar; do
  if command -v "$c" >/dev/null 2>&1; then printf '  %-8s ok\n' "$c"; else printf '  %-8s missing\n' "$c"; fi
done
log "OK: aliases work in new shells (or run: source /etc/profile.d/ci-runner.sh); Docker and journal aliases use sudo"
