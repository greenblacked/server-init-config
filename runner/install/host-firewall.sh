#!/usr/bin/env bash
# Host firewall and fail2ban for the runner host: firewalld on Rocky/Alma/CentOS, ufw on Debian/Ubuntu.
# Self-contained (no lib.sh) so cloud-init can embed it. Safe to rerun.
#
# Nothing is opened except SSH (22 and every port sshd listens on) and, when Grafana is published on a domain
# (override file exists), 80/443. Services of the host
# (monitoring, logging, caches) listen on 127.0.0.1 or the docker0 IP and need no rule. Lockout guard, as in
# server/server-init-*.sh: the firewall is only started or enabled when SSH is in the saved rules, and it is
# stopped again when SSH is not allowed in the running rules. Also open the same ports in the Hetzner Cloud Firewall.
#
# Docker keeps working: on Rocky firewalld puts docker0 into its own docker zone when Docker starts after firewalld;
# if Docker was already running, this script moves docker0 into that zone (no Docker restart). On Debian
# ufw does not touch the chains Docker manages. Jobs are kept away from the host by ci-job-isolation.sh.
# fail2ban: sshd jail on the journal, 5 tries in 10 minutes, 1 hour ban.
set -Eeuo pipefail

JAIL_FILE="${JAIL_FILE:-/etc/fail2ban/jail.d/50-sshd.local}"   # overridable for tests
GRAFANA_OVERRIDE="${GRAFANA_OVERRIDE:-/opt/monitoring/docker-compose.override.yml}"   # exists once grafana-domain.sh ran

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0   enables firewalld (Rocky) or ufw (Debian) with SSH allowed, plus the fail2ban sshd jail"
  exit 0
fi
[[ $EUID -eq 0 ]] || die "run as root"

web_published() { [[ -f "$GRAFANA_OVERRIDE" ]]; }

ssh_ports() {
  { echo 22; sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }'; } | sort -un
}

put_jail() {
  local banaction="$1" tmp ports
  ports=$(ssh_ports | paste -sd, -)   # the jail must watch every port sshd listens on, not only 22
  tmp=$(mktemp)
  {
    if [[ -n "$banaction" ]]; then
      printf '[DEFAULT]\nbanaction = %s\nbanaction_allports = %s[type=allports]\n\n' "$banaction" "$banaction"
    fi
    printf '[sshd]\nenabled  = true\nport     = %s\nbackend  = systemd\nmaxretry = 5\nfindtime = 10m\nbantime  = 1h\n' "$ports"
  } > "$tmp"
  install -D -m 0644 "$tmp" "$JAIL_FILE"
  rm -f "$tmp"
  if command -v restorecon >/dev/null 2>&1; then restorecon "$JAIL_FILE" || true; fi
}

firewalld_setup() {
  local running=0 p zone set_zone
  command -v firewall-cmd >/dev/null 2>&1 || dnf -y -q install firewalld || die "cannot install firewalld"
  systemctl is-active --quiet firewalld && running=1
  # SSH is allowed in the public zone, so the uplink must be in it: make it the default zone (as server-init does).
  if (( running )); then zone=$(firewall-cmd --get-default-zone) || die "cannot read the default zone"; else zone=$(firewall-offline-cmd --get-default-zone) || die "cannot read the default zone"; fi
  # Running: the default zone is switched after the reload, so SSH is never refused in between.
  set_zone=0
  if [[ "$zone" != public ]]; then
    log "firewalld: default zone was ${zone}, set to public"
    if (( running )); then set_zone=1; else firewall-offline-cmd --set-default-zone=public >/dev/null || die "cannot set the default zone"; fi
  fi
  # Permanent rules are written first (offline when firewalld is stopped), then the daemon is started or reloaded.
  fw() { if systemctl is-active --quiet firewalld; then firewall-cmd --permanent "$@"; else firewall-offline-cmd "$@"; fi; }
  fw --zone=public --query-service=ssh >/dev/null 2>&1 || fw --zone=public --add-service=ssh >/dev/null || die "cannot add ssh to the public zone"
  for p in $(ssh_ports); do
    [[ "$p" == 22 ]] && continue
    fw --zone=public --query-port="${p}/tcp" >/dev/null 2>&1 || fw --zone=public --add-port="${p}/tcp" >/dev/null || die "cannot add port ${p}"
  done
  if web_published; then
    for p in http https; do
      fw --zone=public --query-service="$p" >/dev/null 2>&1 || fw --zone=public --add-service="$p" >/dev/null || die "cannot add ${p} to the public zone"
    done
    log "firewalld: http and https kept open (Grafana is published on a domain)"
  fi
  # Lockout guard: the saved rules must allow SSH before the firewall runs.
  fw --zone=public --query-service=ssh >/dev/null 2>&1 || die "ssh missing from the saved public zone; firewall left as it was"
  for p in $(ssh_ports); do
    [[ "$p" == 22 ]] && continue
    fw --zone=public --query-port="${p}/tcp" >/dev/null 2>&1 || die "port ${p} missing from the saved public zone; firewall left as it was"
  done
  if (( running )); then firewall-cmd --reload >/dev/null || die "firewalld reload failed"; else systemctl enable --now firewalld || die "firewalld did not start"; fi
  systemctl enable firewalld >/dev/null 2>&1 || true
  if (( set_zone )); then firewall-cmd --set-default-zone=public >/dev/null || die "cannot set the default zone"; fi
  if ! firewall-cmd --zone=public --query-service=ssh >/dev/null; then
    systemctl stop firewalld
    die "ssh not allowed after start; firewalld stopped"
  fi
  for p in $(ssh_ports); do
    [[ "$p" == 22 ]] && continue
    if ! firewall-cmd --zone=public --query-port="${p}/tcp" >/dev/null; then
      systemctl stop firewalld
      die "ssh port ${p} not allowed after start; firewalld stopped"
    fi
  done
  log "firewalld: active, public zone: $(firewall-cmd --zone=public --list-services) $(firewall-cmd --zone=public --list-ports)"
  docker_zone
}

