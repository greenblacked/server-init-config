#!/usr/bin/env bash
# Laptop-side bootstrap of a new server built from one of the cloud-init files.
# Waits for cloud-init, streams this repo (git HEAD) to the server over SSH, runs the safe components
# through gitlab-runner/setup.sh and finishes with `health`. Nothing secret is stored on the server
# beforehand: the repo is private, so it is never cloned there, and the runner token is typed at the
# prompt of an interactive ssh -t session (never on a command line, in the environment or in a file).
set -Eeuo pipefail

REMOTE_DIR=/root/server-init-config
SSH_USER=root
SSH_PORT=22
SERVER=""
DRY_RUN=0
ALLOW_DIRTY=0
DO_REGISTER=1
WITH_PREWARM=0
CONTINUE_DEGRADED=0
WAIT_SSH_SECONDS=300

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

log() { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "[$(date +%H:%M:%S)] WARN: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 [options] SERVER_IP

Run after creating a server from a cloud-init file. Waits for cloud-init, copies this repo (git HEAD)
to ${REMOTE_DIR} without any credential on the server, installs the safe components and runs health.

  --user USER         SSH user (default root); a non-root user needs passwordless sudo
  --port PORT         SSH port (default 22)
  --no-register       do not register the runner (also skips npm-cache and shared-cache
                      unless a runner is already registered)
  --with-prewarm      also run the image prewarm (asks for a GitLab deploy token)
  --allow-dirty       copy HEAD even though the working tree has uncommitted changes
  --continue-degraded go on when cloud-init reports "degraded" (recoverable errors)
  --dry-run           print the ssh commands and the component list, change nothing
  -h, --help          this help

Env (passed to the server, none of them is a secret):
  DOMAIN, ACME_EMAIL  both set: also set up Grafana on an HTTPS domain
  DESCRIPTION         runner description for the registration
  GITLAB_URL          GitLab URL for the registration (default https://gitlab.com)

Never installed here: lock-root (run it yourself after testing the ops login) and selinux (the
Rocky inits enable it already). The runner token is typed at the prompt on the server.
Components that are already installed are skipped, so rerunning is safe.
USAGE
}

while (( $# )); do
  case "$1" in
    --user) [[ $# -ge 2 ]] || die "--user needs a value"; SSH_USER="$2"; shift ;;
    --port) [[ $# -ge 2 ]] || die "--port needs a value"; SSH_PORT="$2"; shift ;;
    --no-register) DO_REGISTER=0 ;;
    --with-prewarm) WITH_PREWARM=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --continue-degraded) CONTINUE_DEGRADED=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *)
      [[ -z "$SERVER" ]] || { usage >&2; die "only one SERVER_IP is accepted"; }
      SERVER="$1"
      ;;
  esac
  shift
done

[[ -n "$SERVER" ]] || { usage >&2; die "SERVER_IP is required"; }
[[ "$SERVER" =~ ^[A-Za-z0-9._:-]+$ ]] || die "invalid server address: ${SERVER}"
[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid --user: ${SSH_USER}"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "invalid --port: ${SSH_PORT}"

DOMAIN="${DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
if [[ -n "$DOMAIN" && -z "$ACME_EMAIL" ]] || [[ -z "$DOMAIN" && -n "$ACME_EMAIL" ]]; then
  die "DOMAIN and ACME_EMAIL must be given together (or neither)"
fi

TARGET="${SSH_USER}@${SERVER}"
SUDO=""   # prefix for remote commands, with a trailing space when set
if [[ "$SSH_USER" != root ]]; then SUDO="sudo -n "; fi
# Never empty, so "${SSH_OPTS[@]}" is safe under set -u on bash 3.2.
SSH_OPTS=(-p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30)

# Print a command the way a shell would need it (dry-run and logs only).
show() {
  local out="" a
  for a in "$@"; do
    if [[ "$a" =~ ^[A-Za-z0-9_@%+=:,./-]+$ ]]; then
      out+=" ${a}"
    else
      out+=" '$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'"
    fi
  done
  echo "${out# }"
}

# Run a command (or only print it in dry-run mode).
run() {
  if (( DRY_RUN )); then
    log "[dry-run] $(show "$@")"
  else
    "$@"
  fi
}

# Quote a value for the remote shell.
q() { printf '%q' "$1"; }

# --- components ---------------------------------------------------------------------------------
# setup.sh orders the components itself, so only the set is chosen here. Phase 1 (users) is run
# alone so root access can be re-checked before anything else changes. Phase 2 is one call, with a
# terminal when a component asks for input.
PHASE2=(packages tools)
NEEDS_TTY=0

registered_on_server() {
  ssh "${SSH_OPTS[@]}" "$TARGET" "${SUDO}grep -qs '^\\[\\[runners\\]\\]' /etc/gitlab-runner/config.toml"
}

REGISTERED=0   # 1 when the runner is (or will be) registered, which npm-cache and shared-cache need

choose_components() {
  PHASE2+=(registry-cache monitoring logging)
  if (( DO_REGISTER )); then
    PHASE2+=(register)
    NEEDS_TTY=1
    REGISTERED=1
  fi
  if (( WITH_PREWARM )); then
    PHASE2+=(prewarm)
    NEEDS_TTY=1
  fi
  if [[ -n "$DOMAIN" ]]; then
    PHASE2+=(grafana-domain)
  fi
}

# When 'users' is not part of this run, monitoring and logging need it to be installed already
# (setup.sh dies otherwise and nothing would be installed). Check it, and drop them if it is not.
# Also warns about the SSH user only when it is really outside ssh-users.
handle_skipped_users() {
  local c keep=() in_group=0 installed=0
  (( INCLUDE_USERS )) && return 0
  if (( DRY_RUN )); then
    log "[dry-run] ${USERS_SKIP_REASON}"
    log "[dry-run] would check on the server whether users is installed; if not, monitoring, logging and grafana-domain are dropped"
    return 0
  fi
  if ssh "${SSH_OPTS[@]}" "$TARGET" "${SUDO}sh -c \"id monitoring >/dev/null 2>&1 && grep -qs '^AllowGroups' /etc/ssh/sshd_config.d/00-ci-hardening.conf\""; then
    installed=1
  fi
  if (( installed )) && [[ "$SSH_USER" != root ]]; then
    if ssh "${SSH_OPTS[@]}" "$TARGET" "id -nG | tr ' ' '\\n' | grep -qx ssh-users"; then in_group=1; fi
    if (( ! in_group )); then warn "${SSH_USER} is not in [ssh-users]; SSH for it may stop working"; fi
  elif (( ! installed )); then
    warn "$USERS_SKIP_REASON"
  fi
  if (( installed )); then
    log "users is already installed on the server, monitoring and logging stay in the list"
    return 0
  fi
  for c in "${PHASE2[@]}"; do
    case "$c" in
      monitoring|logging|grafana-domain) ;;
      *) keep+=("$c") ;;
    esac
  done
  PHASE2=("${keep[@]}")
  warn "users is not installed on the server: monitoring, logging (and grafana-domain) are NOT installed in this run. Add them later, after 'users' is installed (run this script again as root on port 22, or on the server: bash ${REMOTE_DIR}/gitlab-runner/setup.sh --users --monitoring --logging)"
}

