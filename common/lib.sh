#!/usr/bin/env bash
# Shared helpers for the installers (runner/install, server and common). Sourced, not executed.
# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "run as root"; }

selinux_on() { command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled; }

pkg_install() {
  if command -v dnf >/dev/null 2>&1; then
    dnf -y -q install "$@"
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -q && apt-get install -y -q "$@"
  else
    die "no supported package manager"
  fi
}

# cmp (diffutils) is missing on minimal hosts but the installers compare files with it; fetch it when run as root.
if [[ $EUID -eq 0 ]] && ! command -v cmp >/dev/null 2>&1; then pkg_install diffutils >/dev/null || log "WARN: diffutils not installed, cmp is missing"; fi

# Label a directory so containers may read files in it (no-op without SELinux).
selinux_label_dir() {
  local dir="$1"
  install -d -m 0755 "$dir"
  selinux_on || return 0
  command -v semanage >/dev/null 2>&1 || pkg_install policycoreutils-python-utils
  # Read the whole list first: grep -q exits at the first match and would SIGPIPE the producer under pipefail.
  if ! grep -q "^${dir}(/\.\*)?" <<<"$(semanage fcontext -l)"; then
    semanage fcontext -a -t container_file_t "${dir}(/.*)?"
  fi
  restorecon -R "$dir"
}

restorecon_if() { if command -v restorecon >/dev/null 2>&1; then restorecon "$@" || true; fi; }

# RHEL-family sudo resets PATH to secure_path, which can leave out /usr/local/bin (so `sudo health` fails).
# Adds a validated drop-in unless some sudoers file already sets a secure_path that includes it.
ensure_secure_path() {
  local f=/etc/sudoers.d/50-secure-path tmp
  command -v visudo >/dev/null 2>&1 || return 0
  if grep -rhsE '^[[:space:]]*Defaults[[:space:]]+secure_path[[:space:]]*=.*/usr/local/bin' /etc/sudoers /etc/sudoers.d 2>/dev/null | grep -q .; then
    return 0
  fi
  if ! grep -rhsE '^[[:space:]]*Defaults[[:space:]]+secure_path' /etc/sudoers /etc/sudoers.d 2>/dev/null | grep -q .; then
    return 0   # no secure_path at all (Debian family keeps it in sudoers; others use the caller PATH)
  fi
  tmp=$(mktemp)
  printf 'Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n' > "$tmp"
  if visudo -cqf "$tmp"; then
    install -d -m 0750 /etc/sudoers.d
    install -m 0440 -o root -g root "$tmp" "$f"
    log "sudo secure_path now includes /usr/local/bin (${f})"
  else
    echo "WARN: generated sudoers drop-in is invalid, secure_path left as it was" >&2
  fi
  rm -f "$tmp"
}

# version_ge HAVE WANT: true when dotted version HAVE >= WANT (numeric, sort -V).
version_ge() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$2" ]]; }

