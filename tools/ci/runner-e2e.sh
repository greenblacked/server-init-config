#!/usr/bin/env bash
# Runner-host components that need no GitLab token and no Docker daemon, in a systemd container (see runner-container.sh).
#   Usage: tools/ci/runner-e2e.sh IMAGE      rockylinux/rockylinux:10 | debian:13
# Env: KEEP=1 keeps the container. WARNING: the container is privileged and applies sysctl keys; on your own machine
# run it in a VM, on CI it is a throwaway runner.
set -Eeuo pipefail
# shellcheck source=systemd-lib.sh
source "$(dirname "$0")/systemd-lib.sh"
cd "$CI_ROOT"
IMAGE="${1:?usage: $0 IMAGE}"
SLUG=$(tr -c 'A-Za-z0-9\n' '_' <<<"$IMAGE")
NAME="runner-e2e-${SLUG}"; TAG="runner-e2e-img:${SLUG}"; W="$CI_OUT/runner-${SLUG}"
mkdir -p "$W"
need docker || die "docker is required"
case "$IMAGE" in *rocky* | *almalinux* | *centos*) KIND=el ;; *debian* | *ubuntu*) KIND=debian ;; *) die "unsupported runner image: $IMAGE" ;; esac
cleanup() {
  local rc=$?
  sd_collect "$NAME" "$W/collected" 2>/dev/null || true
  docker exec "$NAME" sh -c 'tar -c /tmp/runner-*.log /tmp/state*.txt /tmp/health-*.txt 2>/dev/null' > "$W/logs.tar" 2>/dev/null || true
  if [[ "${KEEP:-0}" != 1 ]]; then docker rm -f "$NAME" >/dev/null 2>&1 || true; fi
  exit "$rc"
}
trap cleanup EXIT

group "build and start ${IMAGE}"
sd_build "$IMAGE" "$TAG" 2>&1 | tee "$W/build.log" | tail -3
sd_run "$NAME" "$TAG"
endgroup
# the repo as `git archive HEAD` (runner needs runner/ and common/), like the bootstrap streams it
docker exec "$NAME" mkdir -p /root/server-init-config
git archive --format=tar HEAD | docker exec -i "$NAME" tar -x -C /root/server-init-config
docker exec -i "$NAME" bash /root/server-init-config/tools/ci/runner-container.sh "$KIND" 2>&1 | tee "$W/run.log"
! grep -q '  FAIL  ' "$W/run.log"
