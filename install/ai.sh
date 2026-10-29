#!/usr/bin/env bash
# Local AI stack: Ollama + Open WebUI, CPU only, UI on 127.0.0.1:${UI_PORT} (default 3080; reach it via SSH tunnel).
# Meant for a separate small server, not the runner host: a model competes with CI jobs for RAM.
# Idempotent: rerun after changing ai/docker-compose.yml to roll out new image tags.
set -Eeuo pipefail
# shellcheck source=install/lib.sh
source "$(dirname "$0")/lib.sh"

DIR=/opt/ai
MODEL="${MODEL:-qwen2.5:1.5b}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
SWAP_FILE=/swapfile
# UI_PORT: environment, else the value saved in .env by an earlier run, else 3080 (3000 is Grafana's).
UI_PORT="${UI_PORT:-}"
if [[ -z "$UI_PORT" && -f "${DIR}/.env" ]]; then
  UI_PORT=$(grep -m1 '^UI_PORT=' "${DIR}/.env" | cut -d= -f2 || true)
fi
UI_PORT="${UI_PORT:-3080}"
[[ "$UI_PORT" =~ ^[0-9]+$ ]] && (( UI_PORT >= 1024 && UI_PORT <= 65535 )) || die "invalid UI_PORT: ${UI_PORT} (use 1024-65535)"
UI_URL="http://127.0.0.1:${UI_PORT}"
CURL=(curl -fsS --connect-timeout 3 --max-time 10)

usage() {
  cat <<USAGE
Usage: $0 [--check-signup]

Installs or updates Ollama + Open WebUI in ${DIR} and pulls one model.
  (no option)      install or update the stack, pull \$MODEL
  --check-signup   read-only: report whether Open WebUI still allows new sign-ups
                   (the first account becomes admin and closes sign-ups automatically;
                   re-open or close later in Admin Panel > Settings > General)
  --close-signup   deprecated alias for --check-signup

Environment:
  UI_PORT    host port of the UI on 127.0.0.1 (default: ${UI_PORT}; saved in ${DIR}/.env; 3000 is Grafana's port on the monitoring stack)
  MODEL      model to pull (default: ${MODEL}); any tag from ollama.com/library
  SWAP_SIZE  swap file to create when the host has no swap (default: ${SWAP_SIZE}, 0 to skip)

Access from your laptop:  ssh -N -L ${UI_PORT}:127.0.0.1:${UI_PORT} <admin>@<server>  then open http://localhost:${UI_PORT}
USAGE
}

ensure_swap() {
  [[ "$SWAP_SIZE" == "0" ]] && return 0
  if [[ -n "$(swapon --noheadings --show)" ]]; then
    log "swap already present, skipping"
    return 0
  fi
  log "creating ${SWAP_SIZE} swap at ${SWAP_FILE}"
  fallocate -l "$SWAP_SIZE" "$SWAP_FILE"
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE" >/dev/null
  restorecon_if "$SWAP_FILE"
  swapon "$SWAP_FILE"
  grep -q "^${SWAP_FILE} " /etc/fstab || echo "${SWAP_FILE} none swap defaults 0 0" >> /etc/fstab
}

ensure_env() {
  local f="${DIR}/.env"
  touch "$f"
  chown root:root "$f"
  chmod 600 "$f"
  if ! grep -q '^WEBUI_SECRET_KEY=' "$f"; then
    env_set "$f" WEBUI_SECRET_KEY "$(openssl rand -hex 32)"
  fi
  env_set "$f" UI_PORT "$UI_PORT"
}

wait_ui() {
  local _
  for _ in $(seq 1 60); do
    "${CURL[@]}" "${UI_URL}/health" >/dev/null 2>&1 && return 0
    sleep 3
  done
  (cd "$DIR" && docker compose logs --tail 40)
  die "Open WebUI did not become healthy on ${UI_URL}"
}

# Does this stack's own open-webui container publish 127.0.0.1:UI_PORT? (true on a rerun)
stack_owns_port() {
  local published
  published=$(docker compose -f "${DIR}/docker-compose.yml" port open-webui 8080 2>/dev/null || true)
  [[ "$published" == "127.0.0.1:${UI_PORT}" ]]
}

check_port_free() {
  local listeners
  listeners=$(ss -ltn | awk -v p=":${UI_PORT}" 'substr($4, length($4) - length(p) + 1) == p { print $4 }')
  [[ -z "$listeners" ]] && return 0
  stack_owns_port && return 0
  die "port ${UI_PORT} is already in use on this host (${listeners//$'\n'/ }); pick another with UI_PORT=<port> (3000 is Grafana's port on the monitoring stack)"
}

check_binding() {
  local exposed
  exposed=$(ss -ltn | awk -v p=":${UI_PORT}" -v ok="127.0.0.1:${UI_PORT}" 'substr($4, length($4) - length(p) + 1) == p && $4 != ok' | wc -l)
  [[ "$exposed" == "0" ]] || { ss -ltn | awk -v p=":${UI_PORT}" 'substr($4, length($4) - length(p) + 1) == p'; die "port ${UI_PORT} is not bound to 127.0.0.1 only"; }
}

# Read-only: sign-ups are controlled inside Open WebUI (Admin Panel > Settings > General), not by .env.
check_signup() {
  command -v jq >/dev/null || pkg_install jq
  local signup
  signup=$("${CURL[@]}" "${UI_URL}/api/config" | jq -r '.features.enable_signup | if . == null then "unknown" else tostring end' || true)
  case "$signup" in
    false)   log "OK: sign-ups disabled" ;;
    true)    die "sign-ups are enabled; switch them off in Admin Panel > Settings > General" ;;
    *)       die "could not read features.enable_signup from ${UI_URL}/api/config (is the UI running?); check Admin Panel > Settings > General by hand" ;;
  esac
}