# require_compose_min WANT WHAT: die before anything is changed when the Docker Compose plugin is older than WANT.
# Why: a stack that needs a newer compose would otherwise fail later at "docker compose config", mid-update.
require_compose_min() {
  local want=$1 what=$2 have
  have=$(docker compose version --short 2>/dev/null || true)
  have=${have#v}
  have=${have%%[!0-9.]*}
  [[ -n "$have" ]] || die "${what} needs Docker Compose ${want} or newer, but 'docker compose version' gives no answer: install the docker-compose-plugin"
  version_ge "$have" "$want" || die "${what} needs Docker Compose ${want} or newer (inline 'configs: content:'), found ${have}: update the docker-compose-plugin package (or Docker Engine) first, then rerun"
}

# Containers that count as a running CI job: GitLab Runner job/service containers and the pods of the GitHub Actions runner
# (runner/scripts/github-runner-ctl labels both of its containers io.server-init.github-runner=job).
CI_JOB_LABELS=(com.gitlab.gitlab-runner.managed=true io.server-init.github-runner=job)
# Ids of those containers, one per line; fails when docker does not answer (that is not "no jobs").
ci_job_ids() { local l ids=""; for l in "${CI_JOB_LABELS[@]}"; do ids+="$(docker ps -q --filter "label=${l}")"$'\n' || return; done; sed '/^$/d' <<<"$ids" | sort -u; }
ci_jobs_running() { ci_job_ids 2>/dev/null | wc -l; }

require_runner_idle() {
  local n
  n=$(ci_jobs_running)
  (( n == 0 )) || die "${n} CI job container(s) running, retry when the runner is idle"
}

# Timestamped copy before a change. Skipped when an identical backup already exists, so reruns of an idempotent
# installer do not pile up copies of an unchanged file.
backup() {
  local f=$1 b
  for b in "${f}".bak.*; do
    [[ -f "$b" ]] && cmp -s "$f" "$b" && return 0
  done
  cp -a "$f" "${f}.bak.$(date +%Y%m%d-%H%M%S)"
}

# edit_with_backup FILE CMD...  runs CMD (which edits FILE in place) and keeps a timestamped copy of the previous content,
# but only when CMD changed the file, so a rerun of an idempotent installer leaves no .bak with the same content as FILE.
edit_with_backup() {
  local f=$1 bak; shift
  # The snapshot lives next to FILE (cp -a keeps its mode), never in /tmp: it can hold a token, and a CMD that dies leaves it behind.
  # mktemp makes the name unique, so a second call on the same file in the same second cannot overwrite (and then delete) the
  # first call's backup of the original content.
  bak=$(mktemp "${f}.bak.$(date +%Y%m%d-%H%M%S).XXXXXX")
  cp -a "$f" "$bak"
  "$@"
  if cmp -s "$f" "$bak"; then rm -f "$bak"; fi
}

# Prometheus scrape jobs for the logging stack, shared by runner/install/logging.sh and runner/install/update.sh.
prom_jobs_logging() {
  cat <<'YAML'
  - job_name: loki
    static_configs:
      - targets: ["127.0.0.1:3100"]
  - job_name: alloy
    static_configs:
      - targets: ["127.0.0.1:12345"]
YAML
}

# Merge KEY=VALUE entries into the single [[runners]] environment line of config.toml.
runner_env_merge() {
  local cfg=/etc/gitlab-runner/config.toml existing list key e line
  [[ $(grep -c '^\[\[runners\]\]' "$cfg") -eq 1 ]] || die "expected exactly one [[runners]] block in $cfg"
  existing=$(grep -E '^  environment = \[' "$cfg" | sed -E 's/^  environment = \[(.*)\]$/\1/' || true)
  list="$existing"
  for e in "$@"; do
    key="${e%%=*}"
    if grep -q "\"${key}=" <<<"$list"; then
      list=$(sed -E "s|\"${key}=[^\"]*\"|\"${e}\"|" <<<"$list")
    else
      list="${list:+${list}, }\"${e}\""
    fi
  done
  line="  environment = [${list}]"
  if grep -qE '^  environment = \[' "$cfg"; then
    sed -i -E "s|^  environment = \[.*\]$|${line}|" "$cfg"
  else
    sed -i -E "0,/^  executor = .*/s||${line}\n&|" "$cfg"
  fi
  chmod 600 "$cfg"
  runner_cfg_owner
}

# When the runner service runs as gitlab-runner (runner/install/users.sh), it must own its config after root edits it.
runner_cfg_owner() {
  local cfg=/etc/gitlab-runner/config.toml
  if [[ -f /etc/systemd/system/gitlab-runner.service.d/10-service-user.conf ]] && id gitlab-runner >/dev/null 2>&1; then
    chown -R gitlab-runner:gitlab-runner /etc/gitlab-runner
    chmod 600 "$cfg"
  fi
}

# --- service user for the monitoring and logging stacks (created by runner/install/users.sh) ---------------
MON_USER="${MON_USER:-monitoring}"

# Set MON_UID and MON_GID, or stop if the service user is missing.
mon_ids() {
  id "$MON_USER" >/dev/null 2>&1 || die "service user ${MON_USER} missing, run runner/install/users.sh first"
  MON_UID=$(id -u "$MON_USER")
  MON_GID=$(id -g "$MON_USER")
}

# env_set FILE KEY VALUE: set KEY=VALUE in a root-only env file.
env_set() {
  local f="$1" k="$2" v="$3"
  touch "$f"
  chmod 600 "$f"
  if grep -q "^${k}=" "$f"; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$f"
  else
    printf '%s=%s\n' "$k" "$v" >> "$f"
  fi
}

# stack_ids DIR [logging]: write the ids the compose file needs into DIR/.env.
stack_ids() {
  local dir="$1" docker_gid journal_gid
  mon_ids
  env_set "${dir}/.env" MON_UID "$MON_UID"
  env_set "${dir}/.env" MON_GID "$MON_GID"
  if [[ "${2:-}" == logging ]]; then
    docker_gid=$(getent group docker | cut -d: -f3)
    [[ -n "$docker_gid" ]] || die "docker group missing"
    env_set "${dir}/.env" DOCKER_GID "$docker_gid"
    journal_gid=$(getent group systemd-journal | cut -d: -f3)
    [[ -n "$journal_gid" ]] || die "systemd-journal group missing"
    # compose rejects equal group_add items, so the journal group is only added when it differs from docker's.
    if [[ "$journal_gid" != "$docker_gid" ]]; then
      printf 'services:\n  alloy:\n    group_add:\n      - "%s"\n' "$journal_gid" > "${dir}/docker-compose.override.yml"
    else
      rm -f "${dir}/docker-compose.override.yml"
    fi
  fi
}

# Config readable by the service user, writable by root only; .env (secrets) stays root-only.
own_stack_dir() {
  local dir="$1"
  chown -R "root:${MON_USER}" "$dir"
  chmod -R u=rwX,g=rX,o= "$dir"
  if [[ -f "${dir}/.env" ]]; then
    chown root:root "${dir}/.env"
    chmod 600 "${dir}/.env"
  fi
}

# Helper container that runs as root next to stack volumes (chown_volumes, the Grafana backup, the README restore command).
# The single pin: alpine 3.20 is end of life. Pinned by the digest of the multi-arch index (amd64 and arm64), so a moved tag cannot change
# what runs as root next to the data. Bump tag and digest here only; every copy must carry the same string (tools/ci/check-pins.sh enforces it): runner/README.md (restore command), runner/ci/smoke.yml,
# runner/ci/mirror-images.yml, tools/ci/runner-container.sh and the generated runner/COMMANDS.md.
HELPER_IMAGE="alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f"

# Create the stack's containers and volumes without starting them, then hand the volumes to the service user.
chown_volumes() {
  local dir="$1" project v
  mon_ids
  project=$(cd "$dir" && docker compose config --format json | jq -r .name)
  (cd "$dir" && docker compose up --no-start --quiet-pull >/dev/null 2>&1) || (cd "$dir" && docker compose up --no-start >/dev/null)
  for v in $(docker volume ls -q --filter "label=com.docker.compose.project=${project}"); do
    # root in the helper only needs to chown and to enter other users' 0700 trees: no network, read-only rootfs, two capabilities, no setuid escalation, symlinks are not followed (-h)
    docker run --rm --network none --read-only --cap-drop ALL --cap-add CHOWN --cap-add DAC_READ_SEARCH \
      --security-opt no-new-privileges \
      -v "${v}:/v" "$HELPER_IMAGE" chown -Rh "${MON_UID}:${MON_GID}" /v
  done
}
