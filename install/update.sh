#!/usr/bin/env bash
# Bring a server built from this repo up to the current repo state, for the installed components only.
# Syncs scripts, systemd units and stack configs. Never touches secrets (.env, config.toml, tokens),
# the runner registration, daemon.json or SSH settings.
set -Eeuo pipefail
# shellcheck source=install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BACKUP_ROOT=/var/backups/server-init-config
KEEP_BACKUPS=5
BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"
LOCK=/run/lock/server-init-update.lock
DRYRUN=0
DO_OS=0
DO_PULL=0
DO_ROLLBACK=0
CHANGED=()
SKIPPED=()
WORK=""

usage() {
  cat <<USAGE
Usage: $0 [--dry-run] [--pull] [--os] [--rollback]

Updates what is installed on this server to the state of this repo checkout:
  host tools     health, cleanup, disk guard (+ prewarm if configured) and their systemd units
  monitoring     /opt/monitoring (Prometheus, Grafana, node_exporter, Caddy override if present)
  logging        /opt/logging (Loki, Grafana Alloy)
  registry-cache /opt/registry-cache
  npm-cache      /opt/npm-cache
Components that are not installed are skipped.

  -n, --dry-run  show what would change, change nothing
      --pull     git pull --ff-only in this checkout first (needs a git clone, not an scp copy)
      --os       also upgrade OS packages (Docker, GitLab Runner included); never reboots
      --rollback restore the files from the newest backup in ${BACKUP_ROOT} and recreate the stacks

Steps that restart Docker-based caches or upgrade packages are skipped while CI jobs are running
and the script exits with code 3; rerun it when the runner is idle.
Every changed file is first copied to ${BACKUP_ROOT}/<timestamp>/ (last ${KEEP_BACKUPS} runs are kept).
USAGE
}

run() {
  if (( DRYRUN )); then
    log "[dry-run] $*"
  else
    "$@"
  fi
}

backup_to_run() {
  local dst="$1"
  [[ -e "$dst" ]] || return 0
  install -d -m 0700 "$BACKUP_ROOT"
  install -d "${BACKUP_DIR}$(dirname "$dst")"
  cp -a "$dst" "${BACKUP_DIR}${dst}"
}

# sync_file SRC DST MODE [replace|inplace]
# Returns 0 if DST was (or would be) changed, 1 if already identical.
# "inplace" keeps the inode: required for files that are single-file bind mounts in containers.
# "replace" writes a new file: required for scripts that may be running right now.
sync_file() {
  local src="$1" dst="$2" mode="$3" how="${4:-replace}" want_mode
  [[ -f "$src" ]] || die "missing source file $src"
  if [[ -f "$dst" ]] && cmp -s "$src" "$dst"; then
    if [[ "$how" == inplace ]]; then
      return 1
    fi
    want_mode=$(printf '%o' "$((8#${mode}))")
    if [[ "$(stat -c '%a' "$dst")" == "$want_mode" ]]; then
      return 1
    fi
  fi
  if (( DRYRUN )); then
    log "[dry-run] would update ${dst}"
    return 0
  fi
  backup_to_run "$dst"
  if [[ "$how" == inplace && -f "$dst" ]]; then
    cat "$src" > "$dst"
  else
    install -d "$(dirname "$dst")"
    install -m "$mode" "$src" "$dst"
  fi
  restorecon_if "$dst"
  log "updated ${dst}"
  return 0
}

# sync_tree SRC_DIR DST_DIR MODE [replace|inplace]: returns 0 if any file changed.
sync_tree() {
  local src="$1" dst="$2" mode="$3" how="${4:-replace}" f rel rc=1
  while IFS= read -r -d '' f; do
    rel="${f#"${src}"/}"
    if sync_file "$f" "${dst}/${rel}" "$mode" "$how"; then
      rc=0
    fi
  done < <(find "$src" -type f -print0)
  return "$rc"
}

