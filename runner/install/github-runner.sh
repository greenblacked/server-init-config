#!/usr/bin/env bash
# Opt-in ephemeral GitHub Actions runner for the PRIVATE repositories of one GitHub App installation (a personal account), on this host
# next to the GitLab Runner. Installs the controller (runner/scripts/github-runner-ctl) and its systemd unit, the service user
# github-runner, /etc/github-runner/config.env (no secrets) and the GitHub App private key /etc/github-runner/app.pem (mode 0600,
# owner github-runner), pulls the pinned images (common/lib.sh), runs a self-test against GitHub and only then enables the service.
# Each job gets a just-in-time runner in its own pod (network, rootless BuildKit sidecar, runner container); no Docker socket in jobs.
# Needs: Docker, runner/install/job-limits.sh (ci-jobs.slice), a GitHub App (see runner/README.md). Safe to rerun: values already in
# config.env are kept unless you pass them in the environment, a changed file gets a backup.
#
# Asks (read -rp) for what is missing: GH_OWNER (GitHub user), GH_APP_CLIENT_ID (the App's client ID) and the path of the downloaded
# private key (.pem; copied, never printed; delete the download afterwards). Without a terminal pass them in the environment: GH_OWNER,
# GH_APP_CLIENT_ID, GH_KEY_SRC.
# Env (all optional, kept from config.env on a rerun): GH_INSTALLATION_ID (found by itself), GH_LABELS (default
# self-hosted,linux,<arm64|x64>,hetzner), GH_RUNNER_GROUP_ID (1), GH_MAX_JOBS (1), GH_POLL_INTERVAL (30), GH_IDLE_TIMEOUT (300),
# GH_EXCLUDE_REPOS, GH_BUILDKIT (1), GH_JOB_CPUS / GH_JOB_MEMORY (the GitLab per-job values from config.toml, else 1.5 / 1536m),
# GH_BUILDKIT_CPUS (1), GH_BUILDKIT_MEMORY (768m), GH_JOB_SUBNET_POOL (10.213.0.0/20), GH_MAX_RUNTIME. See runner/README.md.
set -Eeuo pipefail
# shellcheck source=../../common/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../common/lib.sh"

ETC=/etc/github-runner
CFG="${ETC}/config.env"
KEY="${ETC}/app.pem"
KEY_RESTART="${ETC}/key-restart-required"
SVC_USER=github-runner
UNIT=github-runner-ctl.service
CTL=/usr/local/bin/github-runner-ctl
SLICE=/etc/systemd/system/ci-jobs.slice
USERNS_DROPIN=/etc/sysctl.d/91-github-runner-userns.conf
GITLAB_CFG=/etc/gitlab-runner/config.toml
DO_PULL=1 DO_SELFTEST=1 DO_START=1 ONLY_SELFTEST=0

usage() {
  sed -n '2,/^set -E/{/^set -E/!p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<USAGE

Usage: $0 [--self-test] [--no-self-test] [--no-start] [--no-pull]
  --self-test     only run the self-test with the installed config: mint a JWT, get an installation token, list the repositories and
                  print which would be served (names and visibility); starts and changes nothing
  --no-self-test  install and enable without the live check against GitHub (offline)
  --no-start      enable the service but do not start it
  --no-pull       do not pull the images now (the controller pulls a missing image before its first job)
Removal: see runner/docs/github-runner.md (Remove it). Stop the controller, review and remove only containers and networks labelled
  io.server-init.github-runner=job; never prune unrelated networks. Running pods survive a controller stop.
USAGE
}

while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --self-test) ONLY_SELFTEST=1 ;;
    --no-self-test) DO_SELFTEST=0 ;;
    --no-start) DO_START=0 ;;
    --no-pull) DO_PULL=0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done
require_root

run_selftest() {
  runuser -u "$SVC_USER" -- env GHR_CONFIG="$CFG" "$CTL" self-test
}

if (( ONLY_SELFTEST )); then
  [[ -x "$CTL" && -f "$CFG" ]] || die "not installed yet: run $0 first"
  run_selftest
  exit $?
fi

