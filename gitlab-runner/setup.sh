#!/usr/bin/env bash
# One entry point for the runner host: installs the components of this repo in the right order.
# Run as root on the server, from a full copy of the repo (for example /root/server-init-config).
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
CFG=/etc/gitlab-runner/config.toml
CURRENT=""

COMPONENTS=(users packages tools register registry-cache monitoring logging npm-cache shared-cache prewarm grafana-domain selinux lock-root)

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

describe() {
  case "$1" in
    users)          echo "admin user ops (sudo), service users gitlab-runner and monitoring, SSH on port 22022" ;;
    packages)       echo "admin tools: htop, btop, ncdu, iotop, mtr, dig, tcpdump, restic, skopeo, aliases" ;;
    tools)          echo "health, weekly cleanup, disk guard and their timers" ;;
    register)       echo "register the runner (asks for the glrt- token)" ;;
    registry-cache) echo "Docker Hub pull-through cache on 127.0.0.1:5000" ;;
    monitoring)     echo "Prometheus, node_exporter, Grafana (127.0.0.1 only)" ;;
    logging)        echo "Loki + Grafana Alloy: container logs and the journal in Grafana" ;;
    npm-cache)      echo "Verdaccio npm cache for CI jobs" ;;
    shared-cache)   echo "shared /srv/ci-cache for npm and Sonar, mounted into jobs" ;;
    prewarm)        echo "daily pre-pull of CI images (asks for a deploy token)" ;;
    grafana-domain) echo "Grafana on an HTTPS domain via Caddy (needs DOMAIN and ACME_EMAIL)" ;;
    selinux)        echo "switch SELinux to enforcing and verify Docker and the runner" ;;
    lock-root)      echo "close root SSH and port 22; only after the admin login on port 22022 works" ;;
  esac
}

script_for() {
  case "$1" in
    users)          echo "${ROOT}/install/users.sh" ;;
    packages)       echo "${ROOT}/install/admin-tools.sh" ;;
    tools)          echo "${ROOT}/install/host-tools.sh" ;;
    register)       echo "${HERE}/register.sh" ;;
    registry-cache) echo "${ROOT}/install/registry-cache.sh" ;;
    monitoring)     echo "${ROOT}/install/monitoring.sh" ;;
    logging)        echo "${ROOT}/install/logging.sh" ;;
    npm-cache)      echo "${ROOT}/install/npm-cache.sh" ;;
    shared-cache)   echo "${ROOT}/install/shared-cache.sh" ;;
    prewarm)        echo "${ROOT}/install/image-prewarm.sh" ;;
    grafana-domain) echo "${ROOT}/install/grafana-domain.sh" ;;
    selinux)        echo "${ROOT}/install/selinux-enforcing.sh" ;;
    lock-root)      echo "${ROOT}/install/lock-root.sh" ;;
  esac
}

is_component() {
  local c
  for c in "${COMPONENTS[@]}"; do
    if [[ "$c" == "$1" ]]; then
      return 0
    fi
  done
  return 1
}

is_installed() {
  case "$1" in
    users)          id monitoring >/dev/null 2>&1 && grep -qs "^AllowGroups" /etc/ssh/sshd_config.d/00-ci-hardening.conf ;;
    packages)       command -v htop >/dev/null 2>&1 && [[ -f /etc/profile.d/ci-runner.sh ]] ;;
    tools)          [[ -x /usr/local/bin/health && -x /usr/local/bin/runner-weekly-cleanup.sh ]] ;;
    register)       [[ -f "$CFG" ]] && grep -q '^\[\[runners\]\]' "$CFG" ;;
    registry-cache) [[ -f /opt/registry-cache/docker-compose.yml ]] ;;
    monitoring)     [[ -f /opt/monitoring/docker-compose.yml ]] ;;
    logging)        [[ -f /opt/logging/docker-compose.yml ]] ;;
    npm-cache)      [[ -f /opt/npm-cache/docker-compose.yml ]] ;;
    shared-cache)   [[ -f "$CFG" ]] && grep -q '/srv/ci-cache:/ci-cache' "$CFG" ;;
    prewarm)        [[ -f /etc/ci-prewarm.conf ]] ;;
    grafana-domain) [[ -f /opt/monitoring/docker-compose.override.yml ]] ;;
    lock-root)      grep -qsx "PermitRootLogin no" /etc/ssh/sshd_config.d/00-ci-hardening.conf ;;
    selinux)        command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == Enforcing ]] ;;
    *)              return 1 ;;
  esac
}

