#!/usr/bin/env bash
# Per-job CPU, memory, swap and /dev/shm limits in [runners.docker] of /etc/gitlab-runner/config.toml, plus a systemd
# slice (ci-jobs.slice) that caps the process count and, optionally, the memory of ALL job containers together, so
# one job cannot take the whole host. The limits cover the build container and its `services:` containers (postgres,
# redis, ...). Backs up the file, changes only these keys, and is safe to rerun. A value you already set in
# config.toml is kept unless you pass it in the environment. Swap follows memory (no swap) unless JOB_MEMORY_SWAP
# (JOB_SERVICE_MEMORY_SWAP) is given or the file already has a memory_swap (service_memory_swap).
#
# GitLab Runner has no per-container process limit, so processes are limited per host through the slice: the jobs
# together can start at most JOBS_TASKS_MAX processes and threads (default 4096), and a fork bomb ends there instead of
# exhausting the host. JOBS_MEMORY_MAX (default 3g) is a ceiling for all job containers together; "" or "infinity" turns it off.
#
# Defaults suit a CAX11 (2 vCPU, 4 GB RAM) with concurrent = 2: two jobs at 1.5 CPU and 1.5 GB, services at 384 MB,
# and a 3 GB ceiling for all of them leave about 1 GB for the host and its stacks. A bigger host: raise JOB_MEMORY,
# JOB_CPUS and JOBS_MEMORY_MAX and keep concurrent x limit below the hardware. A job that needs more fails with an
# out-of-memory kill (exit 137) instead of freezing the host.
# gitlab-runner reloads config.toml by itself; running jobs keep their old limits, new jobs get the new ones.
#
# Env: JOB_MEMORY (default 1536m), JOB_MEMORY_SWAP (default = JOB_MEMORY, i.e. no swap), JOB_CPUS (default 1.5),
#      JOB_SHM_SIZE in bytes (default 268435456), JOB_SERVICE_MEMORY (default 384m), JOB_SERVICE_MEMORY_SWAP
#      (default = JOB_SERVICE_MEMORY), JOB_SERVICE_CPUS (default 0.5), JOBS_TASKS_MAX (default 4096),
#      JOBS_MEMORY_MAX (default 3g)
set -Eeuo pipefail
# shellcheck source=../../common/lib.sh
source "$(dirname "$0")/../../common/lib.sh"

