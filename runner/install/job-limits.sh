#!/usr/bin/env bash
# Per-job CPU, memory, swap, process and /dev/shm limits in [runners.docker] of /etc/gitlab-runner/config.toml,
# so one job cannot take the whole host. Backs up the file, changes only these keys, and is safe to rerun.
# A value you already set in config.toml is kept unless you pass it in the environment. Swap follows memory
# (no swap) unless JOB_MEMORY_SWAP is given or the file already has a memory_swap.
#
# Defaults suit a CAX11 (2 vCPU, 4 GB RAM) with concurrent = 2: two jobs at 1.5 CPU and 1.5 GB leave about 1 GB for
# the host and its stacks. A bigger host: raise JOB_MEMORY and JOB_CPUS and keep concurrent x limit below the hardware.
# A job that needs more fails with an out-of-memory kill (exit 137) instead of freezing the host.
# gitlab-runner reloads config.toml by itself; running jobs keep their old limits, new jobs get the new ones.
#
# Env: JOB_MEMORY (default 1536m), JOB_MEMORY_SWAP (default = JOB_MEMORY, i.e. no swap), JOB_CPUS (default 1.5),
#      JOB_PIDS (default 2048), JOB_SHM_SIZE in bytes (default 268435456)
set -Eeuo pipefail
# shellcheck source=../../common/lib.sh
source "$(dirname "$0")/../../common/lib.sh"

CFG="${RUNNER_CONFIG:-/etc/gitlab-runner/config.toml}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
require_root
[[ -f "$CFG" ]] && grep -q '^[[:space:]]*\[runners.docker\]' "$CFG" || die "no [runners.docker] section in ${CFG}: register the runner first (runner/install/register-runner.sh)"

mem_default="${JOB_MEMORY:-1536m}"
[[ "$mem_default" =~ ^[0-9]+[kmg]$ ]] || die "invalid JOB_MEMORY: ${mem_default} (for example 1536m)"
swap_default="${JOB_MEMORY_SWAP:-$mem_default}"
[[ "$swap_default" =~ ^[0-9]+[kmg]$ ]] || die "invalid JOB_MEMORY_SWAP: ${swap_default}"
cpus_default="${JOB_CPUS:-1.5}"
[[ "$cpus_default" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "invalid JOB_CPUS: ${cpus_default}"
pids_default="${JOB_PIDS:-2048}"
[[ "$pids_default" =~ ^[0-9]+$ ]] || die "invalid JOB_PIDS: ${pids_default}"
shm_default="${JOB_SHM_SIZE:-268435456}"
[[ "$shm_default" =~ ^[0-9]+$ ]] || die "invalid JOB_SHM_SIZE: ${shm_default}"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
# FORCE_<key>=1 when the environment gave the value: it then replaces what config.toml has.
awk -v mem="\"${mem_default}\"" -v swap="\"${swap_default}\"" -v cpus="\"${cpus_default}\"" -v pids="$pids_default" -v shm="$shm_default" \
    -v fmem="${JOB_MEMORY:+1}" -v fswap="${JOB_MEMORY_SWAP:+1}${JOB_MEMORY:+1}" -v fcpus="${JOB_CPUS:+1}" -v fpids="${JOB_PIDS:+1}" -v fshm="${JOB_SHM_SIZE:+1}" '
  function flush(   k) {
    if (!insec) return
    # Without its own value, swap follows the memory limit of this section (swap below memory is rejected by Docker).
    if (!seen[2] && curmem != "") vals[2] = curmem
    for (k = 1; k <= 5; k++) if (!seen[k]) print "    " names[k] " = " vals[k]
    insec = 0
  }
  BEGIN {
    names[1] = "memory";      vals[1] = mem;  force[1] = fmem
    names[2] = "memory_swap"; vals[2] = swap; force[2] = fswap
    names[3] = "cpus";        vals[3] = cpus; force[3] = fcpus
    names[4] = "pids_limit";  vals[4] = pids; force[4] = fpids
    names[5] = "shm_size";    vals[5] = shm;  force[5] = fshm
  }
  /^[[:space:]]*\[/ { flush() }
  /^[[:space:]]*\[runners\.docker\][[:space:]]*$/ { insec = 1; curmem = ""; split("", seen); print; next }
  insec {
    for (k = 1; k <= 5; k++) {
      if ($0 ~ "^[[:space:]]*" names[k] "[[:space:]]*=") {
        seen[k] = 1
        if (k == 1) { curmem = $0; sub(/^[^=]*=[[:space:]]*/, "", curmem); sub(/[[:space:]]*#.*$/, "", curmem) }
        if (force[k]) { if (k == 1) curmem = vals[1]; print "    " names[k] " = " vals[k]; next }
      }
    }
  }
  { print }
  END { flush() }
' "$CFG" > "$tmp"

if cmp -s "$tmp" "$CFG"; then
  log "job limits already set in ${CFG}"
else
  backup "$CFG"
  cat "$tmp" > "$CFG"
  log "job limits written to ${CFG}"
fi
awk '/^[[:space:]]*\[runners\.docker\]/ { s = 1; next } /^[[:space:]]*\[/ { s = 0 } s && /^[[:space:]]*(memory|memory_swap|cpus|pids_limit|shm_size)[[:space:]]*=/' "$CFG"