restore_files() {
  local f
  [[ -d "$BACKUP_DIR" ]] || return 0
  log "restoring files from ${BACKUP_DIR}"
  while IFS= read -r -d '' f; do
    if (( DRYRUN )); then
      log "[dry-run] would restore ${f#"${BACKUP_DIR}"}"
    else
      cp -a "$f" "${f#"${BACKUP_DIR}"}"
    fi
  done < <(find "$BACKUP_DIR" -type f -print0)
  run systemctl daemon-reload
}

prune_backups() {
  [[ -d "$BACKUP_ROOT" ]] || return 0
  find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | head -n "-${KEEP_BACKUPS}" | xargs -r rm -rf --
}

need_idle() {
  local n
  n=$(ci_jobs_running)
  if (( n == 0 )); then
    return 0
  fi
  SKIPPED+=("$1")
  log "WARN: ${n} CI job container(s) running, skipping $1 (rerun when idle)"
  return 1
}

wait_url() {
  local url="$1" tries="${2:-30}" i
  for ((i = 0; i < tries; i++)); do
    if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

reboot_needed() {
  local running latest
  if [[ -f /var/run/reboot-required ]]; then
    return 0
  fi
  if command -v rpm >/dev/null 2>&1 && rpm -q kernel-core >/dev/null 2>&1; then
    running=$(uname -r)
    latest=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n 1)
    if [[ "$running" != "$latest" ]]; then
      return 0
    fi
  fi
  return 1
}

update_os() {
  need_idle "os-packages" || return 0
  if (( DRYRUN )); then
    log "[dry-run] would upgrade OS packages"
    return 0
  fi
  log "upgrading OS packages"
  if command -v dnf >/dev/null 2>&1; then
    dnf -y upgrade --refresh
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Options::=--force-confold upgrade
  else
    die "no supported package manager"
  fi
  CHANGED+=("os-packages")
  local svc
  for svc in docker gitlab-runner; do
    if systemctl cat "$svc" >/dev/null 2>&1 && ! systemctl is-active --quiet "$svc"; then
      log "WARN: ${svc} is not active after the upgrade"
    fi
  done
  if reboot_needed; then
    log "REBOOT RECOMMENDED (new kernel or libraries). Do it when the runner is idle; this script never reboots."
  fi
}

update_host_tools() {
  local f u existed units_changed=0 cleanup_changed=0
  local -a scripts=(health runner-weekly-cleanup.sh runner-disk-guard.sh)
  local -a units=(runner-weekly-cleanup.service runner-weekly-cleanup.timer runner-disk-guard.service runner-disk-guard.timer)
  local -a new_timers=() changed_timers=()

  if [[ -f /etc/ci-prewarm.conf ]]; then
    scripts+=(ci-image-prewarm.sh)
    units+=(ci-image-prewarm.service ci-image-prewarm.timer)
  fi

  for f in "${scripts[@]}"; do
    bash -n "${REPO_ROOT}/scripts/${f}" || die "syntax error in scripts/${f}, nothing changed"
  done

  for f in "${scripts[@]}"; do
    if sync_file "${REPO_ROOT}/scripts/${f}" "/usr/local/bin/${f}" 0755; then
      CHANGED+=("scripts/${f}")
      if [[ "$f" == runner-weekly-cleanup.sh ]]; then
        cleanup_changed=1
      fi
    fi
  done

  for u in "${units[@]}"; do
    existed=0
    if [[ -f "/etc/systemd/system/${u}" ]]; then
      existed=1
    fi
    if sync_file "${REPO_ROOT}/systemd/${u}" "/etc/systemd/system/${u}" 0644; then
      CHANGED+=("systemd/${u}")
      units_changed=1
      if [[ "$u" == *.timer ]]; then
        if (( existed )); then
          changed_timers+=("$u")
        else
          new_timers+=("$u")
        fi
      fi
    fi
  done

  if (( units_changed )); then
    run systemctl daemon-reload
    for u in "${new_timers[@]}"; do
      run systemctl enable --now "$u"
    done
    for u in "${changed_timers[@]}"; do
      if (( DRYRUN )) || systemctl is-active --quiet "$u"; then
        run systemctl restart "$u"
      fi
    done
  fi

  if (( cleanup_changed && ! DRYRUN )); then
    if ! DRY_RUN=1 /usr/local/bin/runner-weekly-cleanup.sh >/dev/null; then
      restore_files
      die "new runner-weekly-cleanup.sh fails its dry run, files restored"
    fi
  fi
  log "host tools: done"
}

