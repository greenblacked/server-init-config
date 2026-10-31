#!/usr/bin/env bash
# Helpers to run a distro image as a systemd machine in a privileged container (PID 1 = systemd, sshd on).
# Sourced by tools/ci/*-e2e.sh. Needs Docker; "privileged" is acceptable on a throwaway CI runner and nowhere else.
# shellcheck shell=bash
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# sd_family IMAGE -> apt | zypper | dnf
sd_family() {
  case "$1" in
    *debian* | *ubuntu*) echo apt ;;
    *opensuse* | *suse*) echo zypper ;;
    *) echo dnf ;;
  esac
}

# sd_build IMAGE TAG: derive an image with systemd, sshd, sudo and the tools the repo expects on a fresh cloud image.
# The images are minimal containers, so what a Hetzner image has by default is added here, and nothing the repo installs
# itself (firewall, fail2ban, Docker, ...) is pre-installed: that is what the test is about.
# cloud-init is replaced by a stub that reports "done", because bootstrap.sh waits for `cloud-init status --wait`
# and a container has no cloud-init run.
sd_build() {
  local image="$1" tag="$2" fam dir
  fam=$(sd_family "$image"); dir=$(mktemp -d)
  case "$fam" in
    apt) cat > "$dir/Dockerfile" <<DOCKER ;;
FROM ${image}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q && apt-get install -y -q --no-install-recommends systemd systemd-sysv dbus openssh-server sudo iproute2 procps curl ca-certificates tar gzip findutils cron kmod \
 && rm -rf /var/lib/apt/lists/* && ssh-keygen -A && systemctl enable ssh
DOCKER
    zypper) cat > "$dir/Dockerfile" <<DOCKER ;;
FROM ${image}
RUN zypper -n install --no-recommends systemd openssh-server sudo iproute2 procps curl ca-certificates tar gzip findutils diffutils kmod \
 && zypper clean -a && ssh-keygen -A && systemctl enable sshd
DOCKER
    dnf) cat > "$dir/Dockerfile" <<DOCKER ;;
FROM ${image}
RUN dnf -y install --setopt=install_weak_deps=False systemd openssh-server sudo iproute procps-ng ca-certificates tar gzip findutils diffutils kmod \
 && dnf clean all && ssh-keygen -A && systemctl enable sshd
DOCKER
  esac
  cat >> "$dir/Dockerfile" <<'DOCKER'
RUN printf '#!/bin/sh\n[ "$1" = status ] && echo "status: done"\nexit 0\n' > /usr/bin/cloud-init && chmod 0755 /usr/bin/cloud-init \
 && systemctl mask getty.target console-getty.service systemd-logind.service >/dev/null 2>&1 || true
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/lib/systemd/systemd"]
DOCKER
  docker build -t "$tag" "$dir" || { rm -rf "$dir"; return 1; }
  rm -rf "$dir"
}

# sd_relax_host_apparmor: the Ubuntu 24.04 runner host loads an AppArmor profile "unix-chkpwd" that attaches by path to
# /usr/sbin/unix_chkpwd. The kernel applies it inside our privileged containers too, so on EL10 (helper at that path) it
# denies dac_read_search/dac_override, pam_unix gets PAM_AUTHINFO_UNAVAIL and both sudo and sshd refuse the admin user
# ("could not obtain user info"). Fedora uses /usr/bin/unix_chkpwd and is not hit; real EL10 servers have no AppArmor.
# So this is a CI-environment artifact: drop the profile from the runner kernel (the VM is thrown away after the job).
# Idempotent; does nothing outside CI unless ALLOW_LOCAL=1, and never touches a developer's machine silently.
sd_relax_host_apparmor() {
  local profiles=/sys/kernel/security/apparmor/profiles
  [[ -r "$profiles" ]] || return 0
  grep -q '^unix-chkpwd ' "$profiles" 2>/dev/null || return 0
  if ! in_ci && [[ "${ALLOW_LOCAL:-0}" != 1 ]]; then
    log "WARN: host AppArmor profile unix-chkpwd is loaded and breaks sudo/ssh in EL10 containers; set ALLOW_LOCAL=1 to unload it"
    return 0
  fi
  log "unloading host AppArmor profile unix-chkpwd (CI runner only, see systemd-lib.sh)"
  sudo apparmor_parser -R /etc/apparmor.d/unix-chkpwd || log "WARN: could not unload unix-chkpwd; EL10 sudo/ssh tests may fail"
}

# sd_run NAME TAG [extra docker run args...]
sd_run() {
  local name="$1" tag="$2"; shift 2
  sd_relax_host_apparmor
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    --tmpfs /tmp --tmpfs /run --tmpfs /run/lock -e container=docker "$@" "$tag" >/dev/null
  # systemd is "running" or "degraded" (units that cannot work in a container); either is fine.
  local state=""
  for _ in $(seq 1 60); do
    state=$(docker exec "$name" systemctl is-system-running 2>/dev/null || true)
    case "$state" in running | degraded) log "systemd in ${name}: ${state}"; return 0 ;; esac
    sleep 2
  done
  docker logs "$name" 2>&1 | tail -20
  die "systemd in ${name} did not come up (state: ${state:-none})"
}

sd_exec() { local n="$1"; shift; docker exec "$n" "$@"; }
sd_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }

# sd_collect NAME DIR: journal, failed units and the repo's own failure logs, for the artifact.
sd_collect() {
  local n="$1" d="$2"
  mkdir -p "$d"
  docker exec "$n" journalctl --no-pager -n 400 > "$d/journal.txt" 2>&1 || true
  docker exec "$n" systemctl --failed --no-pager > "$d/failed-units.txt" 2>&1 || true
  docker exec "$n" sh -c 'cat /var/log/server-init-failed.log /var/log/ci-bootstrap-failed.log 2>/dev/null' > "$d/init-failed.log" 2>&1 || true
  docker exec "$n" sh -c 'cat /tmp/health-*.txt 2>/dev/null' > "$d/health.txt" 2>&1 || true
}
