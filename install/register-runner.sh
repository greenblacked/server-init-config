#!/usr/bin/env bash
# Register a docker-executor runner with a glrt- token and apply the job pickup fix.
set -Eeuo pipefail
# shellcheck source=install/lib.sh
source "$(dirname "$0")/lib.sh"

GITLAB_URL="${GITLAB_URL:-https://gitlab.com}"
DESCRIPTION="${DESCRIPTION:-hetzner-$(uname -n)}"
DEFAULT_IMAGE="${DEFAULT_IMAGE:-alpine:3.20}"
REQUEST_CONCURRENCY="${REQUEST_CONCURRENCY:-2}"
CFG=/etc/gitlab-runner/config.toml

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<USAGE
Usage: $0
Env: GITLAB_URL (default https://gitlab.com), DESCRIPTION (default hetzner-<hostname>),
     DEFAULT_IMAGE (default alpine:3.20), REQUEST_CONCURRENCY (default 2)
Tags, untagged jobs, protected and locked are set in the GitLab UI when creating the runner.
The token is read interactively and never stored in shell history.
USAGE
  exit 0
fi
require_root
command -v gitlab-runner >/dev/null || die "gitlab-runner not installed"
systemctl is-active --quiet docker || die "docker is not running"
if [[ -f "$CFG" ]] && grep -q '^\[\[runners\]\]' "$CFG"; then
  die "a runner is already registered in ${CFG}. Remove it first: gitlab-runner unregister --all-runners"
fi

read -rsp "Runner authentication token (glrt-...): " token; echo
[[ "$token" == glrt-* ]] || die "token must start with glrt-"

[[ -f "$CFG" ]] && backup "$CFG"
gitlab-runner register --non-interactive \
  --url "$GITLAB_URL" \
  --token "$token" \
  --executor docker \
  --docker-image "$DEFAULT_IMAGE" \
  --description "$DESCRIPTION" \
  --docker-pull-policy "if-not-present" \
  --docker-volumes "/cache" >/dev/null
unset token

if ! grep -q 'request_concurrency' "$CFG"; then
  sed -i -E "0,/^  name = .*/s//&\n  request_concurrency = ${REQUEST_CONCURRENCY}/" "$CFG"
fi
chmod 600 "$CFG"
runner_cfg_owner
systemctl restart gitlab-runner
sleep 3

gitlab-runner verify 2>&1 | grep -E 'is valid|is not valid' || true
grep -nE '^concurrent|^listen_address|request_concurrency|executor' "$CFG"
if journalctl -u gitlab-runner --since "-1min" --no-pager | grep -qi bottleneck; then
  log "WARN: runner still reports a request bottleneck"
else
  log "OK: runner registered"
fi
