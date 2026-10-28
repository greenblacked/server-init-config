#!/usr/bin/env bash
# Shared helpers for install/*.sh. Sourced, not executed.
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

# Label a directory so containers may read files in it (no-op without SELinux).
selinux_label_dir() {
  local dir="$1"
  install -d -m 0755 "$dir"
  selinux_on || return 0
  command -v semanage >/dev/null 2>&1 || pkg_install policycoreutils-python-utils
  if ! semanage fcontext -l | grep -q "^${dir}(/\.\*)?"; then
    semanage fcontext -a -t container_file_t "${dir}(/.*)?"
  fi
  restorecon -R "$dir"
}

restorecon_if() { if command -v restorecon >/dev/null 2>&1; then restorecon "$@" || true; fi; }

ci_jobs_running() { docker ps -q --filter "label=com.gitlab.gitlab-runner.managed=true" 2>/dev/null | wc -l; }

require_runner_idle() {
  local n
  n=$(ci_jobs_running)
  (( n == 0 )) || die "${n} CI job container(s) running, retry when the runner is idle"
}

backup() { cp -a "$1" "${1}.bak.$(date +%Y%m%d-%H%M%S)"; }

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
}
