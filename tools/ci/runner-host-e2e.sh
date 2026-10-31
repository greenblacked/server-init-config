#!/usr/bin/env bash
# The Docker-dependent runner pieces, tested on a real Docker host (the GitHub ubuntu runner), NOT inside a container:
# the DOCKER-USER / INPUT rules live in the netfilter of the machine that runs dockerd, so a container-in-container
# could only test its own namespace, and mounting the host docker.sock into a systemd container would test the host's rules
# from the wrong place. A throwaway CI VM is the honest environment for this.
#   1. registry cache (runner/install/registry-cache.sh): starts, mirror wired into daemon.json, a pull goes through it, rerun is a no-op
#   2. job isolation (runner/scripts/ci-job-isolation.sh): a container cannot reach 169.254.169.254 (a network namespace answers
#      there, forwarded through the host like the real Hetzner address) or the host's services, but can reach the internet side and
#      the npm-cache port; custom bridges too; the systemd unit re-applies the rules after a Docker restart
#   3. npm cache stack (runner/stacks/npm-cache): comes up bound to the docker0 IP only
# It changes /etc/docker/daemon.json, restarts Docker and adds iptables rules: CI only (or ALLOW_LOCAL=1 in a VM).
#   Usage: sudo tools/ci/runner-host-e2e.sh
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$CI_ROOT"
[[ $EUID -eq 0 ]] || die "run as root (sudo)"
in_ci || [[ "${ALLOW_LOCAL:-0}" == 1 ]] || die "this changes the Docker daemon config and firewall of the machine: set ALLOW_LOCAL=1 to run it on a disposable VM"
W="$CI_OUT/runner-host"; mkdir -p "$W"

NS=ci-meta
cleanup() {
  local rc=$?
  set +e
  { docker ps -aq --filter label=ci-e2e=1 | xargs -r docker rm -f
    docker network rm ci-e2e-br
    docker compose -f /opt/npm-cache/docker-compose.yml down -v
    (cd /opt/registry-cache 2>/dev/null && docker compose down -v)
    systemctl disable --now ci-job-isolation.service
    pkill -f 'http.server 18080'
    ip netns pids "$NS" | xargs -r kill
    ip netns del "$NS"
    ip link del vmeta0
  } >/dev/null 2>&1 || true
  iptables-save > "$W/iptables-final.txt" 2>/dev/null || true
  exit "$rc"
}
trap cleanup EXIT

dexec() { docker run --rm --label ci-e2e=1 "$@"; }
# can a container fetch URL within 5 s? (alpine's busybox wget)
reach() { dexec "${NET_ARGS[@]}" alpine:3.20 wget -q -T 5 -O /dev/null "$1" >/dev/null 2>&1; }
NET_ARGS=()

group "1. registry cache"
install -d /etc/docker
[[ -s /etc/docker/daemon.json ]] || echo '{}' > /etc/docker/daemon.json
need jq || apt-get install -y -q jq
bash runner/install/registry-cache.sh 2>&1 | tee "$W/registry-cache-1.log" | tail -8
curl -fsS http://127.0.0.1:5000/v2/ >/dev/null && pass "registry cache answers on 127.0.0.1:5000" || fail "registry cache does not answer"
docker info 2>/dev/null | grep -A1 'Registry Mirrors' | grep -q '127.0.0.1:5000' && pass "Docker lists the mirror" || fail "Docker does not list the mirror"
docker rmi -f alpine:3.19 >/dev/null 2>&1 || true
docker pull -q alpine:3.19 >/dev/null && pass "a Docker Hub pull works through the mirror" || fail "pull failed"
if curl -fsS http://127.0.0.1:5000/v2/_catalog | tee "$W/catalog.json" | grep -q 'library/alpine'; then pass "the pull was served through (and stored by) the cache: $(cat "$W/catalog.json")"; else fail "alpine is not in the cache catalog: $(cat "$W/catalog.json")"; fi
curl -fsS http://127.0.0.1:5001/metrics 2>/dev/null | grep -q registry_ && pass "cache metrics on 127.0.0.1:5001" || warn "no registry metrics on 5001"
ss -ltn | awk '$4 ~ /:5000$/ {print $4}' | grep -qv '^127.0.0.1:' && fail "cache listens beyond loopback" || pass "cache listens on loopback only"
cp /etc/docker/daemon.json "$W/daemon-1.json"
bash runner/install/registry-cache.sh > "$W/registry-cache-2.log" 2>&1 && pass "registry-cache rerun exits 0" || fail "registry-cache rerun failed"
cmp -s /etc/docker/daemon.json "$W/daemon-1.json" && pass "rerun left daemon.json unchanged" || fail "rerun changed daemon.json"
grep -q 'restarting docker' "$W/registry-cache-2.log" && fail "rerun restarted Docker" || pass "rerun did not restart Docker"
jq -e '(.["registry-mirrors"] | length) == 1' /etc/docker/daemon.json >/dev/null && pass "exactly one mirror entry" || fail "mirror entry duplicated"
endgroup

