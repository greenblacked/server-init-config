#!/usr/bin/env bash
# Laptop-side bootstrap of a plain server (no GitLab Runner). Works on a fresh Hetzner server or on one that
# already ran a server cloud-init file. Waits for cloud-init, streams server/ and common/ of this repo (git HEAD)
# to the server over SSH, runs the server-init script that matches the detected OS, installs `health` and, on
# Fedora and EL, the maintenance tools, and finishes with `health`. It never installs or registers a GitLab Runner.
# Nothing secret is stored on the server: the repo is streamed, not cloned there (git clone of the public repo on the server also works), and no credential
# goes into a command line, the environment or a file. For a runner host use runner/bootstrap.sh.
# Written for bash 3.2 (macOS): no associative arrays, no mapfile, no ${var,,}.
set -Eeuo pipefail

REMOTE_DIR=/root/server-init-config
SSH_USER=root
SSH_PORT=22
SERVER=""
OS_KIND=""
DRY_RUN=0
ALLOW_DIRTY=0
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

Run after creating a plain server (any supported image, with or without a server cloud-init file). Waits for
cloud-init, copies server/ and common/ of this repo (git HEAD) to ${REMOTE_DIR} without any credential on the
server, runs the matching server-init script, installs health (and the maintenance tools on Fedora and EL) and
runs health. No GitLab Runner is installed or registered; use runner/bootstrap.sh for that.

  --user USER         SSH user (default root); a non-root user needs passwordless sudo
  --port PORT         SSH port (default 22); server-init never changes the SSH port
  --os KIND           fedora, el10, debian or opensuse; default: detected from /etc/os-release
  --allow-dirty       copy HEAD even though the working tree has uncommitted changes
  --continue-degraded go on when cloud-init reports "degraded" (recoverable errors)
  --dry-run           print the ssh commands and the steps, change nothing
  -h, --help          this help

Env (first run only, saved to /etc/server-init.conf on the server; none of them is a secret):
  ADMIN_USER, EXTRA_PORTS, TIMEZONE, INSTALL_DOCKER, INSTALL_SWAP, INSTALL_CLEANUP, APP

Root keeps SSH login by key throughout; nothing here closes it (optional afterwards: server/lock-root.sh). Every step is safe to rerun.
USAGE
}