usage() {
  local c
  cat <<USAGE
Usage: $0 [--base] [--all] [--list] [--COMPONENT ...]

  --base   users + packages + tools + registry-cache + monitoring (no questions asked)
  --all    --base + register + logging + npm-cache + shared-cache (asks for the runner token)
           lock-root is never implied: run --lock-root after the admin login works
  --list   show what is installed and exit

Components, installed in this order whatever the order of the flags:
USAGE
  for c in "${COMPONENTS[@]}"; do
    printf '  --%-15s %s\n' "$c" "$(describe "$c")"
  done
  cat <<USAGE

Components that are already installed are skipped; refresh them with install/update.sh.
Examples:
  $0 --register
  $0 --npm-cache --shared-cache
  DOMAIN=grafana.example.com ACME_EMAIL=you@example.com $0 --grafana-domain
USAGE
}

list_components() {
  local c state
  for c in "${COMPONENTS[@]}"; do
    if is_installed "$c"; then
      state="installed"
    else
      state="-"
    fi
    printf '%-15s %-10s %s\n' "$c" "$state" "$(describe "$c")"
  done
}

preflight() {
  [[ $EUID -eq 0 ]] || die "run as root"
  [[ -d "${ROOT}/install" && -d "${ROOT}/scripts" && -d "${ROOT}/systemd" ]] \
    || die "incomplete copy: the whole repository is needed, not only the gitlab-runner folder"
  command -v docker >/dev/null || die "docker is not installed yet; wait for 'cloud-init status --wait' and read /var/log/cloud-init-output.log"
  command -v gitlab-runner >/dev/null || die "gitlab-runner is not installed yet; see /var/log/cloud-init-output.log"
  systemctl is-active --quiet docker || die "docker is not running"

  if [[ -n "${WANT[grafana-domain]:-}" ]]; then
    [[ -n "${DOMAIN:-}" && -n "${ACME_EMAIL:-}" ]] || die "--grafana-domain needs DOMAIN and ACME_EMAIL in the environment"
    if ! is_installed monitoring && [[ -z "${WANT[monitoring]:-}" ]]; then
      die "--grafana-domain needs monitoring: add --monitoring"
    fi
  fi
  local c
  for c in monitoring logging; do
    if [[ -n "${WANT[$c]:-}" ]] && ! is_installed users && [[ -z "${WANT[users]:-}" ]]; then
      die "--${c} runs as the monitoring service user: add --users"
    fi
  done
  for c in npm-cache shared-cache; do
    if [[ -n "${WANT[$c]:-}" ]] && ! is_installed register && [[ -z "${WANT[register]:-}" ]]; then
      die "--${c} needs a registered runner: add --register"
    fi
  done
}

run_component() {
  local name="$1"
  if is_installed "$name"; then
    log "${name}: already installed, skipping (refresh with install/update.sh)"
    return 0
  fi
  CURRENT="$name"
  local script
  script="$(script_for "$name")"
  [[ -f "$script" ]] || die "${name}: ${script} is missing, copy the full repository again"
  log "=== ${name}: $(describe "$name") ==="
  bash "$script"
  log "${name}: done"
  CURRENT=""
}

declare -A WANT=()
LIST=0

main() {
  local c
  while (( $# )); do
    case "$1" in
      --base) for c in users packages tools registry-cache monitoring; do WANT[$c]=1; done ;;
      --all)  for c in users packages tools register registry-cache monitoring logging npm-cache shared-cache; do WANT[$c]=1; done ;;
      --list) LIST=1 ;;
      -h|--help) usage; exit 0 ;;
      --*)
        c="${1#--}"
        is_component "$c" || { usage >&2; die "unknown option: $1"; }
        WANT[$c]=1
        ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
    shift
  done

  if (( LIST )); then
    list_components
    exit 0
  fi
  if (( ${#WANT[@]} == 0 )); then
    usage
    exit 1
  fi

  trap 'log "ERROR: step ${CURRENT:-preflight} failed (line ${LINENO}). Fix the cause and rerun the same command; finished components are skipped."' ERR
  preflight
  for c in "${COMPONENTS[@]}"; do
    if [[ -n "${WANT[$c]:-}" ]]; then
      run_component "$c"
    fi
  done

  if [[ -x /usr/local/bin/health ]]; then
    log "health check"
    /usr/local/bin/health -q --no-color || log "health exit code $? (1 = warnings, 2 = failures)"
  fi
  if is_installed monitoring; then
    log "Grafana: ssh -N -L 3000:127.0.0.1:3000 root@<server-ip>, then http://localhost:3000 (password: grep GF_SECURITY_ADMIN_PASSWORD /opt/monitoring/.env)"
  fi
}

main "$@"
