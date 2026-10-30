#!/usr/bin/env bash
# Docker Hub pull-through cache on 127.0.0.1:5000, wired into the Docker daemon as a mirror.
# Restarts Docker: refuses to run while CI jobs are running.
set -Eeuo pipefail
# shellcheck source=../../common/lib.sh
source "$(dirname "$0")/../../common/lib.sh"

DIR=/opt/registry-cache
MIRROR="http://127.0.0.1:5000"
DAEMON=/etc/docker/daemon.json
PROM_CFG=/opt/monitoring/prometheus/prometheus.yml

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0  installs the Docker Hub pull-through cache into $DIR"
  exit 0
fi
require_root
command -v jq >/dev/null || pkg_install jq
require_runner_idle
if ss -ltn | awk '$4 ~ /:(5000|5001)$/' | grep -q .; then die "port 5000 or 5001 already in use"; fi

selinux_label_dir "$DIR"
cp -a "$REPO_ROOT/runner/stacks/registry-cache/config.yml" "$REPO_ROOT/runner/stacks/registry-cache/docker-compose.yml" "$DIR/"
restorecon_if -R "$DIR"

cd "$DIR"
docker compose config -q
docker compose pull -q
docker compose up -d
for _ in $(seq 1 15); do curl -fsS "$MIRROR/v2/" >/dev/null 2>&1 && break; sleep 2; done
curl -fsS "$MIRROR/v2/" >/dev/null || { docker compose logs --tail 30; die "registry cache did not start"; }

if ! jq -e --arg m "$MIRROR" '(.["registry-mirrors"] // []) | index($m)' "$DAEMON" >/dev/null 2>&1; then
  backup "$DAEMON"
  tmp=$(mktemp)
  jq --arg m "$MIRROR" '.["registry-mirrors"] = [$m]' "$DAEMON" > "$tmp"
  dockerd --validate --config-file "$tmp" >/dev/null || { rm -f "$tmp"; die "new daemon.json is invalid"; }
  install -m 0644 "$tmp" "$DAEMON"
  rm -f "$tmp"
  restorecon_if "$DAEMON"
  log "restarting docker"
  systemctl restart docker
  sleep 5
  systemctl restart gitlab-runner || true
  for _ in $(seq 1 20); do curl -fsS "$MIRROR/v2/" >/dev/null 2>&1 && break; sleep 2; done
fi

if [[ -f "$PROM_CFG" ]] && ! grep -q 'job_name: registry-cache' "$PROM_CFG"; then
  backup "$PROM_CFG"
  cat >> "$PROM_CFG" <<'YAML'
  - job_name: registry-cache
    static_configs:
      - targets: ["127.0.0.1:5001"]
YAML
  curl -fsS -X POST http://127.0.0.1:9090/-/reload || log "WARN: prometheus reload failed"
fi

docker rmi -f busybox:1.36 >/dev/null 2>&1 || true
docker pull -q busybox:1.36 >/dev/null
docker info 2>/dev/null | grep -A1 'Registry Mirrors'
curl -fsS "$MIRROR/v2/_catalog" | jq -c .
ss -ltn | awk 'NR==1 || /:(5000|5001) /'
log "OK: Docker Hub pull-through cache at ${MIRROR}"
