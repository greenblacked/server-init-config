#!/usr/bin/env bash
# Keeps CI jobs away from the cloud metadata service (DOCKER-USER drops 169.254.169.254) and from host services (INPUT from docker0
# and br-* goes through CI-JOBS-IN: replies, ping and the npm cache, docker0 IP port 4873, pass; br-* only from GH_JOB_SUBNET_POOL).
# Run by ci-job-isolation.service at boot and after every Docker start; IPv4 only. Remove: disable the unit, iptables -F CI-JOBS-IN,
# delete the two "ci-job-isolation" rules shown by iptables -S.
set -Eeuo pipefail
META_IP="${META_IP:-169.254.169.254}"
NPM_PORT="${NPM_PORT:-4873}"
TAG=ci-job-isolation
log() { logger -t "$TAG" -- "$*" 2>/dev/null || true; echo "$*"; }
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0   blocks CI jobs from ${META_IP} and from host services (except the npm cache on the docker0 IP, port ${NPM_PORT})"
  exit 0
fi
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }
command -v iptables >/dev/null 2>&1 || { log "iptables not found, nothing applied"; exit 1; }
# Docker creates DOCKER-USER when it starts; wait for it after a boot.
for _ in $(seq 1 30); do
  if iptables -n -L DOCKER-USER >/dev/null 2>&1; then break; fi
  sleep 1
done
iptables -n -L DOCKER-USER >/dev/null 2>&1 || { log "chain DOCKER-USER does not exist (is Docker running?), nothing applied"; exit 1; }
# Insert a rule at the top of a chain unless it is there already.
ensure() {
  local chain="$1"
  shift
  iptables -C "$chain" "$@" 2>/dev/null || iptables -I "$chain" 1 "$@"
}
ensure DOCKER-USER -d "$META_IP" -m comment --comment "$TAG" -j DROP
BRIDGE_IP="${BRIDGE_IP:-}"
if [[ -z "$BRIDGE_IP" ]] && command -v ip >/dev/null 2>&1; then
  BRIDGE_IP=$(ip -4 -o addr show docker0 2>/dev/null | awk '{ print $4 }' | cut -d/ -f1 | head -1 || true)
fi
iptables -N CI-JOBS-IN 2>/dev/null || true
iptables -F CI-JOBS-IN
iptables -A CI-JOBS-IN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A CI-JOBS-IN -p icmp --icmp-type echo-request -j ACCEPT
if [[ -n "$BRIDGE_IP" ]]; then
  iptables -A CI-JOBS-IN -i docker0 -d "$BRIDGE_IP" -p tcp --dport "$NPM_PORT" -j ACCEPT
fi
POOL=$(sed -n 's/^GH_JOB_SUBNET_POOL=//p' "${GHR_CONFIG:-/etc/github-runner/config.env}" 2>/dev/null | tr -d '"' | head -1 || true)
if [[ -n "$POOL" && -n "$BRIDGE_IP" ]]; then
  # only a private /16 to /27 block with zero host bits (as the controller checks it); a failing rule must not skip the DROP
  IFS=. read -r o1 o2 o3 o4 <<<"${POOL%/*}"
  if [[ "$POOL" =~ ^(10(\.[0-9]{1,3}){3}|172\.(1[6-9]|2[0-9]|3[01])(\.[0-9]{1,3}){2}|192\.168(\.[0-9]{1,3}){2})/(1[6-9]|2[0-7])$ ]] \
     && (( ((10#$o1 << 24 | 10#$o2 << 16 | 10#$o3 << 8 | 10#$o4) & ((1 << (32 - ${POOL#*/})) - 1)) == 0 )); then
    iptables -A CI-JOBS-IN -i 'br-+' -s "$POOL" -d "$BRIDGE_IP" -p tcp --dport "$NPM_PORT" -j ACCEPT || { log "WARN: pool rule failed"; POOL=""; }
  else
    log "WARN: GH_JOB_SUBNET_POOL '${POOL}' is not an aligned private /16-/27 block, ignored"; POOL=""
  fi
fi
iptables -A CI-JOBS-IN -j DROP
ensure INPUT -i docker0 -m comment --comment "$TAG" -j CI-JOBS-IN
ensure INPUT -i 'br-+' -m comment --comment "$TAG" -j CI-JOBS-IN
log "applied: ${META_IP} blocked for containers; host services closed to job networks (npm cache: ${BRIDGE_IP:-none}:${NPM_PORT}${POOL:+, also for ${POOL}})"