# ---- preflight ---------------------------------------------------------------------------------------------------------------
command -v docker >/dev/null || die "docker is not installed"
systemctl is-active --quiet docker || die "docker is not running"
systemctl cat ci-job-isolation.service >/dev/null 2>&1 || die "ci-job-isolation.service missing: install the runner host tools first"
getent group docker >/dev/null || die "no docker group"
[[ -f "$SLICE" ]] || die "${SLICE} missing: run runner/setup.sh --job-limits first (the pods run inside ci-jobs.slice, which caps all CI jobs together)"
read -r cgdrv cgver < <(docker info --format '{{.CgroupDriver}} {{.CgroupVersion}}' 2>/dev/null || echo "? ?")
[[ "$cgdrv" == systemd && "$cgver" == 2 ]] || die "Docker must use cgroup v2 with the systemd cgroup driver (found: ${cgdrv} v${cgver}); --cgroup-parent ci-jobs.slice needs it"
for t in curl jq openssl; do command -v "$t" >/dev/null || pkg_install "$t"; done
command -v runuser >/dev/null || die "runuser (util-linux) is missing"
[[ -f "${REPO_ROOT}/runner/scripts/github-runner-ctl" && -f "${REPO_ROOT}/runner/systemd/${UNIT}" ]] || die "incomplete copy of the repository"

existing() { # existing KEY: the value in config.env, quotes removed
  [[ -f "$CFG" ]] || return 0
  { grep -m1 "^$1=" "$CFG" || true; } | cut -d= -f2- | sed -E 's/^"(.*)"$/\1/'
}
# pick KEY DEFAULT: environment, else config.env, else DEFAULT
pick() {
  local v=${!1:-}
  [[ -n "$v" ]] || v=$(existing "$1")
  printf '%s' "${v:-$2}"
}

