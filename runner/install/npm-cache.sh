#!/usr/bin/env bash
# Verdaccio npm pull-through cache on the docker0 bridge IP, exposed to CI jobs via runner env.
# If the cache is down, npm ci in jobs fails (npm has no automatic fallback).
set -Eeuo pipefail
# shellcheck source=../../common/lib.sh
source "$(dirname "$0")/../../common/lib.sh"

DIR=/opt/npm-cache
CFG=/etc/gitlab-runner/config.toml

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0  installs Verdaccio into $DIR and points runner jobs at it"
  exit 0
fi
require_root
if ! { [[ -f "$CFG" ]] && grep -q '^\[\[runners\]\]' "$CFG"; }; then die "runner not registered yet, run runner/install/register-runner.sh first"; fi

BRIDGE_IP=$(ip -4 -o addr show docker0 2>/dev/null | awk '{ print $4 }' | cut -d/ -f1)
[[ -n "$BRIDGE_IP" ]] || die "docker0 bridge not found"
REG="http://${BRIDGE_IP}:4873/"
require_runner_idle

selinux_label_dir "$DIR"
sed "s/172\.17\.0\.1:4873/${BRIDGE_IP}:4873/" "$REPO_ROOT/runner/stacks/npm-cache/config.yaml" > "$DIR/config.yaml"
sed "s/172\.17\.0\.1:4873/${BRIDGE_IP}:4873/" "$REPO_ROOT/runner/stacks/npm-cache/docker-compose.yml" > "$DIR/docker-compose.yml"
restorecon_if -R "$DIR"

cd "$DIR"
docker compose config -q
docker compose pull -q
docker compose up -d
for _ in $(seq 1 20); do curl -fsS "${REG}-/ping" >/dev/null 2>&1 && break; sleep 2; done
curl -fsS "${REG}-/ping" >/dev/null || { docker compose logs --tail 30; die "verdaccio did not start"; }

exposed=$(ss -ltn | awk -v want="${BRIDGE_IP}:4873" '/:4873 / && $4 != want' | wc -l)
[[ "$exposed" == "0" ]] || { ss -ltn | awk '/:4873 /'; die "port 4873 is not bound to ${BRIDGE_IP} only"; }

backup "$CFG"
runner_env_merge "npm_config_registry=${REG}" "YARN_NPM_REGISTRY_SERVER=${REG}" "YARN_UNSAFE_HTTP_WHITELIST=${BRIDGE_IP}"
systemctl restart gitlab-runner
sleep 3

docker run --rm -e npm_config_registry="$REG" node:22-alpine sh -c \
  'cd /tmp && npm init -y >/dev/null && npm install --no-audit --no-fund lodash >/dev/null && echo "npm install via cache OK"' \
  || die "npm install through verdaccio failed"

grep -n 'environment =' "$CFG"
ss -ltn | awk 'NR==1 || /:4873 /'
gitlab-runner verify 2>&1 | grep -E 'is valid|is not valid' || true
log "OK: npm cache at ${REG}"