# Without --no-register the runner gets registered in this run. With it, the caches are added only
# if the server already has a registered runner (setup.sh refuses them otherwise). Needs SSH.
add_cache_components() {
  if (( ! REGISTERED && ! DRY_RUN )) && registered_on_server; then
    REGISTERED=1
  fi
  if (( REGISTERED )); then
    PHASE2+=(npm-cache shared-cache)
  elif (( DRY_RUN )); then
    log "[dry-run] --no-register: npm-cache and shared-cache are added only if the server already has a registered runner"
  else
    warn "no registered runner: npm-cache and shared-cache skipped (after registering: setup.sh --npm-cache --shared-cache)"
  fi
}

# Users: with root as the SSH user, install/users.sh keeps "PermitRootLogin prohibit-password",
# "AllowGroups ssh-users root" and Port 22 (SSH_PORT defaults to 22) until --lock-root, so root
# stays reachable by key. A non-root SSH user is not in ssh-users yet, so it could lock itself out.
INCLUDE_USERS=1
USERS_SKIP_REASON=""
if [[ "$SSH_USER" != root ]]; then
  INCLUDE_USERS=0
  USERS_SKIP_REASON="--user ${SSH_USER}: 'users' skipped, it limits SSH to the ssh-users group and ${SSH_USER} may not be in it; run it as root"
