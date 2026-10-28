#!/usr/bin/env bash
# Log collection: Loki (storage, 7 days) + Grafana Alloy (container logs and the systemd journal).
# CI job containers are not collected, their output is the job log in GitLab.
# Alloy reads the Docker socket, which is root-equivalent on the host. Everything listens on 127.0.0.1.
set -Eeuo pipefail
# shellcheck source=install/lib.sh
source "$(dirname "$0")/lib.sh"

DIR=/opt/logging
MON=/opt/monitoring
PROM_CFG="${MON}/prometheus/prometheus.yml"
DATASOURCE="${MON}/grafana/provisioning/datasources/loki.yml"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0  installs Loki + Grafana Alloy into $DIR and adds Loki to Grafana if monitoring is installed"
  exit 0
fi
require_root
mon_ids
command -v docker >/dev/null || die "docker not installed"
docker compose version >/dev/null 2>&1 || die "docker compose plugin missing"
command -v jq >/dev/null || pkg_install jq
if [[ -f "${DIR}/docker-compose.yml" ]]; then
  log "${DIR} exists: re-applying the repo files and finishing the setup (safe after a failed run)"
elif ss -ltn | awk '$4 ~ /:(3100|9096|12345)$/' | grep -q .; then
  die "port 3100, 9096 or 12345 already in use"
fi
[[ -f /etc/machine-id ]] || die "/etc/machine-id missing, the journal cannot be read"

if [[ ! -d /var/log/journal ]]; then
  log "enabling persistent journal in /var/log/journal"
  install -d -m 2755 -g systemd-journal /var/log/journal
  systemd-tmpfiles --create --prefix /var/log/journal
  systemctl restart systemd-journald
fi

selinux_label_dir "$DIR"
cp -a "${REPO_ROOT}/logging/docker-compose.yml" "${REPO_ROOT}/logging/loki.yaml" "${REPO_ROOT}/logging/config.alloy" "${DIR}/"
stack_ids "$DIR" logging
own_stack_dir "$DIR"
restorecon_if -R "$DIR"

loki_image=$(awk '/image: grafana\/loki/ { print $2 }' "${DIR}/docker-compose.yml")
alloy_image=$(awk '/image: grafana\/alloy/ { print $2 }' "${DIR}/docker-compose.yml")

cd "$DIR"
docker compose config -q
docker compose pull -q
docker run --rm --user "${MON_UID}:${MON_GID}" -v "${DIR}/loki.yaml:/etc/loki/config.yaml:ro" "$loki_image" \
  -config.file=/etc/loki/config.yaml -verify-config || die "Loki rejected loki.yaml"
docker run --rm --user "${MON_UID}:${MON_GID}" --entrypoint /bin/alloy -v "${DIR}/config.alloy:/config/config.alloy:ro" "$alloy_image" \
  fmt /config/config.alloy >/dev/null || die "Alloy rejected config.alloy"
chown_volumes "$DIR"
docker compose up -d --force-recreate

ready=0
for _ in $(seq 1 45); do
  if curl -fsS -m 3 http://127.0.0.1:3100/ready >/dev/null 2>&1 && curl -fsS -m 3 http://127.0.0.1:12345/-/ready >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
if (( ! ready )); then
  docker compose logs --tail 40
  die "Loki or Alloy did not become ready"
fi

if [[ -d "${MON}/grafana/provisioning/datasources" ]]; then
  cp "${REPO_ROOT}/logging/grafana-datasource.yml" "$DATASOURCE"
  chown "root:${MON_USER}" "$DATASOURCE"
  chmod 640 "$DATASOURCE"
  restorecon_if "$DATASOURCE"
  (cd "$MON" && docker compose restart grafana >/dev/null)
  log "Loki added to Grafana as a datasource"
fi
if [[ -f "$PROM_CFG" ]] && ! grep -q 'job_name: loki' "$PROM_CFG"; then
  backup "$PROM_CFG"
  prom_jobs_logging >> "$PROM_CFG"
  curl -fsS -X POST http://127.0.0.1:9090/-/reload || log "WARN: prometheus reload failed"
fi

marker="logging-install-check-$(date +%s)"
logger -t logging-install -- "$marker"
found=0
for _ in $(seq 1 30); do
  n=$(curl -fsS -G -m 5 http://127.0.0.1:3100/loki/api/v1/query_range \
        --data-urlencode "query={source=\"journal\"} |= \"${marker}\"" --data-urlencode "since=10m" 2>/dev/null \
      | jq '.data.result | length' 2>/dev/null || echo 0)
  if [[ "${n:-0}" != "0" ]]; then
    found=1
    break
  fi
  sleep 2
done
if (( found )); then
  log "journal -> Alloy -> Loki works"
else
  log "WARN: test line not in Loki yet, check: docker compose -f ${DIR}/docker-compose.yml logs alloy"
fi

docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'
exposed=$(ss -ltn | awk '/:(3100|9096|12345) / && $4 !~ /^127\.0\.0\.1:/' | wc -l)
[[ "$exposed" == "0" ]] || die "a logging port is not bound to 127.0.0.1"
log "OK: logs in Grafana > Explore > Loki, e.g. {unit=\"gitlab-runner.service\"} or {compose_project=\"registry-cache\"}"
