#!/usr/bin/env bash
# Install Prometheus + node_exporter + Grafana (all bound to 127.0.0.1) with the runner dashboard.
set -Eeuo pipefail
# shellcheck source=../../common/lib.sh
source "$(dirname "$0")/../../common/lib.sh"

DIR=/opt/monitoring

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0  installs the monitoring stack into $DIR"
  exit 0
fi
require_root
mon_ids
command -v docker >/dev/null || die "docker not installed"
docker compose version >/dev/null 2>&1 || die "docker compose plugin missing"
command -v jq >/dev/null || pkg_install jq
[[ -f "$DIR/docker-compose.yml" ]] && die "$DIR/docker-compose.yml exists, stack already installed"

selinux_label_dir "$DIR"
curl -fsS http://127.0.0.1:9252/metrics >/dev/null 2>&1 || log "WARN: runner metrics on 127.0.0.1:9252 not reachable"

cp -a "$REPO_ROOT/runner/stacks/monitoring/docker-compose.yml" "$DIR/"
cp -a "$REPO_ROOT/runner/stacks/monitoring/prometheus" "$REPO_ROOT/runner/stacks/monitoring/grafana" "$DIR/"

if [[ ! -f "$DIR/.env" ]]; then
  pw=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-24)
  (umask 077; sed "s/^GF_SECURITY_ADMIN_PASSWORD=.*/GF_SECURITY_ADMIN_PASSWORD=${pw}/" "$REPO_ROOT/runner/stacks/monitoring/env.example" | grep -v '^#' > "$DIR/.env")
  unset pw
fi
chmod 600 "$DIR/.env"
stack_ids "$DIR"
own_stack_dir "$DIR"
restorecon_if -R "$DIR"

prom_image=$(awk '/image: prom\/prometheus/ { print $2 }' "$DIR/docker-compose.yml")
jq empty "$DIR/grafana/dashboards/gitlab-runner.json"
docker compose -f "$DIR/docker-compose.yml" config -q
docker run --rm --user "${MON_UID}:${MON_GID}" --entrypoint promtool -v "$DIR/prometheus:/etc/prometheus:ro" "$prom_image" \
  check config /etc/prometheus/prometheus.yml

cd "$DIR"
docker compose pull -q
chown_volumes "$DIR"
docker compose up -d

for _ in $(seq 1 30); do
  curl -fsS http://127.0.0.1:9090/-/ready >/dev/null 2>&1 \
    && curl -fsS http://127.0.0.1:3000/api/health >/dev/null 2>&1 && break
  sleep 2
done
for _ in $(seq 1 15); do
  down=$(curl -fsS http://127.0.0.1:9090/api/v1/targets | jq '[.data.activeTargets[] | select(.health != "up")] | length')
  [[ "$down" == "0" ]] && break
  sleep 2
done

docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'
curl -fsS http://127.0.0.1:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.health)\t\(.lastError)"'
ss -ltn | awk 'NR==1 || /:(9090|9100|3000|9252) /'

exposed=$(ss -ltn | awk '/:(9090|9100|3000) / && $4 !~ /^127\.0\.0\.1:/' | wc -l)
[[ "$exposed" == "0" ]] || die "a monitoring port is not bound to 127.0.0.1"
log "OK: monitoring up. Grafana password: sudo grep GF_SECURITY_ADMIN_PASSWORD $DIR/.env"