fi
if [[ "$SSH_PORT" != 22 ]]; then
  INCLUDE_USERS=0
  USERS_SKIP_REASON="--port ${SSH_PORT}: 'users' skipped, install/users.sh keeps sshd on port 22 and would drop this port"
fi
PORT_OPT=""
if [[ "$SSH_PORT" != 22 ]]; then PORT_OPT=" -p ${SSH_PORT}"; fi
HEALTH_BIN=/usr/local/bin/health

# --- checks on the laptop ------------------------------------------------------------------------
check_local() {
  command -v ssh >/dev/null || die "ssh not found"
  command -v git >/dev/null || die "git not found"
  command -v tar >/dev/null || die "tar not found"
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "${REPO_ROOT} is not a git repository"
  [[ -f "${REPO_ROOT}/gitlab-runner/setup.sh" ]] || die "gitlab-runner/setup.sh not found in ${REPO_ROOT}"
  if (( ! ALLOW_DIRTY )) && [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]]; then
    die "uncommitted changes in ${REPO_ROOT}: only HEAD is copied. Commit them, or use --allow-dirty to copy HEAD anyway"
  fi
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]]; then
    warn "working tree is dirty: the server gets HEAD, not your uncommitted changes"
  fi
  if (( NEEDS_TTY && ! DRY_RUN )) && [[ ! -t 0 ]]; then
    die "registering the runner (or prewarm) needs a terminal for the token prompt; run from an interactive shell, or use --no-register"
  fi
}

# --- ssh ------------------------------------------------------------------------------------------
# Retry while the server is still booting; fail at once on host-key and authentication problems.
wait_for_ssh() {
  local deadline=$(( $(date +%s) + WAIT_SSH_SECONDS )) err
  log "waiting for SSH on ${TARGET} (port ${SSH_PORT})"
  while :; do
    if err="$(ssh "${SSH_OPTS[@]}" "$TARGET" true 2>&1)"; then
      return 0
    fi
    case "$err" in
      *"Host key verification failed"*|*"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"No ED25519 host key is known"*|*"No RSA host key is known"*|*"No ECDSA host key is known"*)
        echo "$err" >&2
        die "host key not trusted. Check it first: ssh-keyscan -p ${SSH_PORT} ${SERVER} (compare with the host-key fingerprints in the cloud-init console output: Hetzner Console, server, Console), or log in once by hand: ssh -p ${SSH_PORT} ${TARGET}. A changed key on a reused IP: ssh-keygen -R ${SERVER}"
        ;;
      *"Permission denied"*)
        echo "$err" >&2
        die "SSH login refused for ${TARGET}: is your key the one given to Hetzner (ssh-add -l, or ssh -i)? Is --user right?"
        ;;
    esac
    if (( $(date +%s) >= deadline )); then
      echo "$err" >&2
      die "no SSH after ${WAIT_SSH_SECONDS}s: is the server up, the IP right and TCP ${SSH_PORT} open in the Hetzner Firewall?"
    fi
    sleep 5
  done
}

