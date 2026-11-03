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

# A Grafana volume left over from an earlier install is archived before a new major can migrate it (no-op on a clean host).
# The copy-paste block (runner/COMMANDS.md) carries monitoring.sh alone, without the backup script: skip it there.
backup_script="$(dirname "$0")/monitoring-backup.sh"
if [[ -f "$backup_script" ]]; then
  bash "$backup_script"
else
  log "WARN: ${backup_script} not found, a Grafana volume left over from an earlier install is not archived"
fi

selinux_label_dir "$DIR"
curl -fsS http://127.0.0.1:9252/metrics >/dev/null 2>&1 || log "WARN: runner metrics on 127.0.0.1:9252 not reachable"

cp -a "$REPO_ROOT/runner/stacks/monitoring/docker-compose.yml" "$DIR/"
cp -a "$REPO_ROOT/runner/stacks/monitoring/prometheus" "$REPO_ROOT/runner/stacks/monitoring/grafana" "$DIR/"

if [[ ! -f "$DIR/.env" ]]; then
  pw=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-24)
  # Grafana encrypts stored credentials (data source passwords, API keys) with secret_key, which is a public default unless set.
  # Generated only on a first install: data that exists under the default key (a volume left over from an earlier install) cannot be
  # read with a new one, so there the default stays. The key belongs next to every backup archive (runner/README.md).
  sk=""
  # A failed `docker volume ls` (daemon down) must not read as "no volume": a key generated over a default-key volume locks its data.
  vols=$(docker volume ls -q --filter label=com.docker.compose.project=monitoring --filter label=com.docker.compose.volume=grafana-data) \
    || die "cannot list docker volumes (is the Docker daemon running?)"
  if [[ -z "$vols" ]]; then
    sk=$(head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-40)
  else
    # The volume may have been written under a key of the earlier install; this run has no way to know it, so it adds none.
    log "NOTE: a Grafana data volume exists, so no new encryption key is generated and Grafana uses its built-in default key"
    log "NOTE: if the earlier install's .env had a GF_SECURITY_SECRET_KEY line, put that same line back in ${DIR}/.env; Grafana is started by this run on the default key, so after adding it run: cd ${DIR} && sudo docker compose up -d grafana (recreates Grafana with the key). An existing .env is kept, so restoring the earlier .env before the installer also works; see runner/README.md, Grafana upgrade and rollback"
  fi
  (umask 077
   sed "s/^GF_SECURITY_ADMIN_PASSWORD=.*/GF_SECURITY_ADMIN_PASSWORD=${pw}/" "$REPO_ROOT/runner/stacks/monitoring/env.example" | grep -v '^#' > "$DIR/.env"
   if [[ -n "$sk" ]]; then printf 'GF_SECURITY_SECRET_KEY=%s\n' "$sk" >> "$DIR/.env"; fi)
  unset pw sk vols
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