while (( $# )); do
  case "$1" in
    --user) [[ $# -ge 2 ]] || die "--user needs a value"; SSH_USER="$2"; shift ;;
    --port) [[ $# -ge 2 ]] || die "--port needs a value"; SSH_PORT="$2"; shift ;;
    --os) [[ $# -ge 2 ]] || die "--os needs a value"; OS_KIND="$2"; shift ;;
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
case "$OS_KIND" in ""|fedora|el10|debian|opensuse) ;; *) die "invalid --os: ${OS_KIND} (fedora, el10, debian or opensuse)" ;; esac

# Settings passed to server-init (read on its first run only). Values are checked, never quoted blindly.
ENV_NAMES="ADMIN_USER EXTRA_PORTS TIMEZONE INSTALL_DOCKER INSTALL_SWAP INSTALL_CLEANUP APP"
check_env() {
  local name value
  for name in $ENV_NAMES; do
    value="${!name:-}"
    [[ -z "$value" ]] && continue
    [[ "$value" =~ ^[A-Za-z0-9_./:\ -]+$ ]] || die "${name} has characters outside A-Z a-z 0-9 _ . / : - and space"
  done
}
check_env

TARGET="${SSH_USER}@${SERVER}"
SUDO=""   # prefix for remote commands, with a trailing space when set
if [[ "$SSH_USER" != root ]]; then SUDO="sudo -n "; fi
# Never empty, so "${SSH_OPTS[@]}" is safe under set -u on bash 3.2.
SSH_OPTS=(-p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30)
PORT_OPT=""
if [[ "$SSH_PORT" != 22 ]]; then PORT_OPT=" -p ${SSH_PORT}"; fi

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

# --- checks on the laptop ------------------------------------------------------------------------
check_local() {
  command -v ssh >/dev/null || die "ssh not found"
  command -v git >/dev/null || die "git not found"
  command -v tar >/dev/null || die "tar not found"
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "${REPO_ROOT} is not a git repository"
  [[ -f "${REPO_ROOT}/server/install-tools.sh" ]] || die "server/install-tools.sh not found in ${REPO_ROOT}"
  if (( ! ALLOW_DIRTY )) && [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]]; then
    die "uncommitted changes in ${REPO_ROOT}: only HEAD is copied. Commit them, or use --allow-dirty to copy HEAD anyway"
  fi
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]]; then
    warn "working tree is dirty: the server gets HEAD, not your uncommitted changes"
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
  local rc=0 out
  out="$(ssh "${SSH_OPTS[@]}" "$TARGET" "${SUDO}cloud-init status --wait" 2>&1)" || rc=$?
  echo "$out"
  if (( rc == 255 )); then
    die "SSH failed while waiting for cloud-init"
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

# The server-init script that fits the OS: os-release ID and VERSION_ID, as the scripts themselves check them.
detect_os() {
  [[ -z "$OS_KIND" ]] || { log "OS: ${OS_KIND} (from --os)"; return 0; }
  if (( DRY_RUN )); then
    log "[dry-run] would read ID and VERSION_ID from /etc/os-release on the server and pick fedora, el10, debian or opensuse"
    OS_KIND="<detected>"
    return 0
  fi
  local line id ver
  line="$(ssh "${SSH_OPTS[@]}" "$TARGET" '. /etc/os-release; echo "${ID:-}:${VERSION_ID:-}"')" || die "could not read /etc/os-release on the server"
  id="${line%%:*}"
  ver="${line#*:}"
  case "${id}:${ver%%.*}" in
    fedora:44) OS_KIND=fedora ;;
    centos:10|rocky:10|almalinux:10) OS_KIND=el10 ;;
    ubuntu:24|ubuntu:26|debian:13) OS_KIND=debian ;;
    opensuse-leap:16) OS_KIND=opensuse ;;
    *) die "no server-init script for ${line} (supported: Fedora 44, CentOS Stream/Rocky/AlmaLinux 10, Ubuntu 24.04/26.04, Debian 13, openSUSE Leap 16); a runner host is built with runner/bootstrap.sh" ;;
  esac
  log "OS: ${line} -> ${OS_KIND}"
}

# Replace the copy atomically: extract next to it, then swap, so no file of an old copy survives.
# Only server/ and common/ go to the server: it has no use for the runner files.
copy_repo() {
  local head script quoted
  head="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  script="set -e; d=${REMOTE_DIR}; rm -rf \"\$d.new\" \"\$d.old\"; install -d -m 0700 \"\$d.new\"; tar -x -C \"\$d.new\"; if [ -e \"\$d\" ]; then mv \"\$d\" \"\$d.old\"; fi; mv \"\$d.new\" \"\$d\"; rm -rf \"\$d.old\""
  quoted="$(q "$script")"
  local remote="${SUDO}sh -c ${quoted}"
  log "copying ${head} (git archive of server/ and common/, no .git, no credentials) to ${TARGET}:${REMOTE_DIR}"
  if (( DRY_RUN )); then
    log "[dry-run] git -C $(show "$REPO_ROOT") -c tar.umask=0022 archive --format=tar HEAD server common | $(show ssh "${SSH_OPTS[@]}" "$TARGET" "$remote")"
    return 0
  fi
  # tar.umask keeps the files from being group-writable on the server. Both pipeline statuses are
  # kept: if the remote side dies before reading, git gets SIGPIPE (141) and hides the real cause.
  local git_rc=0 ssh_rc=0 rcs=()
  set +e
  git -C "$REPO_ROOT" -c tar.umask=0022 archive --format=tar HEAD server common | ssh "${SSH_OPTS[@]}" "$TARGET" "$remote"
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
  ssh "${SSH_OPTS[@]}" "$TARGET" "${SUDO}test -f ${REMOTE_DIR}/server/install-tools.sh" || die "the copy on the server is incomplete"
}