group "2. job isolation"
# A network namespace plays the Hetzner metadata service: it owns 169.254.169.254 and is reached THROUGH the host (forwarded),
# like the real address. (A local address would go through INPUT, never touching DOCKER-USER.)
ip netns add "$NS"
ip link add vmeta0 type veth peer name vmeta1 netns "$NS"
ip addr add 10.99.0.1/30 dev vmeta0; ip link set vmeta0 up
ip -n "$NS" addr add 10.99.0.2/30 dev vmeta1; ip -n "$NS" link set vmeta1 up; ip -n "$NS" link set lo up
ip -n "$NS" addr add 169.254.169.254/32 dev lo
ip -n "$NS" route add default via 10.99.0.1
ip route add 169.254.169.254/32 via 10.99.0.2
sysctl -qw net.ipv4.ip_forward=1
mkdir -p "$W/www"; echo meta > "$W/www/index.html"
( cd "$W/www" && ip netns exec "$NS" python3 -m http.server 80 --bind 0.0.0.0 >"$W/meta-server.log" 2>&1 & )
# a service on the host itself (all interfaces) and one on the npm-cache port
( cd "$W/www" && python3 -m http.server 18080 --bind 0.0.0.0 >"$W/host-18080.log" 2>&1 & )
( cd "$W/www" && python3 -m http.server 4873 --bind 0.0.0.0 >"$W/host-4873.log" 2>&1 & )
sleep 2
GW=$(ip -4 -o addr show docker0 | awk '{print $4}' | cut -d/ -f1 | head -1)
log "docker0 gateway ${GW}"
docker network create ci-e2e-br >/dev/null
BRGW=$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' ci-e2e-br)

echo "-- before the rules (control: the test setup itself works)"
reach http://169.254.169.254/ && pass "control: container reaches the metadata stand-in" || fail "control failed: metadata stand-in unreachable, the test cannot prove anything"
reach http://10.99.0.2/ && pass "control: container reaches another forwarded address (10.99.0.2)" || fail "control failed: 10.99.0.2 unreachable"
reach "http://${GW}:18080/" && pass "control: container reaches a host service on docker0 (${GW}:18080)" || fail "control failed: host service unreachable from docker0"

