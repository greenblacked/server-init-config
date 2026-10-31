#!/usr/bin/env bash
# Shared host cache /srv/ci-cache mounted into every job as /ci-cache (npm tarballs, Sonar plugins).
# The cache is shared across all projects on this runner: only use it for trusted projects.
set -Eeuo pipefail
# shellcheck source=../../common/lib.sh
source "$(dirname "$0")/../../common/lib.sh"

HOST_DIR=/srv/ci-cache
MOUNT=/ci-cache
CFG=/etc/gitlab-runner/config.toml

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0  mounts $HOST_DIR into all jobs and sets npm_config_cache and SONAR_USER_HOME"
  exit 0
fi
require_root
if ! { [[ -f "$CFG" ]] && grep -q '^\[\[runners\]\]' "$CFG"; }; then die "runner not registered yet"; fi
require_runner_idle

install -d -m 1777 "$HOST_DIR" "$HOST_DIR/npm" "$HOST_DIR/sonar"
if selinux_on; then
  command -v semanage >/dev/null 2>&1 || pkg_install policycoreutils-python-utils
  grep -q "^${HOST_DIR}(/\.\*)?" <<<"$(semanage fcontext -l)" || semanage fcontext -a -t container_file_t "${HOST_DIR}(/.*)?"
  restorecon -R "$HOST_DIR"
fi

add_shared_cache() {
  if ! grep -q "${HOST_DIR}:${MOUNT}" "$CFG"; then
    grep -qE '^    volumes = \["/cache"\]' "$CFG" || die "unexpected volumes line in [runners.docker], edit manually"
    sed -i -E "s|^    volumes = \[\"/cache\"\]|    volumes = [\"/cache\", \"${HOST_DIR}:${MOUNT}:rw\"]|" "$CFG"
  fi
  runner_env_merge "npm_config_cache=${MOUNT}/npm" "SONAR_USER_HOME=${MOUNT}/sonar"
}
edit_with_backup "$CFG" add_shared_cache
systemctl restart gitlab-runner
sleep 3

docker run --rm --user 1000:1000 -v "${HOST_DIR}:${MOUNT}:rw" alpine:3.20 \
  sh -c "touch ${MOUNT}/npm/.probe && rm ${MOUNT}/npm/.probe && echo 'non-root write OK'" \
  || die "containers cannot write to ${HOST_DIR}"

grep -nE 'volumes =|environment =' "$CFG"
gitlab-runner verify 2>&1 | grep -E 'is valid|is not valid' || true
log "OK: shared cache ${HOST_DIR} mounted as ${MOUNT} in all jobs"