wait_cloud_init() {
  log "waiting for cloud-init to finish (cloud-init status --wait)"
  local rc=0 out failed_log
  out="$(ssh "${SSH_OPTS[@]}" "$TARGET" "${SUDO}cloud-init status --wait" 2>&1)" || rc=$?
  echo "$out"
  if (( rc == 255 )); then
    die "SSH failed while waiting for cloud-init"
  fi
  # The bootstrap writes this file when a step failed, even if cloud-init itself reports success.
  failed_log="$(ssh "${SSH_OPTS[@]}" "$TARGET" "${SUDO}cat /var/log/ci-bootstrap-failed.log 2>/dev/null" || true)"
  if [[ -n "$failed_log" ]]; then
    warn "/var/log/ci-bootstrap-failed.log is not empty:"
    echo "$failed_log" >&2
  fi
  if (( rc == 0 )); then
    log "cloud-init: done"
    return 0
  fi
  log "cloud-init exited with code ${rc} (1 = error, 2 = degraded)"
  if (( rc == 2 && CONTINUE_DEGRADED )); then
    warn "cloud-init is degraded, continuing because of --continue-degraded"
    return 0
  fi
  echo "Read the full log: ssh ${TARGET} 'cat /var/log/cloud-init-output.log'. Fix the cause, or rebuild the server." >&2
  if (( rc == 2 )); then
    echo "Degraded means recoverable errors (see the log above); --continue-degraded goes on anyway." >&2
  fi
  die "cloud-init did not finish cleanly, nothing was installed"
}

# Replace the copy atomically: extract next to it, then swap, so no file of an old copy survives.
copy_repo() {
  local head script quoted
  head="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  script="set -e; d=${REMOTE_DIR}; rm -rf \"\$d.new\" \"\$d.old\"; install -d -m 0700 \"\$d.new\"; tar -x -C \"\$d.new\"; if [ -e \"\$d\" ]; then mv \"\$d\" \"\$d.old\"; fi; mv \"\$d.new\" \"\$d\"; rm -rf \"\$d.old\""
  quoted="$(q "$script")"
  local remote="${SUDO}sh -c ${quoted}"
  log "copying ${head} (git archive, no .git, no credentials) to ${TARGET}:${REMOTE_DIR}"
  if (( DRY_RUN )); then
    log "[dry-run] git -C $(show "$REPO_ROOT") -c tar.umask=0022 archive --format=tar HEAD | $(show ssh "${SSH_OPTS[@]}" "$TARGET" "$remote")"
    return 0
  fi
  # tar.umask keeps the files from being group-writable on the server. Both pipeline statuses are
  # kept: if the remote side dies before reading, git gets SIGPIPE (141) and hides the real cause.
  local git_rc=0 ssh_rc=0 rcs=()
  set +e
  git -C "$REPO_ROOT" -c tar.umask=0022 archive --format=tar HEAD | ssh "${SSH_OPTS[@]}" "$TARGET" "$remote"
  rcs=("${PIPESTATUS[@]}")
  set -e
  git_rc="${rcs[0]}"
  ssh_rc="${rcs[1]}"
  if (( ssh_rc != 0 )); then
    die "copy failed on the server side (ssh/tar exit ${ssh_rc}; 255 = connection problem): the repo was not copied. Check disk space and, for a non-root user, passwordless sudo"
  fi
  if (( git_rc != 0 )); then
    die "copy failed on the laptop side (git archive exit ${git_rc})"
  fi
  ssh "${SSH_OPTS[@]}" "$TARGET" "${SUDO}test -f ${REMOTE_DIR}/gitlab-runner/setup.sh" || die "the copy on the server is incomplete"
}

# Remote command for setup.sh. Only non-secret values go into it.
setup_command() {
  local envs="" c cmd
  if [[ -n "$DOMAIN" ]]; then envs+=" DOMAIN=$(q "$DOMAIN") ACME_EMAIL=$(q "$ACME_EMAIL")"; fi
  if [[ -n "${DESCRIPTION:-}" ]]; then envs+=" DESCRIPTION=$(q "$DESCRIPTION")"; fi
  if [[ -n "${GITLAB_URL:-}" ]]; then envs+=" GITLAB_URL=$(q "$GITLAB_URL")"; fi
  cmd="cd ${REMOTE_DIR} &&${envs} bash gitlab-runner/setup.sh"
  for c in "$@"; do cmd+=" --${c}"; done
  # /root is not readable for a non-root user: the whole line runs under sudo.
  if [[ -n "$SUDO" ]]; then cmd="${SUDO}bash -c $(q "$cmd")"; fi
  echo "$cmd"
}