CFG="${RUNNER_CONFIG:-/etc/gitlab-runner/config.toml}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
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
shm_default="${JOB_SHM_SIZE:-268435456}"
[[ "$shm_default" =~ ^[0-9]+$ ]] || die "invalid JOB_SHM_SIZE: ${shm_default}"
smem_default="${JOB_SERVICE_MEMORY:-384m}"
[[ "$smem_default" =~ ^[0-9]+[kmg]$ ]] || die "invalid JOB_SERVICE_MEMORY: ${smem_default}"
sswap_default="${JOB_SERVICE_MEMORY_SWAP:-$smem_default}"
[[ "$sswap_default" =~ ^[0-9]+[kmg]$ ]] || die "invalid JOB_SERVICE_MEMORY_SWAP: ${sswap_default}"
scpus_default="${JOB_SERVICE_CPUS:-0.5}"
[[ "$scpus_default" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "invalid JOB_SERVICE_CPUS: ${scpus_default}"
tasks_max="${JOBS_TASKS_MAX:-4096}"
[[ "$tasks_max" =~ ^[0-9]+$ ]] || die "invalid JOBS_TASKS_MAX: ${tasks_max}"
mem_max="${JOBS_MEMORY_MAX-3g}"
[[ -z "$mem_max" || "$mem_max" == "infinity" || "$mem_max" =~ ^[0-9]+[KMGkmg]?$ ]] || die "invalid JOBS_MEMORY_MAX: ${mem_max} (for example 3g)"

# The slice is the parent cgroup of every job and service container (Docker uses the systemd cgroup driver on these hosts).
slice="${JOBS_SLICE_FILE:-/etc/systemd/system/ci-jobs.slice}"
slice_tmp=$(mktemp)
tmp=$(mktemp)
trap 'rm -f "$tmp" "$slice_tmp"' EXIT
{
  echo "# Written by runner/install/job-limits.sh: ceiling for all CI job containers together."
  echo "[Slice]"
  echo "TasksMax=${tasks_max}"
  if [[ -n "$mem_max" && "$mem_max" != "infinity" ]]; then echo "MemoryMax=${mem_max}"; fi
} > "$slice_tmp"
if ! cmp -s "$slice_tmp" "$slice" 2>/dev/null; then
  install -m 0644 "$slice_tmp" "$slice"
  systemctl daemon-reload 2>/dev/null || true
  log "wrote ${slice}"
fi

# Lines: key, value, force (1 when the environment gave the value: it then replaces what config.toml has).
# memory_swap and service_memory_swap follow their memory key when neither is set.
specs=$(printf '%s\t%s\t%s\n' \
  memory "\"${mem_default}\"" "${JOB_MEMORY:+1}" \
  memory_swap "\"${swap_default}\"" "${JOB_MEMORY_SWAP:+1}${JOB_MEMORY:+1}" \
  cpus "\"${cpus_default}\"" "${JOB_CPUS:+1}" \
  shm_size "${shm_default}" "${JOB_SHM_SIZE:+1}" \
  cgroup_parent '"ci-jobs.slice"' 1 \
  service_memory "\"${smem_default}\"" "${JOB_SERVICE_MEMORY:+1}" \
  service_memory_swap "\"${sswap_default}\"" "${JOB_SERVICE_MEMORY_SWAP:+1}${JOB_SERVICE_MEMORY:+1}" \
  service_cpus "\"${scpus_default}\"" "${JOB_SERVICE_CPUS:+1}" \
  service_cgroup_parent '"ci-jobs.slice"' 1)
awk -v specs="$specs" '
  function flush(   k) {
    if (!insec) return
    # Without its own value, swap follows the memory limit of this section (swap below memory is rejected by Docker).
    if (!seen["memory_swap"] && curmem != "") vals["memory_swap"] = curmem
    if (!seen["service_memory_swap"] && cursmem != "") vals["service_memory_swap"] = cursmem
    for (k = 1; k <= n; k++) if (!seen[names[k]]) print "    " names[k] " = " vals[names[k]]
    insec = 0
  }
  function val(line,   v) { v = line; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]*#.*$/, "", v); return v }
  BEGIN {
    n = split(specs, lines, "\n")
    for (i = 1; i <= n; i++) { split(lines[i], f, "\t"); names[i] = f[1]; vals[f[1]] = f[2]; force[f[1]] = f[3] }
  }
  /^[[:space:]]*\[/ { flush() }
  /^[[:space:]]*\[runners\.docker\][[:space:]]*$/ { insec = 1; curmem = ""; cursmem = ""; split("", seen); print; next }
  insec {
    # pids_limit is not a GitLab Runner key (an older version of this script wrote it): drop it.
    if ($0 ~ "^[[:space:]]*pids_limit[[:space:]]*=") next
    for (k = 1; k <= n; k++) {
      nm = names[k]
      if ($0 ~ "^[[:space:]]*" nm "[[:space:]]*=") {
        seen[nm] = 1
        if (nm == "memory") curmem = val($0)
        if (nm == "service_memory") cursmem = val($0)
        if (force[nm]) { if (nm == "memory") curmem = vals[nm]; if (nm == "service_memory") cursmem = vals[nm]; print "    " nm " = " vals[nm]; next }
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
awk '/^[[:space:]]*\[runners\.docker\]/ { s = 1; next } /^[[:space:]]*\[/ { s = 0 } s && /^[[:space:]]*(memory|memory_swap|cpus|shm_size|cgroup_parent|service_[a-z_]+)[[:space:]]*=/' "$CFG"