case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  --check-signup) check_signup; exit 0 ;;
  --close-signup) log "NOTE: --close-signup is deprecated and only checks now; Open WebUI closes sign-ups itself after the first account"; check_signup; exit 0 ;;
  "") ;;
  *) usage; die "unknown option: $1" ;;
esac

require_root
command -v docker >/dev/null || die "docker not installed"
docker compose version >/dev/null 2>&1 || die "docker compose plugin missing"
command -v openssl >/dev/null || pkg_install openssl
[[ -f "$REPO_ROOT/ai/docker-compose.yml" ]] || die "missing $REPO_ROOT/ai/docker-compose.yml: run ai.sh from a full copy of the repo"
[[ "$MODEL" =~ ^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$ ]] || die "invalid MODEL: ${MODEL}"

if systemctl is-active --quiet gitlab-runner 2>/dev/null; then
  log "WARN: gitlab-runner is active on this host; the model will compete with CI jobs for memory"
fi
mem_mb=$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)
(( mem_mb >= 3500 )) || log "WARN: ${mem_mb} MB RAM; the stack is sized for 4 GB"

check_port_free
ensure_swap
install -d -m 0750 "$DIR"
if [[ -f "${DIR}/docker-compose.yml" ]] && ! cmp -s "$REPO_ROOT/ai/docker-compose.yml" "${DIR}/docker-compose.yml"; then
  backup "${DIR}/docker-compose.yml"
fi
install -m 0640 "$REPO_ROOT/ai/docker-compose.yml" "${DIR}/docker-compose.yml"
ensure_env

cd "$DIR"
docker compose config -q
docker compose pull -q
docker compose up -d --remove-orphans
wait_ui
check_binding

# Read the whole list first: grep -q exits at the first match and would SIGPIPE the producer under pipefail.
models=$(docker compose exec -T ollama ollama list | awk 'NR > 1 { print $1 }')
# ollama list always shows the tag, so an untagged MODEL means :latest.
want="$MODEL"
[[ "${want##*/}" == *:* ]] || want="${want}:latest"
if grep -qxF -- "$want" <<<"$models"; then
  log "model ${MODEL} already present"
else
  log "pulling model ${MODEL}"
  docker compose exec -T ollama ollama pull "$MODEL"
fi

docker compose ps
docker compose exec -T ollama ollama list
ss -ltn | awk -v p=":${UI_PORT}" 'NR == 1 || substr($4, length($4) - length(p) + 1) == p'
log "OK: Open WebUI on ${UI_URL} (server-local). Tunnel in, create the admin account, then verify with: $0 --check-signup"