# Docker that was running before firewalld left docker0 in the default zone, where firewalld rejects job traffic to
# the host (the npm cache on the docker0 address). Put docker0 into the docker zone (target ACCEPT, as Docker makes it),
# permanently and now, without restarting Docker. iptables rules (ci-job-isolation.sh) still apply on top.
docker_zone() {
  command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker || return 0
  ip link show docker0 >/dev/null 2>&1 || return 0
  [[ "$(firewall-cmd --get-zone-of-interface=docker0 2>/dev/null)" == docker ]] && return 0
  if ! firewall-cmd --permanent --get-zones | tr ' ' '\n' | grep -qx docker; then
    firewall-cmd --permanent --new-zone=docker >/dev/null && firewall-cmd --permanent --zone=docker --set-target=ACCEPT >/dev/null \
      && firewall-cmd --reload >/dev/null || { log "WARN: cannot create the firewalld docker zone; restart Docker while no CI job runs: systemctl restart docker"; return 0; }
  fi
  if firewall-cmd --permanent --zone=docker --add-interface=docker0 >/dev/null && firewall-cmd --zone=docker --change-interface=docker0 >/dev/null; then
    log "firewalld: docker0 put into the docker zone"
  else
    log "WARN: docker0 is not in the docker zone; restart Docker while no CI job runs: systemctl restart docker"
  fi
}

ufw_setup() {
  local p o was_active=0
  command -v ufw >/dev/null 2>&1 || { DEBIAN_FRONTEND=noninteractive apt-get install -y -q ufw >/dev/null || die "cannot install ufw"; }
  o=$(ufw status 2>/dev/null) || true
  if grep -q '^Status: active' <<<"$o"; then was_active=1; fi
  for p in $(ssh_ports); do ufw allow "${p}/tcp" >/dev/null || die "cannot allow ${p}/tcp"; done
  if web_published; then
    ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null || die "cannot allow 80/443 in ufw"
    log "ufw: 80/tcp and 443/tcp kept open (Grafana is published on a domain)"
  fi
  # Lockout guard: every SSH port must be in the saved rules before ufw is enabled.
  o=$(ufw show added 2>/dev/null) || true
  for p in $(ssh_ports); do
    grep -qE "^ufw (allow|limit) (in )?${p}/tcp([[:space:]]|\$)" <<<"$o" || die "${p}/tcp missing from the saved ufw rules; ufw left as it was"
  done
  if (( ! was_active )); then
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw --force enable >/dev/null
  fi
  systemctl enable ufw >/dev/null 2>&1 || true
  o=$(ufw status 2>/dev/null) || true
  for p in $(ssh_ports); do
    if ! grep -qE "^${p}/tcp([[:space:]]+\\(v6\\))?[[:space:]]+(ALLOW|LIMIT)" <<<"$o"; then
      if (( ! was_active )); then ufw disable >/dev/null 2>&1 || true; fi
      die "ssh port ${p} not allowed in the running ufw; ufw disabled again"
    fi
  done
  log "ufw: $(ufw status | head -1); allowed: $(ssh_ports | tr '\n' ' ')"
}

# FIREWALL_BACKEND=firewalld|ufw overrides the choice by package manager (used by the tests).
backend="${FIREWALL_BACKEND:-}"
if [[ -z "$backend" ]]; then
  if command -v dnf >/dev/null 2>&1; then backend=firewalld; elif command -v apt-get >/dev/null 2>&1; then backend=ufw; fi
fi

if [[ "$backend" == firewalld ]]; then
  dnf -y -q install epel-release >/dev/null 2>&1 || true
  dnf -y -q install fail2ban-server fail2ban-firewalld >/dev/null 2>&1 || log "WARN: fail2ban not available (EPEL?), sshd jail skipped"
  firewalld_setup
  if command -v fail2ban-client >/dev/null 2>&1; then
    put_jail ""
    systemctl enable --now fail2ban >/dev/null && systemctl restart fail2ban
  fi
elif [[ "$backend" == ufw ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q fail2ban >/dev/null 2>&1 || log "WARN: fail2ban not installed, sshd jail skipped"
  ufw_setup
  if command -v fail2ban-client >/dev/null 2>&1; then
    put_jail nftables
    systemctl enable --now fail2ban >/dev/null && systemctl restart fail2ban
  fi
else
  die "no supported package manager"
fi
if command -v fail2ban-client >/dev/null 2>&1; then
  log "fail2ban: $(fail2ban-client status 2>/dev/null | tr '\n' ' ' || true)"
fi
log "OK: host firewall on. If you lock yourself out, use the Hetzner web console: systemctl stop firewalld (or: ufw disable)"