# Rootless BuildKit needs user namespaces for non-root (kernel: user.max_user_namespaces > 0). Only written when it is 0.
buildkit_wanted=$(pick GH_BUILDKIT 1)
if [[ "$buildkit_wanted" == 1 ]]; then
  maxns=$(sysctl -n user.max_user_namespaces 2>/dev/null || echo 0)
  if [[ "$maxns" =~ ^[0-9]+$ ]] && (( maxns == 0 )); then
    printf '# Written by runner/install/github-runner.sh: rootless BuildKit needs user namespaces.\nuser.max_user_namespaces = 28633\n' > "${USERNS_DROPIN}.new"
    if ! cmp -s "${USERNS_DROPIN}.new" "$USERNS_DROPIN" 2>/dev/null; then mv "${USERNS_DROPIN}.new" "$USERNS_DROPIN"; else rm -f "${USERNS_DROPIN}.new"; fi
    sysctl -q -w user.max_user_namespaces=28633 || log "WARN: could not set user.max_user_namespaces now; it applies after a reboot"
    log "user.max_user_namespaces was 0: set to 28633 (${USERNS_DROPIN}); rootless BuildKit needs it"
  else
    log "user.max_user_namespaces = ${maxns}: ok for rootless BuildKit"
  fi
  if [[ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" == 1 ]]; then
    log "WARN: kernel.apparmor_restrict_unprivileged_userns=1 (Ubuntu): rootless BuildKit will fail; set it to 0 in /etc/sysctl.d or use GH_BUILDKIT=0"
  fi
fi

# ---- service user ----------------------------------------------------------------------------------------------------------------
NOLOGIN=$(command -v nologin || echo /sbin/nologin)
if ! id "$SVC_USER" >/dev/null 2>&1; then
  useradd -r -U -M -d /nonexistent -s "$NOLOGIN" -c "GitHub Actions runner controller" "$SVC_USER"
  log "created service user ${SVC_USER}"
fi
usermod -s "$NOLOGIN" "$SVC_USER" >/dev/null 2>&1 || true
usermod -L "$SVC_USER" 2>/dev/null || true
usermod -aG docker "$SVC_USER"   # root-equivalent: it is what the controller needs to start the pods
install -d -m 0750 -o root -g "$SVC_USER" "$ETC"

# ---- the key ---------------------------------------------------------------------------------------------------------------------
changed=0
src=${GH_KEY_SRC:-}
if [[ -z "$src" && ! -f "$KEY" ]]; then
  [[ -t 0 ]] || die "no private key yet: pass its path in GH_KEY_SRC (the .pem downloaded from the GitHub App page)"
  read -rp "Path of the downloaded GitHub App private key (.pem): " src
fi
if [[ -n "$src" ]]; then
  [[ -f "$src" && -r "$src" ]] || die "cannot read ${src}"
  openssl rsa -in "$src" -passin pass: -noout >/dev/null 2>&1 || die "${src} is not an RSA private key (download it from the GitHub App page, Generate a private key)"
  if ! cmp -s "$src" "$KEY" 2>/dev/null; then
    [[ ! -f "$KEY" ]] || backup "$KEY"
    install -m 0600 -o "$SVC_USER" -g "$SVC_USER" "$src" "$KEY"
    ( umask 077; : > "$KEY_RESTART" )
    changed=1   # clear cached credentials after a successful self-test, even when config and code are unchanged
    log "private key installed: ${KEY} (mode 0600, owner ${SVC_USER})"
  fi
  if [[ "$(realpath "$src")" != "$(realpath "$KEY")" ]]; then
    log "REMINDER: the downloaded copy ${src} is still on disk: delete it once the self-test passes (shred -u '${src}')"
  fi
fi
[[ -f "$KEY" ]] || die "no ${KEY}"
openssl rsa -in "$KEY" -passin pass: -noout >/dev/null 2>&1 || die "${KEY} is not an RSA private key"
chown "${SVC_USER}:${SVC_USER}" "$KEY"; chmod 0600 "$KEY"
[[ ! -f "$KEY_RESTART" ]] || changed=1   # retry a rotation whose self-test or activation previously failed

# ---- config ----------------------------------------------------------------------------------------------------------------------
GH_OWNER=$(pick GH_OWNER "")
if [[ -z "$GH_OWNER" ]]; then
  [[ -t 0 ]] || die "GH_OWNER is not set: pass the GitHub user name in the environment"
  read -rp "GitHub user (owner of the private repositories): " GH_OWNER
fi
GH_APP_CLIENT_ID=$(pick GH_APP_CLIENT_ID "")
if [[ -z "$GH_APP_CLIENT_ID" ]]; then
  [[ -t 0 ]] || die "GH_APP_CLIENT_ID is not set: pass the App's client ID in the environment"
  read -rp "Client ID of the GitHub App (Iv...): " GH_APP_CLIENT_ID
fi
case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; *) arch=x64 ;; esac
# the per-job limits of the GitLab jobs (same numbers): from config.toml when job-limits.sh wrote them
gl() { [[ -f "$GITLAB_CFG" ]] && sed -nE "s/^[[:space:]]+$1 = \"([^\"]+)\".*/\1/p" "$GITLAB_CFG" | head -n1 || true; }
job_mem_default=$(gl memory); job_cpu_default=$(gl cpus)

# only plain characters: the value goes through sed (env_set) and into a file the controller parses
set_cfg() {
  [[ "$2" =~ ^[A-Za-z0-9_.,@:/+-]*$ ]] || die "$1: unexpected characters in '$2'"
  [[ -n "${CFG_DRY:-}" ]] || env_set "${CFG_TARGET:-$CFG}" "$1" "$2"
}
write_config() {
  set_cfg GH_OWNER "$GH_OWNER"
  set_cfg GH_APP_CLIENT_ID "$GH_APP_CLIENT_ID"
  set_cfg GH_INSTALLATION_ID "$(pick GH_INSTALLATION_ID "")"
  set_cfg GH_LABELS "$(pick GH_LABELS "self-hosted,linux,${arch},hetzner")"
  set_cfg GH_RUNNER_GROUP_ID "$(pick GH_RUNNER_GROUP_ID 1)"
  set_cfg GH_MAX_JOBS "$(pick GH_MAX_JOBS 1)"
  set_cfg GH_POLL_INTERVAL "$(pick GH_POLL_INTERVAL 30)"
  set_cfg GH_IDLE_TIMEOUT "$(pick GH_IDLE_TIMEOUT 300)"
  set_cfg GH_MAX_RUNTIME "$(pick GH_MAX_RUNTIME 21900)"
  set_cfg GH_EXCLUDE_REPOS "$(pick GH_EXCLUDE_REPOS "")"
  set_cfg GH_BUILDKIT "$buildkit_wanted"
  set_cfg GH_JOB_CPUS "$(pick GH_JOB_CPUS "${job_cpu_default:-1.5}")"
  set_cfg GH_JOB_MEMORY "$(pick GH_JOB_MEMORY "${job_mem_default:-1536m}")"
  set_cfg GH_BUILDKIT_CPUS "$(pick GH_BUILDKIT_CPUS 1)"
  set_cfg GH_BUILDKIT_MEMORY "$(pick GH_BUILDKIT_MEMORY 768m)"
  set_cfg GH_JOB_SUBNET_POOL "$(pick GH_JOB_SUBNET_POOL 10.213.0.0/20)"
  set_cfg GH_KEY_FILE "$KEY"
  # the images are pinned in common/lib.sh and follow the repository (a bump reaches the host with this script or update.sh)
  set_cfg GH_RUNNER_IMAGE "$GHR_RUNNER_IMAGE"
  set_cfg GH_BUILDKIT_IMAGE "$GHR_BUILDKIT_IMAGE"
}
CFG_DRY=1 write_config   # checks every value first: a bad one must not leave a half-written file
cfg_candidate=$(mktemp)
trap 'rm -f -- "$cfg_candidate"' EXIT
if [[ -f "$CFG" ]]; then cp "$CFG" "$cfg_candidate"; fi
CFG_TARGET="$cfg_candidate" write_config
GHR_CONFIG="$cfg_candidate" bash "${REPO_ROOT}/runner/scripts/github-runner-ctl" check-config \
  || die "candidate config is invalid; installed config was not changed"
apply_config() { cat "$cfg_candidate" > "$CFG"; }
if [[ ! -f "$CFG" ]]; then
  printf '# Written by runner/install/github-runner.sh. No secrets here: the private key is %s.\n# Documentation: runner/README.md (GitHub Actions runner).\n' "$KEY" > "$CFG"
  write_config   # a new file: nothing to back up
else
  cfg_before=$(sha256sum < "$CFG")
  edit_with_backup "$CFG" apply_config
  [[ "$cfg_before" == "$(sha256sum < "$CFG")" ]] || changed=1   # restart below so the controller reads the new values
fi
chown "root:${SVC_USER}" "$CFG"; chmod 0640 "$CFG"

# ---- files, unit, images -----------------------------------------------------------------------------------------------------------
install_if_changed() { # SRC DST MODE
  if ! cmp -s "$1" "$2" 2>/dev/null || [[ "$(stat -c %a "$2")" != "$(printf '%o' "$((8#$3))")" ]]; then
    [[ ! -f "$2" ]] || backup "$2"
    install -m "$3" "$1" "$2"; restorecon_if "$2"; changed=1; log "installed ${2}"
  fi
}
bash -n "${REPO_ROOT}/runner/scripts/github-runner-ctl" || die "syntax error in the controller"
install_if_changed "${REPO_ROOT}/runner/scripts/github-runner-ctl" "$CTL" 0755
install_if_changed "${REPO_ROOT}/runner/systemd/${UNIT}" "/etc/systemd/system/${UNIT}" 0644
GHR_CONFIG="$CFG" "$CTL" check-config || die "config.env is invalid (see above); fix it and rerun"
systemctl daemon-reload
# ci-job-isolation reads GH_JOB_SUBNET_POOL: it lets the pod networks, and only them, reach the npm cache (docker0 IP, port 4873)
systemctl reload-or-restart ci-job-isolation.service || die "ci-job-isolation failed: inspect journalctl -u ci-job-isolation.service before enabling the runner"

if (( DO_PULL )); then
  log "pulling the pinned images (the runner image is large)"
  docker pull -q "$GHR_RUNNER_IMAGE" >/dev/null
  if [[ "$(existing GH_BUILDKIT)" == 1 ]]; then docker pull -q "$GHR_BUILDKIT_IMAGE" >/dev/null; fi
fi

# ---- self-test, then enable --------------------------------------------------------------------------------------------------------
if (( DO_SELFTEST )); then
  log "self-test against GitHub (starts nothing)"
  if ! run_selftest; then
    log "self-test FAILED: service activation is unchanged (an existing service may still be running). Fix the App, then rerun ${0} to self-test and apply activation/restart."
    exit 1
  fi
fi
systemctl enable "$UNIT" >/dev/null 2>&1
if (( DO_START )); then
  if systemctl is-active --quiet "$UNIT"; then
    if (( changed )); then systemctl restart "$UNIT"; log "${UNIT} restarted (running pods keep running)"; fi
  else
    systemctl start "$UNIT"
  fi
  sleep 3
  systemctl is-active --quiet "$UNIT" || { journalctl -u github-runner-ctl -n 20 --no-pager || true; die "${UNIT} is not running"; }
  rm -f -- "$KEY_RESTART"
  log "OK: ${UNIT} running. Use it with runs-on: [self-hosted, hetzner] in a private repository; logs: journalctl -u github-runner-ctl -f; health shows the status"
else
  log "OK: ${UNIT} enabled, not started (--no-start): systemctl start github-runner-ctl"
fi
