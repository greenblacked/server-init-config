#!/usr/bin/env bash
# Keep CI job containers away from the cloud metadata service and from services on the host.
# Run at boot and after every Docker start by ci-job-isolation.service; safe to rerun any time.
#
#   DOCKER-USER   drops traffic to 169.254.169.254 (Hetzner metadata: server data, user-data, tokens).
#   INPUT         traffic from docker0 and the br-* bridges to the host itself goes through the chain CI-JOBS-IN:
#                 only replies, ping and the npm cache (docker0 IP, port 4873) are let in, the rest is dropped.
#
# Not affected: internet access of jobs, the Docker Hub cache (Docker pulls through the mirror on 127.0.0.1:5000,
# jobs do not), traffic between containers of one job, and the host-network stacks (monitoring, logging, caches).
# Only IPv4 is handled. Remove the rules: systemctl disable --now ci-job-isolation; then iptables -F CI-JOBS-IN
# and delete the two "ci-job-isolation" rules shown by iptables -S.
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
iptables -A CI-JOBS-IN -j DROP
ensure INPUT -i docker0 -m comment --comment "$TAG" -j CI-JOBS-IN
ensure INPUT -i 'br-+' -m comment --comment "$TAG" -j CI-JOBS-IN

log "applied: ${META_IP} blocked for containers; host services closed to job networks (npm cache: ${BRIDGE_IP:-none}:${NPM_PORT})"