update_monitoring() {
  local dir=/opt/monitoring stage="${WORK}/monitoring" prom_image zopt="" prom=0 graf=0 comp=0
  if [[ ! -f "${dir}/docker-compose.yml" ]]; then
    log "monitoring: not installed, skipping"
    return 0
  fi

  install -d -m 0755 "$stage"
  cp -a "${REPO_ROOT}/monitoring/prometheus/." "${stage}/"
  if [[ -f /opt/registry-cache/docker-compose.yml ]] && ! grep -q 'job_name: registry-cache' "${stage}/prometheus.yml"; then
    cat >> "${stage}/prometheus.yml" <<'YAML'
  - job_name: registry-cache
    static_configs:
      - targets: ["127.0.0.1:5001"]
YAML
  fi
  if [[ -f /opt/logging/docker-compose.yml ]] && ! grep -q 'job_name: loki' "${stage}/prometheus.yml"; then
    prom_jobs_logging >> "${stage}/prometheus.yml"
  fi
  chmod -R a+rX "$stage"

  if command -v jq >/dev/null 2>&1; then
    jq empty "${REPO_ROOT}/monitoring/grafana/dashboards/gitlab-runner.json" || die "invalid dashboard JSON, nothing changed"
  fi
  if selinux_on; then
    zopt=",z"
  fi
  prom_image=$(awk '/image: prom\/prometheus/ { print $2 }' "${REPO_ROOT}/monitoring/docker-compose.yml")
  docker run --rm --entrypoint promtool -v "${stage}:/etc/prometheus:ro${zopt}" "$prom_image" \
    check config /etc/prometheus/prometheus.yml || die "promtool rejected the new Prometheus config, nothing changed"

  if sync_file "${stage}/prometheus.yml" "${dir}/prometheus/prometheus.yml" 0644 inplace; then
    prom=1
    CHANGED+=("monitoring/prometheus.yml")
  fi
  if sync_file "${stage}/alerts.yml" "${dir}/prometheus/alerts.yml" 0644 inplace; then
    prom=1
    CHANGED+=("monitoring/alerts.yml")
  fi
  if sync_tree "${REPO_ROOT}/monitoring/grafana" "${dir}/grafana" 0644 inplace; then
    graf=1
    CHANGED+=("monitoring/grafana")
  fi
  if sync_file "${REPO_ROOT}/monitoring/docker-compose.yml" "${dir}/docker-compose.yml" 0644 inplace; then
    comp=1
    CHANGED+=("monitoring/docker-compose.yml")
  fi
  if (( DRYRUN )); then
    return 0
  fi

  if ! (cd "$dir" && docker compose config -q); then
    restore_files
    die "monitoring: compose config invalid, files restored"
  fi
  if (( comp )); then
    (cd "$dir" && docker compose pull -q)
  fi
  (cd "$dir" && docker compose up -d)
  if ! wait_url http://127.0.0.1:9090/-/ready 30; then
    (cd "$dir" && docker compose logs --tail 30 prometheus) || true
    restore_files
    (cd "$dir" && docker compose up -d --force-recreate) || true
    die "monitoring: prometheus not ready, files restored"
  fi
  if (( prom )); then
    curl -fsS -X POST http://127.0.0.1:9090/-/reload || log "WARN: prometheus reload failed"
  fi
  if (( graf )); then
    (cd "$dir" && docker compose restart grafana)
  fi
  wait_url http://127.0.0.1:3000/api/health 30 || log "WARN: grafana did not report healthy yet"
  log "monitoring: done"
}

