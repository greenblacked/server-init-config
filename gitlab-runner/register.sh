#!/usr/bin/env bash
# Register this host as a GitLab Runner (docker executor) with a glrt- authentication token.
# Self-contained: does not need the rest of the repo.
set -Eeuo pipefail

GITLAB_URL="${GITLAB_URL:-https://gitlab.com}"
DESCRIPTION="${DESCRIPTION:-$(uname -n)}"
DEFAULT_IMAGE="${DEFAULT_IMAGE:-alpine:3.20}"
REQUEST_CONCURRENCY="${REQUEST_CONCURRENCY:-2}"
CFG=/etc/gitlab-runner/config.toml

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<USAGE
Usage: $0
Env: GITLAB_URL (default https://gitlab.com), DESCRIPTION (default: hostname),
     DEFAULT_IMAGE (default alpine:3.20), REQUEST_CONCURRENCY (default 2)
Create the runner first in GitLab (Settings > CI/CD > Runners > New runner) and copy its glrt- token.
Tags, untagged jobs, protected and locked are set there, not here.
The token is read without echo and is never written to shell history.
USAGE
  exit 0
fi

[[ $EUID -eq 0 ]] || die "run as root"
command -v gitlab-runner >/dev/null || die "gitlab-runner is not installed"
systemctl is-active --quiet docker || die "docker is not running"
if [[ -f "$CFG" ]] && grep -q '^\[\[runners\]\]' "$CFG"; then
  die "a runner is already registered in ${CFG}. Remove it first: gitlab-runner unregister --all-runners"
fi

read -rsp "Runner authentication token (glrt-...): " token; echo
[[ "$token" == glrt-* ]] || die "token must start with glrt-"

[[ -f "$CFG" ]] && cp -a "$CFG" "${CFG}.bak.$(date +%Y%m%d-%H%M%S)"
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
systemctl restart gitlab-runner
sleep 3

gitlab-runner verify 2>&1 | grep -E 'is valid|is not valid' || true
grep -nE '^concurrent|^listen_address|request_concurrency|executor|pull_policy' "$CFG"
if journalctl -u gitlab-runner --since "-1min" --no-pager | grep -qi bottleneck; then
  log "WARN: runner still reports a request bottleneck"
else
  log "OK: runner registered. Run a job from ci/smoke.yml to confirm it picks jobs up."
fi