# Remote command: run a script of the copy in its directory. Only checked, non-secret values go into it.
remote_command() {
  local script="$1" envs="" name value cmd
  if [[ "$script" == server/server-init-* ]]; then
    for name in $ENV_NAMES; do
      value="${!name:-}"
      [[ -z "$value" ]] || envs+=" ${name}=$(q "$value")"
    done
  fi
  cmd="cd ${REMOTE_DIR} &&${envs} bash ${script}"
  # /root is not readable for a non-root user: the whole line runs under sudo.
  if [[ -n "$SUDO" ]]; then cmd="${SUDO}bash -c $(q "$cmd")"; fi
  echo "$cmd"
}

run_remote() { run ssh "${SSH_OPTS[@]}" "$TARGET" "$1"; }

recheck_login() {
  log "re-checking SSH login for ${TARGET}"
  if (( DRY_RUN )); then log "[dry-run] $(show ssh "${SSH_OPTS[@]}" "$TARGET" true)"; return 0; fi
  ssh "${SSH_OPTS[@]}" "$TARGET" true \
    || die "SSH login for ${TARGET} no longer works after server-init. Use the Hetzner console and read /var/log/server-init-failed.log"
  log "login by key still works"
}

main() {
  check_local
  log "target: ${TARGET}:${SSH_PORT}, repo: ${REPO_ROOT} @ $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  log "never installed here: GitLab Runner (use runner/bootstrap.sh for a runner host)"

  if (( DRY_RUN )); then
    log "[dry-run] $(show ssh "${SSH_OPTS[@]}" "$TARGET" true)"
    log "[dry-run] $(show ssh "${SSH_OPTS[@]}" "$TARGET" "${SUDO}cloud-init status --wait")"
  else
    wait_for_ssh
    wait_cloud_init
  fi
  detect_os
  copy_repo

  local init="server/server-init-${OS_KIND}.sh"
  log "step 1: ${init} (SSH keys only, admin user, firewall, fail2ban, updates; root keeps key login)"
  run_remote "$(remote_command "$init")" || {
    warn "server-init failed (exit $?)"
    recheck_login
    die "server-init failed; SSH is still usable (checked above). Read /var/log/server-init-failed.log on the server, then rerun: every step is idempotent"
  }
  recheck_login

  case "$OS_KIND" in
    fedora|el10|"<detected>")
      log "step 2: server/install-tools.sh (srv, server-update, disk guard, health and its timers, login summary)"
      run_remote "$(remote_command server/install-tools.sh)"
      ;;
    *)
      log "step 2: server/install-health.sh (install-tools.sh needs dnf: Fedora and EL only)"
      run_remote "$(remote_command server/install-health.sh)"
      ;;
  esac

  log "health"
  local rc=0
  if (( DRY_RUN )); then
    run ssh "${SSH_OPTS[@]}" "$TARGET" "${SUDO}/usr/local/bin/health --no-color"
  else
    ssh "${SSH_OPTS[@]}" "$TARGET" "${SUDO}/usr/local/bin/health --no-color" || rc=$?
    if (( rc == 1 )); then warn "health reports warnings (exit 1)"; fi
    if (( rc >= 2 )); then warn "health reports failures (exit ${rc}); read the report above"; fi
  fi

  local DAILY="health -q"
  case "$OS_KIND" in fedora|el10) DAILY="srv status  and  health -q" ;; esac
  cat <<NEXT

[done] Next steps
  1. Test the admin login from a second terminal (ADMIN_USER is ops unless you changed it):
       ssh${PORT_OPT} ops@${SERVER} 'sudo -n true && echo ok'
  2. Root SSH by key is still open. To close it once step 1 works, on the server as ops (or your ADMIN_USER):
       sudo bash ${REMOTE_DIR}/server/lock-root.sh
  3. Daily use on the server:  ${DAILY}
  4. Later updates: rerun this script (it replaces the copy in ${REMOTE_DIR} and reruns the steps).
NEXT
}

main