# stack_sync NAME DIR CONFIG_SRC CONFIG_NAME COMPOSE_SRC HEALTH_URL
# Single-config stacks (registry, verdaccio). A change recreates the container, so it waits for an idle runner.
stack_sync() {
  local name="$1" dir="$2" cfg_src="$3" cfg_name="$4" compose_src="$5" url="$6" pending=0
  if ! cmp -s "$cfg_src" "${dir}/${cfg_name}" || ! cmp -s "$compose_src" "${dir}/docker-compose.yml"; then
    pending=1
  fi

  if (( DRYRUN )); then
    if (( pending )); then
      sync_file "$cfg_src" "${dir}/${cfg_name}" 0644 inplace || true
      sync_file "$compose_src" "${dir}/docker-compose.yml" 0644 inplace || true
      CHANGED+=("$name")
    else
      log "${name}: up to date"
    fi
    return 0
  fi

  if (( pending )); then
    need_idle "$name" || return 0
    sync_file "$cfg_src" "${dir}/${cfg_name}" 0644 inplace || true
    sync_file "$compose_src" "${dir}/docker-compose.yml" 0644 inplace || true
    CHANGED+=("$name")
    if ! (cd "$dir" && docker compose config -q); then
      restore_files
      die "${name}: compose config invalid, files restored"
    fi
    (cd "$dir" && docker compose pull -q && docker compose up -d --force-recreate)
  else
    (cd "$dir" && docker compose up -d)
  fi

  if ! wait_url "$url" 20; then
    (cd "$dir" && docker compose logs --tail 30) || true
    if (( pending )); then
      restore_files
      (cd "$dir" && docker compose up -d --force-recreate) || true
    fi
    die "${name}: not healthy at ${url}"
  fi
  log "${name}: done"
}

# Loki + Alloy. Restarting them does not affect CI jobs, so no idle check.
update_logging() {
  local dir=/opt/logging ds=/opt/monitoring/grafana/provisioning/datasources/loki.yml f changed=0 ds_changed=0 ok=0
  if [[ ! -f "${dir}/docker-compose.yml" ]]; then
    log "logging: not installed, skipping"
    return 0
  fi
  for f in loki.yaml config.alloy docker-compose.yml; do
    if sync_file "${REPO_ROOT}/logging/${f}" "${dir}/${f}" 0644 inplace; then
      changed=1
      CHANGED+=("logging/${f}")
    fi
  done
  if [[ -f /opt/monitoring/docker-compose.yml ]] && sync_file "${REPO_ROOT}/logging/grafana-datasource.yml" "$ds" 0644 inplace; then
    ds_changed=1
    CHANGED+=("logging/grafana-datasource.yml")
  fi
  if (( DRYRUN )); then
    return 0
  fi

  if (( changed )); then
    if ! (cd "$dir" && docker compose config -q); then
      restore_files
      die "logging: compose config invalid, files restored"
    fi
    (cd "$dir" && docker compose pull -q && docker compose up -d --force-recreate)
  else
    (cd "$dir" && docker compose up -d)
  fi
  for _ in $(seq 1 45); do
    if wait_url http://127.0.0.1:3100/ready 1 && wait_url http://127.0.0.1:12345/-/ready 1; then
      ok=1
      break
    fi
  done
  if (( ! ok )); then
    (cd "$dir" && docker compose logs --tail 30) || true
    if (( changed )); then
      restore_files
      (cd "$dir" && docker compose up -d --force-recreate) || true
    fi
    die "logging: Loki or Alloy not ready"
  fi
  if (( ds_changed )); then
    (cd /opt/monitoring && docker compose restart grafana >/dev/null)
  fi
  log "logging: done"
}

update_registry_cache() {
  local dir=/opt/registry-cache
  if [[ ! -f "${dir}/docker-compose.yml" ]]; then
    log "registry-cache: not installed, skipping"
    return 0
  fi
  stack_sync registry-cache "$dir" "${REPO_ROOT}/registry-cache/config.yml" config.yml \
    "${REPO_ROOT}/registry-cache/docker-compose.yml" http://127.0.0.1:5000/v2/
}