bash runner/scripts/ci-job-isolation.sh 2>&1 | tee "$W/isolation-1.log"
iptables-save | grep -c ci-job-isolation > "$W/rules-1.count" || true
echo "-- after the rules"
reach http://169.254.169.254/ && fail "container STILL reaches 169.254.169.254" || pass "container cannot reach 169.254.169.254 (DOCKER-USER drop)"
reach http://10.99.0.2/ && pass "other forwarded addresses still work (jobs keep internet-side access)" || fail "isolation blocked ordinary forwarded traffic"
reach "http://${GW}:18080/" && fail "container STILL reaches a host service via docker0" || pass "container cannot reach host services via docker0"
reach "http://${GW}:4873/" && pass "container reaches the npm-cache port (${GW}:4873)" || fail "npm-cache port is blocked"
NET_ARGS=(--network ci-e2e-br)
reach "http://${BRGW}:18080/" && fail "container on a custom bridge STILL reaches a host service" || pass "custom bridge (br-*) is isolated from host services too"
reach http://169.254.169.254/ && fail "custom-bridge container reaches 169.254.169.254" || pass "custom-bridge container cannot reach 169.254.169.254"
NET_ARGS=()
curl -fsS http://127.0.0.1:18080/ >/dev/null && pass "the host itself still reaches its services" || fail "host lost access to its own service"
echo "-- rerun is idempotent"
bash runner/scripts/ci-job-isolation.sh >/dev/null 2>&1
iptables-save | grep -c ci-job-isolation > "$W/rules-2.count" || true
expect_eq "rule count after a second run" "$(cat "$W/rules-2.count")" "$(cat "$W/rules-1.count")"
echo "-- survives a Docker restart through the systemd unit"
install -m 0755 runner/scripts/ci-job-isolation.sh /usr/local/bin/ci-job-isolation.sh
install -m 0644 runner/systemd/ci-job-isolation.service /etc/systemd/system/ci-job-isolation.service
systemctl daemon-reload
systemctl enable --now ci-job-isolation.service && pass "ci-job-isolation.service starts" || fail "ci-job-isolation.service failed: $(systemctl status ci-job-isolation --no-pager 2>&1 | tail -5)"
iptables -S DOCKER-USER | grep -q ci-job-isolation && pass "rule present before the restart" || fail "rule missing before the restart"
iptables -F DOCKER-USER || true   # what a fresh Docker start would look like
systemctl restart docker
for _ in $(seq 1 30); do iptables -S DOCKER-USER 2>/dev/null | grep -q ci-job-isolation && break; sleep 1; done
iptables -S DOCKER-USER | grep -q ci-job-isolation && pass "the unit re-applied the DOCKER-USER rule after systemctl restart docker" || fail "rule not re-applied after a Docker restart"
reach http://169.254.169.254/ && fail "metadata reachable after the Docker restart" || pass "metadata still blocked after the Docker restart"
iptables-save > "$W/iptables-isolation.txt"
endgroup

group "3. npm cache stack"
GW=$(ip -4 -o addr show docker0 | awk '{print $4}' | cut -d/ -f1 | head -1)
install -d /opt/npm-cache
sed "s/172\.17\.0\.1:4873/${GW}:4873/" runner/stacks/npm-cache/config.yaml > /opt/npm-cache/config.yaml
sed "s/172\.17\.0\.1:4873/${GW}:4873/" runner/stacks/npm-cache/docker-compose.yml > /opt/npm-cache/docker-compose.yml
pkill -f 'http.server 4873' || true; sleep 1
(cd /opt/npm-cache && docker compose config -q && docker compose up -d) 2>&1 | tail -3
for _ in $(seq 1 30); do curl -fsS "http://${GW}:4873/-/ping" >/dev/null 2>&1 && break; sleep 2; done
curl -fsS "http://${GW}:4873/-/ping" >/dev/null && pass "verdaccio answers on the docker0 IP" || { (cd /opt/npm-cache && docker compose logs --tail 30); fail "verdaccio did not start"; }
if ss -ltn | awk '/:4873 /{print $4}' | grep -qv "^${GW}:4873$"; then fail "port 4873 is bound beyond the docker0 IP: $(ss -ltn | awk '/:4873 /{print $4}' | tr '\n' ' ')"; else pass "port 4873 is bound to ${GW} only"; fi
reach "http://${GW}:4873/-/ping" && pass "a job container reaches the cache through the isolation rules" || fail "job container cannot reach the npm cache"
endgroup
finish
