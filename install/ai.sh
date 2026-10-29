#!/usr/bin/env bash
# Local AI stack: Ollama + Open WebUI, CPU only, UI on 127.0.0.1:3000 (reach it via SSH tunnel).
# Meant for a separate small server, not the runner host: a model competes with CI jobs for RAM.
# Idempotent: rerun after changing ai/docker-compose.yml to roll out new image tags.
set -Eeuo pipefail
# shellcheck source=install/lib.sh
source "$(dirname "$0")/lib.sh"

DIR=/opt/ai
MODEL="${MODEL:-qwen2.5:1.5b}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
SWAP_FILE=/swapfile
UI_URL="http://127.0.0.1:3000"
CURL=(curl -fsS --connect-timeout 3 --max-time 10)

usage() {
  cat <<USAGE
Usage: $0 [--close-signup]

Installs or updates Ollama + Open WebUI in ${DIR} and pulls one model.
  (no option)      install or update the stack, pull \$MODEL
  --close-signup   after you created the admin account: disable new sign-ups and restart the UI

Environment:
  MODEL      model to pull (default: ${MODEL}); any tag from ollama.com/library
  SWAP_SIZE  swap file to create when the host has no swap (default: ${SWAP_SIZE}, 0 to skip)

Access from your laptop:  ssh -N -L 3000:127.0.0.1:3000 <admin>@<server>  then open http://localhost:3000
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
  grep -q '^ENABLE_SIGNUP=' "$f" || env_set "$f" ENABLE_SIGNUP true
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

check_binding() {
  local exposed
  exposed=$(ss -ltn | awk '$4 ~ /:3000$/ && $4 != "127.0.0.1:3000"' | wc -l)
  [[ "$exposed" == "0" ]] || { ss -ltn | awk '$4 ~ /:3000$/'; die "port 3000 is not bound to 127.0.0.1 only"; }
}

close_signup() {
  [[ -f "${DIR}/docker-compose.yml" ]] || die "stack not installed, run $0 first"
  command -v jq >/dev/null || pkg_install jq
  env_set "${DIR}/.env" ENABLE_SIGNUP false
  (cd "$DIR" && docker compose up -d open-webui)
  wait_ui
  # Open WebUI keeps settings in its database once saved, and a stored value wins over the environment.
  local signup
  signup=$("${CURL[@]}" "${UI_URL}/api/config" | jq -r '.features.enable_signup | if . == null then "unknown" else tostring end' || true)
  case "$signup" in
    false)   log "OK: sign-ups disabled" ;;
    true)    die "sign-ups are still enabled by the setting stored in Open WebUI; switch them off in Admin Panel > Settings > General" ;;
    *)       die "could not read features.enable_signup from ${UI_URL}/api/config; check Admin Panel > Settings > General by hand" ;;
  esac
}

case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  --close-signup) require_root; close_signup; exit 0 ;;
  "") ;;
  *) usage; die "unknown option: $1" ;;
esac

require_root
command -v docker >/dev/null || die "docker not installed"
docker compose version >/dev/null 2>&1 || die "docker compose plugin missing"
command -v openssl >/dev/null || pkg_install openssl
[[ "$MODEL" =~ ^[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?$ ]] || die "invalid MODEL: ${MODEL}"

if systemctl is-active --quiet gitlab-runner 2>/dev/null; then
  log "WARN: gitlab-runner is active on this host; the model will compete with CI jobs for memory"
fi
mem_mb=$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)
(( mem_mb >= 3500 )) || log "WARN: ${mem_mb} MB RAM; the stack is sized for 4 GB"

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
if grep -qxF -- "$MODEL" <<<"$models"; then
  log "model ${MODEL} already present"
else
  log "pulling model ${MODEL}"
  docker compose exec -T ollama ollama pull "$MODEL"
fi

docker compose ps
docker compose exec -T ollama ollama list
ss -ltn | awk 'NR == 1 || $4 ~ /:3000$/'
log "OK: Open WebUI on ${UI_URL} (server-local). Tunnel in, create the admin account, then run: $0 --close-signup"
