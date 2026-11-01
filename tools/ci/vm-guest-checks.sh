#!/usr/bin/env bash
# Checks INSIDE the test VM (as root), fed over ssh by tools/ci/vm-e2e.sh:
#   ssh root@VM bash -s -- ROLE KIND PHASE < tools/ci/vm-guest-checks.sh
#   ROLE   server | runner
#   KIND   server: el10 | fedora | debian | opensuse;  runner: rocky | debian
#   PHASE  first (right after cloud-init) | reboot (after the VM was rebooted: what must come back by itself)
# What a container cannot show: swap, kernel tuning, Docker with a real kernel, the firewall on its own netfilter, units
# enabled at boot. Prints PASS/FAIL/WARN lines and ends with CHECKS-DONE; exits 1 when something failed.
set -uo pipefail
ROLE="${1:?role}"
KIND="${2:?kind}"
PHASE="${3:?phase}"
fails=0
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; echo "::error::$PHASE: $*"; fails=$((fails + 1)); }
warn() { echo "  WARN  $*"; echo "::warning::$PHASE: $*"; }
# ok DESC CMD...   (stdout and stderr of the command are dropped)
ok() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }
# retry SECONDS CMD...   the command may need a moment after boot (units are started in parallel)
retry() { local n=$1 i; shift; for ((i = 0; i < n; i++)); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
okw() { local d="$1" n="$2"; shift 2; if retry "$n" "$@"; then pass "$d"; else fail "$d"; return 1; fi; }

echo "== ${ROLE} ${KIND}, phase ${PHASE}: $(. /etc/os-release; echo "${PRETTY_NAME:-$ID}"), kernel $(uname -r), boot $(cat /proc/sys/kernel/random/boot_id | cut -c1-8)"

# Every "key = value" line of a sysctl.d file must be what the running kernel reports; a leading "-" means "ignore a key this
# kernel does not have", so such a key is compared only when it exists.
squeeze_ws() { tr -s '[:space:]' ' ' <<<"$1" | sed -E 's/^ //; s/ $//'; }

sysctl_file() { # file
  local f=$1 line key val got n=0 skipped=0
  [[ -f "$f" ]] || { fail "$f is missing"; return; }
  while IFS= read -r line; do
    line=${line%%#*}
    [[ "$line" == *=* ]] || continue
    key=$(sed -E 's/^[[:space:]]*-?[[:space:]]*([^=[:space:]]+).*/\1/' <<<"$line")
    val=$(sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]+$//' <<<"$line")
    if ! got=$(sysctl -n "$key" 2>/dev/null); then
      if [[ "$line" =~ ^[[:space:]]*- ]]; then skipped=$((skipped + 1)); continue; fi
      fail "sysctl ${key}: key does not exist in this kernel"; continue
    fi
    # Normalise both sides alike: collapse runs of blanks/tabs (multi-value keys such as tcp_rmem) and trim the ends; a here-string
    # appends a newline, so each side is trimmed after the squeeze, not just the live one.
    got=$(squeeze_ws "$got"); val=$(squeeze_ws "$val")
    if [[ "$got" == "$val" ]]; then n=$((n + 1)); else fail "sysctl ${key} = ${got} (${f} says ${val})"; fi
  done < "$f"
  if (( n > 0 )); then pass "sysctl: ${n} value(s) from ${f} are live (${skipped} optional key(s) absent)"; else fail "sysctl: no value of ${f} could be checked"; fi
}

# Why Docker is down, in the log of the run that sees it (the journal of the key units is also collected at the end).
docker_diag() {
  echo "  --- docker is down: kernel $(uname -r); installed: $(rpm -q kernel-core 2>&1 | tr '\n' ' ')"
  { systemctl status docker docker.socket containerd -l --no-pager 2>&1 | head -40
    journalctl -b -u docker -u docker.socket -u containerd --no-pager -n 60 2>&1; } | cut -c1-300 | sed 's/^/  docker: /'
}

docker_works() {
  okw "docker.service is active" 60 systemctl is-active --quiet docker || docker_diag
  ok "docker daemon answers (docker info)" docker info
  ok "docker compose plugin works" docker compose version
  local img out
  # Docker Hub rate-limits anonymous pulls by IP, so the Google mirror of the library images goes first.
  for img in mirror.gcr.io/library/hello-world docker.io/library/hello-world; do
    if out=$(timeout 180 docker run --rm "$img" 2>&1) && grep -q 'Hello from Docker' <<<"$out"; then pass "docker run ${img}"; return; fi
  done
  fail "docker run hello-world failed on both registries: $(tail -3 <<<"$out" | tr '\n' ' ')"
}

# "ufw reload" re-runs ufw's own sysctl.conf (log_martians=0): our after.init hook must put the values back, and ufw's
# conffile must still be what dpkg shipped. Runs in both phases (after the first boot and after the reboot).
ufw_reload_checks() {
  local k out
  ok "ufw's stock sysctl.conf sets log_martians=0 (so the reload really resets them)" grep -Eq '^net/ipv4/conf/(all|default)/log_martians=0' /etc/ufw/sysctl.conf
  ok "/etc/ufw/after.init is our executable hook" bash -c "[[ -x /etc/ufw/after.init ]] && grep -qxF '# server-init: ufw-reload-hook (re-applies sysctl.d/90-server.conf)' /etc/ufw/after.init"
  ok "ufw reload succeeds" ufw reload
  for k in all default; do
    [[ $(sysctl -n "net.ipv4.conf.${k}.log_martians" 2>/dev/null) == 1 ]] && pass "log_martians (${k}) is 1 after ufw reload" || fail "log_martians (${k}) is not 1 after ufw reload"
  done
  ok "ufw is still active after the reload" bash -c "ufw status | grep -q '^Status: active'"
  # dpkg --verify lists changed files; "??5" means the md5 differs. Its exit status is 1 for any change (our after.init is one),
  # so only the /etc/ufw/sysctl.conf line counts; the conffile must also be known to dpkg or the test proves nothing.
  out=$(dpkg --verify ufw 2>&1)
  if grep -q '^..5.*/etc/ufw/sysctl\.conf$' <<<"$out"; then fail "/etc/ufw/sysctl.conf differs from dpkg's md5"; else pass "/etc/ufw/sysctl.conf is unmodified (dpkg --verify ufw)"; fi
  ok "dpkg knows /etc/ufw/sysctl.conf as a ufw conffile" bash -c "dpkg-query -W -f='\${Conffiles}\n' ufw | grep -q '^ /etc/ufw/sysctl\.conf '"
  if command -v debsums >/dev/null; then ok "debsums -ce ufw reports no changed conffile" bash -c "! debsums -ce ufw 2>&1 | grep -q 'sysctl\.conf'"; fi
}

timers_enabled() { local u; for u in "$@"; do ok "${u} is enabled" systemctl is-enabled --quiet "$u"; done; }

server_checks() {
  ok "sshd is active" systemctl is-active --quiet sshd ssh
  # swap: "if none" in the init; cloud images mostly have none, Fedora has zram. Either way it must be active and counted.
  local swap_kb
  swap_kb=$(awk 'NR > 1 { s += $3 } END { print s + 0 }' /proc/swaps)
  if (( swap_kb > 0 )); then pass "swap is active ($(awk 'NR > 1 { printf "%s %s kB; ", $1, $3 }' /proc/swaps))"; else fail "no active swap (/proc/swaps is empty)"; fi
  if [[ -f /swapfile ]]; then
    grep -qE '^/swapfile[[:space:]]+none[[:space:]]+swap' /etc/fstab && pass "/swapfile is in fstab (survives the reboot)" || fail "/swapfile is not in /etc/fstab"
    [[ $(stat -c %a /swapfile) == 600 ]] && pass "/swapfile mode 600" || fail "/swapfile mode is $(stat -c %a /swapfile), not 600"
  fi
  sysctl_file /etc/sysctl.d/90-server.conf
  docker_works
  case "$KIND" in
    debian)
      ok "ufw is active" bash -c "ufw status | grep -q '^Status: active'"
      ok "ufw allows 22/tcp" bash -c "ufw status | grep -qE '^22(/tcp)? +ALLOW'"
      ok "ufw is enabled at boot" systemctl is-enabled --quiet ufw
      ufw_reload_checks
      timers_enabled apt-daily.timer apt-daily-upgrade.timer ;;
    *)
      okw "firewalld is active" 60 systemctl is-active --quiet firewalld
      ok "firewalld is enabled at boot" systemctl is-enabled --quiet firewalld
      okw "firewalld public zone allows ssh" 30 firewall-cmd --zone=public --query-service=ssh
      ok "nftables ruleset exists (firewalld backend)" bash -c "nft list ruleset | grep -q 'table inet firewalld'"
      timers_enabled server-cleanup.timer
      case "$KIND" in
        opensuse) timers_enabled server-security-updates.timer ;;
        fedora) if systemctl is-enabled --quiet dnf5-automatic.timer 2>/dev/null; then pass "dnf5-automatic.timer is enabled"; else timers_enabled dnf-automatic.timer; fi ;;
        *) timers_enabled dnf-automatic.timer ;;
      esac ;;
  esac
  okw "fail2ban is active" 60 systemctl is-active --quiet fail2ban
  okw "fail2ban has the sshd jail" 60 bash -c "fail2ban-client status 2>/dev/null | grep -q sshd"
  ok "fail2ban is enabled at boot" systemctl is-enabled --quiet fail2ban
  ok "sshd: password login is off" bash -c "sshd -T | grep -qi '^passwordauthentication no'"
}