update_npm_cache() {
  local dir=/opt/npm-cache bridge cfg="${WORK}/npm-config.yaml"
  if [[ ! -f "${dir}/docker-compose.yml" ]]; then
    log "npm-cache: not installed, skipping"
    return 0
  fi
  bridge=$(ip -4 -o addr show docker0 2>/dev/null | awk '{ print $4 }' | cut -d/ -f1 || true)
  if [[ -z "$bridge" ]]; then
    SKIPPED+=("npm-cache")
    log "WARN: docker0 bridge not found, skipping npm-cache"
    return 0
  fi
  sed "s/172\.17\.0\.1:4873/${bridge}:4873/" "${REPO_ROOT}/npm-cache/config.yaml" > "$cfg"
  stack_sync npm-cache "$dir" "$cfg" config.yaml \
    "${REPO_ROOT}/npm-cache/docker-compose.yml" "http://${bridge}:4873/-/ping"
}

do_rollback() {
  local latest
  latest=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1 || true)
  [[ -n "$latest" ]] || die "no backups in ${BACKUP_ROOT}"
  BACKUP_DIR="$latest"
  restore_files
  if (( DRYRUN )); then
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    if [[ -f /opt/monitoring/docker-compose.yml ]]; then
      (cd /opt/monitoring && docker compose up -d --force-recreate)
    fi
    if [[ -f /opt/logging/docker-compose.yml ]]; then
      (cd /opt/logging && docker compose up -d --force-recreate)
    fi
    if need_idle "stack-recreate"; then
      if [[ -f /opt/registry-cache/docker-compose.yml ]]; then
        (cd /opt/registry-cache && docker compose up -d --force-recreate)
      fi
      if [[ -f /opt/npm-cache/docker-compose.yml ]]; then
        (cd /opt/npm-cache && docker compose up -d --force-recreate)
      fi
    fi
  fi
  log "rollback done. Running update.sh again re-applies the repo state."
}

summary() {
  local verb="updated" item
  if (( DRYRUN )); then
    verb="would update"
  fi
  if (( ${#CHANGED[@]} )); then
    log "${verb}:"
    for item in "${CHANGED[@]}"; do
      printf '  - %s\n' "$item"
    done
  else
    log "everything is up to date"
  fi
  if (( ${#SKIPPED[@]} )); then
    log "SKIPPED (rerun when idle): ${SKIPPED[*]}"
  fi
}

main() {
  while (( $# )); do
    case "$1" in
      -n|--dry-run) DRYRUN=1 ;;
      --pull) DO_PULL=1 ;;
      --os) DO_OS=1 ;;
      --rollback) DO_ROLLBACK=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
  done

  require_root
  exec 9>"$LOCK"
  flock -n 9 || die "another update is running"
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  trap 'log "ERROR at line ${LINENO}: update aborted. Changed files are backed up in ${BACKUP_DIR} (install/update.sh --rollback)"' ERR

  if (( DO_ROLLBACK )); then
    do_rollback
    if (( ${#SKIPPED[@]} )); then
      exit 3
    fi
    return 0
  fi

  if (( DO_PULL )); then
    [[ -d "${REPO_ROOT}/.git" ]] || die "--pull needs a git clone, this copy has no .git"
    run git -C "$REPO_ROOT" pull --ff-only
  fi

  if (( DO_OS )); then
    update_os
  fi
  update_host_tools
  if command -v docker >/dev/null 2>&1; then
    update_monitoring
    update_logging
    update_registry_cache
    update_npm_cache
  else
    log "docker not installed, skipping container stacks"
  fi

  if (( ! DRYRUN )); then
    prune_backups
  fi
  summary

  if (( ! DRYRUN )) && [[ -x /usr/local/bin/health ]]; then
    log "health check"
    /usr/local/bin/health -q --no-color || log "health exit code $? (1 = warnings, 2 = failures)"
  fi
  if (( ${#SKIPPED[@]} )); then
    exit 3
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