run_remote() {
  local tty="$1" cmd="$2"
  if [[ "$tty" == tty ]]; then
    run ssh -t "${SSH_OPTS[@]}" "$TARGET" "$cmd"
  else
    run ssh "${SSH_OPTS[@]}" "$TARGET" "$cmd"
  fi
}

recheck_root() {
  log "re-checking SSH login for ${TARGET}"
  (( DRY_RUN )) && { log "[dry-run] $(show ssh "${SSH_OPTS[@]}" "$TARGET" true)"; return 0; }
  ssh "${SSH_OPTS[@]}" "$TARGET" true \
    || die "SSH login for ${TARGET} no longer works after 'users'. Use the Hetzner console, then: install/users.sh --unlock-root"
  log "login by key still works"
  [[ "${1:-}" == quiet ]] && return 0
  log "TEST THE OPS LOGIN NOW from a second terminal:  ssh${PORT_OPT} ops@${SERVER} 'sudo -n true && echo ok'  (must print ok). Root SSH stays open until you run lock-root."
}

main() {
  choose_components
  check_local

  log "target: ${TARGET}:${SSH_PORT}, repo: ${REPO_ROOT} @ $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  local not_installed="lock-root, selinux"
  if [[ -z "$DOMAIN" ]]; then not_installed+=", grafana-domain (DOMAIN and ACME_EMAIL not set)"; fi
  log "never installed here: ${not_installed}"

  if (( DRY_RUN )); then
    log "[dry-run] $(show ssh "${SSH_OPTS[@]}" "$TARGET" true)"
    log "[dry-run] $(show ssh "${SSH_OPTS[@]}" "$TARGET" "${SUDO}cloud-init status --wait")"
  else
    wait_for_ssh
    wait_cloud_init
  fi
  handle_skipped_users
  add_cache_components
  if (( INCLUDE_USERS )); then log "components, phase 1: users"; fi
  log "components, phase 2 (setup.sh orders them): ${PHASE2[*]}"
  copy_repo

  if (( INCLUDE_USERS )); then
    run_remote notty "$(setup_command users)" || {
      warn "the users phase failed (exit $?)"
      recheck_root quiet
      die "users failed; SSH is still usable (checked above). Read the output above, fix the cause and rerun: installed components are skipped"
    }
    recheck_root
  fi
  local tty="notty"
  if (( NEEDS_TTY )); then
    tty="tty"
    log "the server asks for the runner token (glrt-...) and any other input on this terminal; nothing is stored on this laptop"
  fi
  run_remote "$tty" "$(setup_command "${PHASE2[@]}")"

  log "health"
  local rc=0
  if (( DRY_RUN )); then
    run ssh "${SSH_OPTS[@]}" "$TARGET" "${SUDO}${HEALTH_BIN} --no-color"
  else
    ssh "${SSH_OPTS[@]}" "$TARGET" "${SUDO}${HEALTH_BIN} --no-color" || rc=$?
    if (( rc == 1 )); then warn "health reports warnings (exit 1)"; fi
    if (( rc >= 2 )); then warn "health reports failures (exit ${rc}); read the report above"; fi
  fi

  cat <<NEXT

[done] Next steps
  1. Smoke test: run ci/smoke.yml in a project. The log must show "on <runner description>" and
     aarch64 (CAX) or x86_64 (CX/CPX/CCX); check with: ssh${PORT_OPT} ${TARGET} uname -m
     The tags in ci/*.yml say arm64: on an x86 server change them to your runner's tag.
  2. Test the admin login from a second terminal:  ssh${PORT_OPT} ops@${SERVER} 'sudo -n true && echo ok'
  3. Only then close root SSH, by hand:  ssh${PORT_OPT} ${TARGET} '${SUDO}bash ${REMOTE_DIR}/gitlab-runner/setup.sh --lock-root'
  4. Later updates: rerun this script, then  ssh${PORT_OPT} ops@${SERVER} 'sudo ${REMOTE_DIR}/gitlab-runner/update.sh'
NEXT
}

main