runner_checks() {
  ok "sshd is active" systemctl is-active --quiet sshd ssh
  sysctl_file /etc/sysctl.d/90-ci-hardening.conf
  docker_works
  ok "gitlab-runner is installed ($(gitlab-runner --version 2>/dev/null | sed -n 's/^Version: *//p'))" gitlab-runner --version
  [[ $(stat -c %a /etc/gitlab-runner/config.toml 2>/dev/null) == 600 ]] && pass "config.toml mode 600" || fail "/etc/gitlab-runner/config.toml is missing or not mode 600"
  grep -q '\[\[runners\]\]' /etc/gitlab-runner/config.toml 2>/dev/null && fail "config.toml lists a registered runner: this test must never register one" || pass "no runner is registered (config.toml has no [[runners]])"
  timers_enabled runner-weekly-cleanup.timer runner-disk-guard.timer runner-engine-update.timer
  okw "ci-job-isolation.service is active" 90 systemctl is-active --quiet ci-job-isolation.service
  okw "DOCKER-USER drops the metadata address" 60 bash -c "iptables -S DOCKER-USER | grep -q 'ci-job-isolation'"
  ok "INPUT sends job bridges through CI-JOBS-IN" bash -c "iptables -S INPUT | grep -q CI-JOBS-IN"
  ok "sshd: password login is off" bash -c "sshd -T | grep -qi '^passwordauthentication no'"
  if [[ "$KIND" == rocky ]]; then
    [[ $(getenforce 2>/dev/null) == Enforcing ]] && pass "SELinux is enforcing" || fail "SELinux is $(getenforce 2>&1)"
  fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q .; then
    pass "registry cache container is running ($(docker ps --format '{{.Names}}' | tr '\n' ' '))"
  else
    warn "registry cache container is not running (the Docker Hub pull may have been rate limited)"
  fi
  # The cloud-init file logs steps that failed to /var/log/ci-bootstrap-failed.log. An optional tool that a mirror lacks is a
  # warning, anything else fails.
  if [[ -s /var/log/ci-bootstrap-failed.log ]]; then
    if grep -qv '^optional-tool-missing-' /var/log/ci-bootstrap-failed.log; then fail "ci-bootstrap-failed.log: $(grep -v '^optional-tool-missing-' /var/log/ci-bootstrap-failed.log | head -5 | tr '\n' ' ')"
    else warn "optional tools missing: $(tr '\n' ' ' < /var/log/ci-bootstrap-failed.log)"; fi
  else
    pass "no /var/log/ci-bootstrap-failed.log entries"
  fi
}

case "$ROLE" in
  server) server_checks ;;
  runner) runner_checks ;;
  *) echo "unknown role $ROLE"; exit 2 ;;
esac
systemctl --failed --no-legend --plain 2>/dev/null | sed 's/^/  note  failed unit: /' | head -10
echo "CHECKS-DONE"
exit $(( fails > 0 ))
