#!/usr/bin/env bash
# The Docker-dependent runner pieces, tested on a real Docker host (the GitHub ubuntu runner), NOT inside a container:
# the DOCKER-USER / INPUT rules live in the netfilter of the machine that runs dockerd, so a container-in-container
# could only test its own namespace, and mounting the host docker.sock into a systemd container would test the host's rules
# from the wrong place. A throwaway CI VM is the honest environment for this.
#   1. registry cache (runner/install/registry-cache.sh): starts, mirror wired into daemon.json, a pull goes through it, rerun is a no-op
#   2. job isolation (runner/scripts/ci-job-isolation.sh): a container cannot reach 169.254.169.254 (a network namespace answers
#      there, forwarded through the host like the real Hetzner address) or the host's services, but can reach the internet side and
#      the npm-cache port; custom bridges too; the systemd unit re-applies the rules after a Docker restart
#   3. npm cache stack (runner/stacks/npm-cache): comes up bound to the docker0 IP only; a job container installs a package through
#      it; the server secret is valid, mode 600 and never logged; simulated 6.x storage is moved aside (not deleted) on the 7.x
#      upgrade and a restart changes nothing
#   4. monitoring stack (runner/install/monitoring.sh, the product's own installer): Grafana healthy, provisioned Prometheus
#      datasource present and healthy, Prometheus ready and scraping node_exporter; a generated Grafana encryption key on a first
#      install only; update.sh's update_monitoring takes the Grafana data backup before it touches anything and stops when the
#      backup cannot run; data made by the old version survives the 12 -> 13 upgrade; update.sh --rollback decides by the Grafana
#      container that ran (13 ran: its compose file stays whole; 12 still runs: the old file and image come back) and the
#      documented archive restore (read from runner/README.md) works and refuses a truncated archive
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
  rm -f "${TRUNC:-}"
  { docker ps -aq --filter label=ci-e2e=1 | xargs -r docker rm -f
    docker network rm ci-e2e-br
    docker compose -f /opt/npm-cache/docker-compose.yml down -v
    docker compose -f /opt/monitoring/docker-compose.yml down -v
    pkill -f "$W/runner-metrics.py"
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
# the helper image that runs as root next to stack volumes: one pin, in common/lib.sh (alpine 3.20 is end of life), by index digest
ALPINE=$(awk -F'"' '/^HELPER_IMAGE=/ { print $2 }' common/lib.sh)
[[ "$ALPINE" == alpine:*@sha256:* ]] || die "no pinned HELPER_IMAGE in common/lib.sh (got '${ALPINE}')"
# can a container fetch URL within 5 s? (alpine's busybox wget)
reach() { dexec "${NET_ARGS[@]}" "$ALPINE" wget -q -T 5 -O /dev/null "$1" >/dev/null 2>&1; }
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
if [[ "$BRGW" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ! [[ "$BRGW" =~ (^|\.)(25[6-9]|2[6-9][0-9]|[3-9][0-9]{2})(\.|$) ]]; then pass "custom bridge gateway is a valid IPv4 (${BRGW})"; else fail "cannot determine the ci-e2e-br gateway (got '${BRGW}'), the custom-bridge host-service checks would prove nothing"; fi

echo "-- before the rules (control: the test setup itself works)"
reach http://169.254.169.254/ && pass "control: container reaches the metadata stand-in" || fail "control failed: metadata stand-in unreachable, the test cannot prove anything"
reach http://10.99.0.2/ && pass "control: container reaches another forwarded address (10.99.0.2)" || fail "control failed: 10.99.0.2 unreachable"
reach "http://${GW}:18080/" && pass "control: container reaches a host service on docker0 (${GW}:18080)" || fail "control failed: host service unreachable from docker0"
NET_ARGS=(--network ci-e2e-br)
reach "http://${BRGW}:18080/" && pass "control: container on ci-e2e-br reaches a host service (${BRGW}:18080) before isolation, same path as the negative below" || fail "control failed: ci-e2e-br container cannot reach ${BRGW}:18080 before isolation, the custom-bridge host-service check proves nothing"
reach http://10.99.0.2/ && pass "control: container on ci-e2e-br reaches the forwarded address (10.99.0.2) before isolation" || fail "control failed: ci-e2e-br container cannot reach 10.99.0.2 before isolation"
NET_ARGS=()

bash runner/scripts/ci-job-isolation.sh 2>&1 | tee "$W/isolation-1.log"
iptables-save | grep -c ci-job-isolation > "$W/rules-1.count" || true
echo "-- after the rules"
reach http://169.254.169.254/ && fail "container STILL reaches 169.254.169.254" || pass "container cannot reach 169.254.169.254 (DOCKER-USER drop)"
reach http://10.99.0.2/ && pass "other forwarded addresses still work (jobs keep internet-side access)" || fail "isolation blocked ordinary forwarded traffic"
reach "http://${GW}:18080/" && fail "container STILL reaches a host service via docker0" || pass "container cannot reach host services via docker0"
reach "http://${GW}:4873/" && pass "container reaches the npm-cache port (${GW}:4873)" || fail "npm-cache port is blocked"
NET_ARGS=(--network ci-e2e-br)
# positive control: the container starts on the custom bridge and has networking, so the negatives below mean "blocked", not "broken"
reach http://10.99.0.2/ && pass "control: container on the custom bridge starts and reaches a forwarded address (10.99.0.2)" || fail "control failed: no container on ci-e2e-br can reach 10.99.0.2, the custom-bridge checks prove nothing"
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
# (the host-service path is blocked by design after the restart, so the positive control here uses the forwarded path)
# positive controls: containers still start and have networking after the restart (default bridge and custom bridge), so the negatives count
reach http://10.99.0.2/ && pass "control: default-bridge container starts and reaches 10.99.0.2 after the Docker restart" || fail "control failed after the Docker restart: default-bridge container cannot reach 10.99.0.2, the checks below prove nothing"
NET_ARGS=(--network ci-e2e-br)
reach http://10.99.0.2/ && pass "control: custom-bridge container starts and reaches 10.99.0.2 after the Docker restart" || fail "control failed after the Docker restart: ci-e2e-br container cannot reach 10.99.0.2, the checks below prove nothing"
reach http://169.254.169.254/ && fail "custom-bridge container reaches metadata after the Docker restart" || pass "custom-bridge container still cannot reach metadata after the Docker restart"
reach "http://${BRGW}:18080/" && fail "custom-bridge container reaches a host service after the Docker restart" || pass "custom-bridge container still isolated from host services after the Docker restart"
NET_ARGS=()
reach http://169.254.169.254/ && fail "metadata reachable after the Docker restart" || pass "metadata still blocked after the Docker restart"
iptables-save > "$W/iptables-isolation.txt"
endgroup

group "3. npm cache stack"
GW=$(ip -4 -o addr show docker0 | awk '{print $4}' | cut -d/ -f1 | head -1)
install -d /opt/npm-cache
sed "s/172\.17\.0\.1:4873/${GW}:4873/" runner/stacks/npm-cache/config.yaml > /opt/npm-cache/config.yaml
sed "s/172\.17\.0\.1:4873/${GW}:4873/" runner/stacks/npm-cache/docker-compose.yml > /opt/npm-cache/docker-compose.yml
pkill -f 'http.server 4873' || true; sleep 1
# Storage left behind by a 6.x Verdaccio: a package, a user file and a 64-character server secret (6.x tolerated it, 7.x refuses to start with it)
npm_c() { (cd /opt/npm-cache && docker compose "$@"); }
npm_x() { npm_c exec -T verdaccio "$@"; }
npm_wait() { for _ in $(seq 1 30); do curl -fsS "http://${GW}:4873/-/ping" >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }
OLD_SECRET=$(printf 'a%.0s' $(seq 1 64))
npm_c config -q && npm_c up --no-start 2>&1 | tail -3
npm_c run --rm --no-deps -T --entrypoint sh verdaccio -c "mkdir -p /verdaccio/storage/data/old-pkg && echo 6x-marker > /verdaccio/storage/data/old-pkg/marker && echo 'old:user' > /verdaccio/storage/htpasswd && printf '{\"list\":[],\"secret\":\"%s\"}' '${OLD_SECRET}' > /verdaccio/storage/data/.verdaccio-db.json"
npm_c up -d 2>&1 | tail -3
npm_wait
curl -fsS "http://${GW}:4873/-/ping" >/dev/null && pass "verdaccio answers on the docker0 IP" || { (cd /opt/npm-cache && docker compose logs --tail 30); fail "verdaccio did not start"; }
if ss -ltn | awk '/:4873 /{print $4}' | grep -qv "^${GW}:4873$"; then fail "port 4873 is bound beyond the docker0 IP: $(ss -ltn | awk '/:4873 /{print $4}' | tr '\n' ' ')"; else pass "port 4873 is bound to ${GW} only"; fi
reach "http://${GW}:4873/-/ping" && pass "a job container reaches the cache through the isolation rules" || fail "job container cannot reach the npm cache"
expect_match "verdaccio version" "$(npm_x verdaccio --version | tail -1)" '^v?7\.'
echo "-- upgrade from 6.x: old storage is moved aside, never deleted"
npm_c logs verdaccio 2>&1 | ci_redact > "$W/npm-cache-1.log" || true
grep -q 'treating it as 6.x' "$W/npm-cache-1.log" && pass "start without a state file and with storage logged that it is treated as 6.x" || fail "no 6.x detection in the log"
expect_eq "backup dirs of the old storage" "$(npm_x sh -c 'ls -d /verdaccio/storage/backup-6.x-* | wc -l')" 1
expect_eq "old package is intact in the backup" "$(npm_x sh -c 'cat /verdaccio/storage/backup-6.x-*/data/old-pkg/marker')" 6x-marker
check "old user file is in the backup" npm_x sh -c 'test -s /verdaccio/storage/backup-6.x-*/htpasswd'
expect_eq "backup dir mode (old credentials inside: only the verdaccio uid reads it)" "$(npm_x sh -c 'stat -c "%a %u" /verdaccio/storage/backup-6.x-*')" "700 10001"
check "old storage is gone from the live path" npm_x sh -c 'test ! -e /verdaccio/storage/data/old-pkg && test ! -e /verdaccio/storage/htpasswd'
expect_eq "deployed major recorded in the state file" "$(npm_x cat /verdaccio/storage/.deployed-major)" 7
echo "-- server secret (values are never printed)"
DB=/verdaccio/storage/data/.verdaccio-db.json
SECRET=$(npm_x sed -n 's/.*"secret":"\([^"]*\)".*/\1/p' "$DB")
ci_mask "$SECRET"
expect_eq "secret file mode and owner (uid)" "$(npm_x stat -c '%a %u' "$DB")" "600 10001"
# 7.x accepts exactly 32 characters; 6.x tolerated other lengths, so the installer makes it exactly 32 (128 random bits)
expect_eq "secret length" "${#SECRET}" 32
[[ "$SECRET" != "$OLD_SECRET" ]] && pass "the old 64-character secret was not reused" || fail "the old secret is still in use"
if npm_c logs verdaccio 2>&1 | grep -qF -- "$SECRET"; then fail "the server secret appears in the container log"; else pass "the server secret is not in the container log"; fi
echo "-- a job container installs a package through the cache"
dexec -e npm_config_registry="http://${GW}:4873/" node:22-alpine sh -c \
  'cd /tmp && npm init -y >/dev/null && npm install --no-audit --no-fund is-number >/dev/null && test -s node_modules/is-number/package.json' \
  && pass "npm install is-number through the cache" || { npm_c logs --tail 30 verdaccio; fail "npm install through the cache failed"; }
check "the tarball is in the cache storage" npm_x sh -c 'ls /verdaccio/storage/data/is-number/*.tgz'
expect_eq "no OOM kill under mem_limit" "$(npm_c ps -q verdaccio | xargs docker inspect -f '{{.State.OOMKilled}}')" false
echo "-- a restart changes nothing"
SNAP=$(npm_x sh -c 'cd /verdaccio/storage && ls -A; ls data/is-number; cat .deployed-major' | tr '\n' ' ')
npm_c up -d --force-recreate 2>&1 | tail -3
npm_wait && pass "verdaccio answers again after the container was recreated" || fail "verdaccio did not come back"
expect_eq "storage listing and state after the restart" "$(npm_x sh -c 'cd /verdaccio/storage && ls -A; ls data/is-number; cat .deployed-major' | tr '\n' ' ')" "$SNAP"
[[ "$(npm_x sed -n 's/.*"secret":"\([^"]*\)".*/\1/p' "$DB")" == "$SECRET" ]] && pass "the secret is unchanged" || fail "the secret changed on restart"
expect_eq "mode after the restart" "$(npm_x stat -c '%a' "$DB")" 600
echo "-- a secret of the wrong length (what 6.x allowed) is replaced, the rest is kept"
npm_x sed -i 's/"secret":"[^"]*"/"secret":"short"/' "$DB"
npm_c up -d --force-recreate 2>&1 | tail -3
npm_wait && pass "verdaccio starts after a bad secret was found" || fail "verdaccio did not start with a bad secret"
SECRET2=$(npm_x sed -n 's/.*"secret":"\([^"]*\)".*/\1/p' "$DB")
ci_mask "$SECRET2"
expect_eq "replaced secret length" "${#SECRET2}" 32
check "cached tarball survived" npm_x sh -c 'ls /verdaccio/storage/data/is-number/*.tgz'
echo "-- crash between the move and the secret: state file present, secret missing -> live 7.x storage is kept, not moved"
npm_x rm "$DB"
npm_c up -d --force-recreate 2>&1 | tail -3
npm_wait && pass "verdaccio starts when only the secret is missing" || fail "verdaccio did not start after the simulated crash"
expect_eq "backup dirs unchanged after the simulated crash" "$(npm_x sh -c 'ls -d /verdaccio/storage/backup-6.x-* | wc -l')" 1
check "live cached tarball was not moved aside" npm_x sh -c 'ls /verdaccio/storage/data/is-number/*.tgz'
SECRET3=$(npm_x sed -n 's/.*"secret":"\([^"]*\)".*/\1/p' "$DB")
ci_mask "$SECRET3"
expect_eq "a new secret was written after the simulated crash (length)" "${#SECRET3}" 32
echo "-- no state file but storage present: treated as 6.x again, moved aside, nothing deleted"
npm_x rm /verdaccio/storage/.deployed-major
npm_c up -d --force-recreate 2>&1 | tail -3
npm_wait && pass "verdaccio starts on the emptied storage" || fail "verdaccio did not start after the second move"
expect_eq "backup dirs" "$(npm_x sh -c 'ls -d /verdaccio/storage/backup-6.x-* | wc -l')" 2
check "first backup still holds the old package" npm_x sh -c 'test -s /verdaccio/storage/backup-6.x-*/data/old-pkg/marker'
check "second backup holds the cached tarball" npm_x sh -c 'ls /verdaccio/storage/backup-6.x-*/data/is-number/*.tgz'
expect_eq "all backup dirs are mode 700" "$(npm_x sh -c 'stat -c %a /verdaccio/storage/backup-6.x-*' | sort -u | tr '\n' ' ')" "700 "
endgroup
group "4. monitoring stack"
MD=/opt/monitoring
MON_OLD=12.0.0   # the Grafana version the repo shipped before the move to the current tag
GTAG=$(awk '/image: grafana\/grafana:/ { sub(/.*grafana\/grafana:/, ""); print $1; exit }' runner/stacks/monitoring/docker-compose.yml)
GURL=http://127.0.0.1:3000
PURL=http://127.0.0.1:9090
mcompose() { (cd "$MD" && docker compose "$@"); }
# mon_retry TRIES cmd...   (2 s apart, quiet)
mon_retry() { local n=$1 i; shift; for ((i = 0; i < n; i++)); do if "$@" >/dev/null 2>&1; then return 0; fi; sleep 2; done; return 1; }
# the admin credentials stay out of argv and out of the log: curl reads them from a config on a pipe
gapi() { curl -fsS --max-time 20 -K <(printf 'user = "%s:%s"\n' "$GF_USER" "$GF_PW") "$@"; }
gcode() { curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$@" || true; }
grafana_ok() { [[ "$(curl -fsS --max-time 5 "${GURL}/api/health" | jq -r .database)" == ok ]]; }
grafana_version() { curl -fsS --max-time 5 "${GURL}/api/health" | jq -r .version; }
prom_up() { curl -fsS --max-time 10 --data-urlencode "query=up{job=\"$1\"}" "${PURL}/api/v1/query" | jq -r '.data.result[0].value[1] // "none"'; }
prom_is() { [[ "$(prom_up "$1")" == "$2" ]]; }
dash_listed() { gapi "${GURL}/api/search?type=dash-db" | jq -e --arg t "$1" 'any(.[]; .title == $t)'; }
up_via_grafana() { [[ "$(gapi --data-urlencode "query=up{job=\"node\"}" -G "${GURL}/api/datasources/proxy/uid/prometheus/api/v1/query" | jq -r '.data.result[0].value[1] // "none"')" == 1 ]]; }
ds_healthy() { [[ "$(gapi "${GURL}/api/datasources/uid/prometheus/health" | jq -r .status)" == OK ]]; }
grafana_logs() { mcompose logs --no-color --tail 40 grafana 2>&1 | ci_redact; }
grafana_mem() { docker inspect -f '{{.HostConfig.Memory}}' monitoring-grafana-1; }
# update.sh functions run in their own bash: a `||`/`if` around a subshell would switch set -e off inside the function.
#   [UPD_BACKUP_DIR=dir] upd FUNCTION [ARGS]   (the real update.sh is sourced, its main is not run)
cat > "$W/upd.sh" <<'UPD'
#!/usr/bin/env bash
set -Eeuo pipefail
src=$1; shift
source "$src"
if [[ -n "${UPD_BACKUP_DIR:-}" ]]; then BACKUP_DIR=$UPD_BACKUP_DIR; fi
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
"$@"
UPD
upd() { bash "$W/upd.sh" "$CI_ROOT/runner/install/update.sh" "$@"; }
# readme_cmd MARKER FILE: the one-line `sudo bash -c '...'` command of runner/README.md that contains MARKER, as the argument of
# bash -c, with FILE as the archive. The test runs what the README says, not a copy of it.
readme_cmd() { grep -F -m1 -- "$1" runner/README.md | sed -e "s/^sudo bash -c '//" -e "s/'\$//" -e "s|/var/backups/monitoring/FILE|$2|g"; }
[[ -n "$GTAG" ]] || fail "cannot read the Grafana tag from the repo compose file"
[[ "$ALPINE" =~ ^alpine:3\.22@sha256:[0-9a-f]{64}$ ]] && pass "helper image (common/lib.sh) is alpine 3.22 pinned by digest" || fail "helper image is not alpine:3.22@sha256:<digest>: '${ALPINE}'"
grep -q '^HELPER_IMAGE=' runner/install/monitoring-backup.sh && fail "monitoring-backup.sh has its own helper image pin, the pin lives in common/lib.sh" || pass "monitoring-backup.sh takes the helper image from common/lib.sh (one pin)"
grep -qF -- "$ALPINE" runner/README.md && pass "the README restore command uses the same pinned image" || fail "runner/README.md does not use ${ALPINE}"

# The installer needs the service user (users.sh also hardens SSH, which a CI VM must not get) and, for the gitlab-runner scrape
# job, something on 127.0.0.1:9252 (a stand-in serving Prometheus text on /metrics).
id monitoring >/dev/null 2>&1 || useradd -r -U -M -d /nonexistent -s /usr/sbin/nologin monitoring
cat > "$W/runner-metrics.py" <<'PY'
import http.server

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"# TYPE ci_e2e_runner gauge\nci_e2e_runner 1\n"
        self.send_response(200 if self.path == "/metrics" else 404)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", 9252), H).serve_forever()
PY
( python3 "$W/runner-metrics.py" >"$W/runner-metrics.log" 2>&1 & )
sleep 1

echo "-- fresh install with the product's installer"
need jq || apt-get install -y -q jq
if ci_run "$W/monitoring-1.log" 12 bash runner/install/monitoring.sh; then pass "runner/install/monitoring.sh exits 0 on a clean host"; else fail "runner/install/monitoring.sh failed (see monitoring-1.log)"; tail -20 "$W/monitoring-1.log"; fi
grep -q 'no Grafana data volume yet' "$W/monitoring-1.log" && pass "clean host: the Grafana backup step had nothing to do" || fail "installer did not report the backup no-op"
[[ -z "$(ls -A /var/backups/monitoring 2>/dev/null)" ]] && pass "clean host: no backup archive was written" || fail "a backup archive exists after a clean install"
[[ "$(stat -c %a "$MD/.env")" == 600 ]] && pass ".env is mode 600" || fail ".env is not mode 600"
GF_USER=$(grep '^GF_SECURITY_ADMIN_USER=' "$MD/.env" | cut -d= -f2-)
GF_PW=$(grep '^GF_SECURITY_ADMIN_PASSWORD=' "$MD/.env" | cut -d= -f2-)
ci_mask "$GF_PW"
[[ -n "$GF_USER" && -n "$GF_PW" && "$GF_PW" != generated-on-install ]] && pass "an admin credential was generated at install time" || fail "no generated admin credential in .env"
# Grafana's own encryption key: generated on a first install only, never printed
SK=$(grep '^GF_SECURITY_SECRET_KEY=' "$MD/.env" | cut -d= -f2-)
ci_mask "$SK"
[[ "$SK" =~ ^[A-Za-z0-9]{32,}$ ]] && pass "a random Grafana encryption key (32+ alphanumerics) was generated on the first install" || fail "no valid generated Grafana encryption key in .env (length ${#SK})"
expect_eq "exactly one encryption key line in .env" "$(grep -c '^GF_SECURITY_SECRET_KEY=' "$MD/.env")" 1
[[ -n "$SK" ]] && ! grep -qF -- "$SK" "$W/monitoring-1.log" && pass "the installer did not print the encryption key" || fail "the encryption key is in the installer output (or missing)"

echo "-- Grafana"
mon_retry 60 grafana_ok && pass "Grafana /api/health reports database ok" || { grafana_logs; fail "Grafana never became healthy"; }
expect_eq "Grafana runs the pinned tag" "$(grafana_version)" "$GTAG"
[[ -n "$SK" && "$(docker exec monitoring-grafana-1 printenv GF_SECURITY_SECRET_KEY)" == "$SK" ]] && pass "the Grafana container got the key from .env" || fail "the Grafana container does not have the generated key"
expect_eq "Grafana container was not OOM-killed under its memory limit" "$(docker inspect -f '{{.State.OOMKilled}} {{.RestartCount}}' monitoring-grafana-1)" "false 0"
gapi "${GURL}/api/datasources/uid/prometheus" > "$W/datasource.json" 2>/dev/null || true
expect_eq "provisioned datasource: type" "$(jq -r .type "$W/datasource.json" 2>/dev/null)" prometheus
expect_eq "provisioned datasource: url" "$(jq -r .url "$W/datasource.json" 2>/dev/null)" "$PURL"
expect_eq "provisioned datasource: default" "$(jq -r .isDefault "$W/datasource.json" 2>/dev/null)" true
mon_retry 30 ds_healthy && pass "the Prometheus datasource health check answers OK" || fail "datasource health is not OK: $(gapi "${GURL}/api/datasources/uid/prometheus/health" 2>&1 | head -c 300)"
dash=$(jq -r .title runner/stacks/monitoring/grafana/dashboards/gitlab-runner.json)
mon_retry 15 dash_listed "$dash" \
  && pass "the provisioned dashboard '${dash}' is listed" || fail "dashboard '${dash}' was not provisioned"
echo "-- controls: the checks above can fail"
expect_eq "no credentials: 401" "$(gcode "${GURL}/api/datasources/uid/prometheus")" 401
expect_eq "wrong credentials: 401" "$(gcode -K <(printf 'user = "%s:%s"\n' "$GF_USER" "not-the-credential") "${GURL}/api/datasources/uid/prometheus")" 401
code=$(gcode -K <(printf 'user = "%s:%s"\n' "$GF_USER" "$GF_PW") "${GURL}/api/datasources/uid/ci-no-such/health")
[[ "$code" =~ ^[45][0-9][0-9]$ ]] && pass "health of an unknown datasource is an error, not OK (${code})" || fail "health of an unknown datasource answered ${code}"
# a datasource whose backend is dead must report an error, otherwise 'health OK' above would prove nothing
gapi -X POST -H 'Content-Type: application/json' -d '{"name":"ci-dead","uid":"ci-dead","type":"prometheus","access":"proxy","url":"http://127.0.0.1:1"}' "${GURL}/api/datasources" >/dev/null 2>&1 || true
dead=$(curl -sS --max-time 30 -K <(printf 'user = "%s:%s"\n' "$GF_USER" "$GF_PW") "${GURL}/api/datasources/uid/ci-dead/health" | jq -r .status)
[[ "$dead" == ERROR ]] && pass "a datasource with a dead backend reports ERROR" || fail "dead datasource reported '${dead}', the health check cannot fail"
gapi -X DELETE "${GURL}/api/datasources/uid/ci-dead" >/dev/null 2>&1 || true

echo "-- Prometheus"
mon_retry 30 curl -fsS --max-time 5 "${PURL}/-/ready" && pass "Prometheus /-/ready answers 200" || fail "Prometheus is not ready"
mon_retry 40 prom_is node 1 \
  && pass "Prometheus scrapes node-exporter (up{job=\"node\"} == 1)" || fail "node-exporter is not scraped: up{job=\"node\"} = $(prom_up node)"
expect_eq "Prometheus scrapes itself" "$(prom_up prometheus)" 1
expect_eq "no node target reports 0" "$(curl -fsS --data-urlencode 'query=up{job="node"} == 0' "${PURL}/api/v1/query" | jq -r '.data.result | length')" 0
expect_eq "a job that does not exist has no series" "$(prom_up ci-no-such-job)" none
mon_retry 20 up_via_grafana \
  && pass "Grafana reads the same series through its Prometheus datasource" || fail "a query through the Grafana datasource did not return up{job=\"node\"} == 1"
# negative control for the up metric itself: stop the runner stand-in and the scrape must go to 0
mon_retry 30 prom_is gitlab-runner 1 \
  && pass "control: the gitlab-runner stand-in is scraped (up == 1)" || fail "control failed: the gitlab-runner stand-in is not scraped"
pkill -f "$W/runner-metrics.py" || true
mon_retry 45 prom_is gitlab-runner 0 \
  && pass "control: with the target stopped, up goes to 0" || fail "up did not drop to 0 after the target stopped"

echo "-- Grafana upgrade: ${MON_OLD} -> ${GTAG}"
rm -rf /var/backups/monitoring
mcompose stop grafana >/dev/null 2>&1
mcompose rm -f grafana >/dev/null 2>&1
docker volume rm monitoring_grafana-data >/dev/null
sed -i "s|image: grafana/grafana:.*|image: grafana/grafana:${MON_OLD}|" "$MD/docker-compose.yml"
mcompose up --no-start grafana >/dev/null 2>&1
docker run --rm --network none -v monitoring_grafana-data:/v "$ALPINE" chown -R "$(id -u monitoring):$(id -g monitoring)" /v
mcompose up -d grafana >/dev/null 2>&1
mon_retry 60 grafana_ok && pass "control: Grafana ${MON_OLD} starts on a clean volume" || { grafana_logs; fail "Grafana ${MON_OLD} did not start"; }
expect_eq "control: the old version is what runs" "$(grafana_version)" "$MON_OLD"
gapi -X POST -H 'Content-Type: application/json' -d '{"title":"ci-upgrade-marker","uid":"ci-marker"}' "${GURL}/api/folders" >/dev/null 2>&1 \
  && gapi -X POST -H 'Content-Type: application/json' -d '{"dashboard":{"uid":"ci-dash","title":"ci-upgrade-dash","panels":[],"schemaVersion":39},"folderUid":"ci-marker","overwrite":true}' "${GURL}/api/dashboards/db" >/dev/null 2>&1 \
  && pass "control: a folder and a dashboard were created on ${MON_OLD}" || fail "could not create the marker folder and dashboard on ${MON_OLD}"
# same major: no archive
bash runner/install/monitoring-backup.sh --from-tag "$MON_OLD" --to-tag 12.4.13 2>&1 | tail -1
[[ -z "$(ls -A /var/backups/monitoring 2>/dev/null)" ]] && pass "same major: no backup is made" || fail "a backup was made without a major change"
# a dry run only reads: a docker shim refuses run/pull/stop (no image pull, no container, no Grafana restart)
mkdir -p "$W/shim"
printf '#!/usr/bin/env bash\ncase "$1" in run|pull|stop|start) echo "docker $1 in a dry run" >&2; exit 99 ;; esac\nexec %s "$@"\n' "$(command -v docker)" > "$W/shim/docker"
chmod +x "$W/shim/docker"
dry=$(PATH="$W/shim:$PATH" bash runner/install/monitoring-backup.sh --dry-run 2>&1) && pass "backup --dry-run runs without docker run, pull or stop" || fail "backup --dry-run called docker run/pull/stop: ${dry}"
grep -q '\[dry-run\] would back up' <<<"$dry" && pass "backup --dry-run reports the archive it would write" || fail "backup --dry-run did not report: ${dry}"
[[ -z "$(ls -A /var/backups/monitoring 2>/dev/null)" ]] && pass "backup --dry-run wrote nothing" || fail "backup --dry-run wrote an archive"
grafana_ok && pass "backup --dry-run left Grafana running" || fail "backup --dry-run stopped Grafana"

echo "-- a helper container that cannot run must stop the upgrade, never skip the backup"
# shim: `docker run` fails like an image pull that hits a rate limit (exit 125) when an argument contains $SHIM_FAIL_ON; all else passes through
mkdir -p "$W/shim-fail"
printf '#!/usr/bin/env bash\n[[ "$1" == run && " $* " == *"$SHIM_FAIL_ON"* ]] && { echo "docker: simulated failure of docker run (exit 125)" >&2; exit 125; }\nexec %s "$@"\n' "$(command -v docker)" > "$W/shim-fail/docker"
chmod +x "$W/shim-fail/docker"
cp "$MD/docker-compose.yml" "$W/compose-before.yml"
cp "$MD/prometheus/prometheus.yml" "$W/prom-before.yml"
rc=0; fb=$(SHIM_FAIL_ON="$ALPINE" PATH="$W/shim-fail:$PATH" bash runner/install/monitoring-backup.sh 2>&1) || rc=$?
printf '%s\n' "$fb" | ci_redact > "$W/backup-fail-1.log"
[[ "$rc" != 0 ]] && pass "helper image cannot run: monitoring-backup.sh exits non-zero (${rc})" || fail "monitoring-backup.sh exited 0 although its helper container cannot run: ${fb}"
grep -q 'not going on without a backup' <<<"$fb" && pass "it says it is not going on without a backup" || fail "no explanation in: ${fb}"
grep -q 'nothing to back up' <<<"$fb" && fail "the failed check was reported as 'nothing to back up'" || pass "the failed check is not reported as 'no database'"
[[ -z "$(ls -A /var/backups/monitoring 2>/dev/null)" ]] && pass "helper image cannot run: no archive" || fail "an archive exists after a failed backup"
grafana_ok && expect_eq "Grafana was not touched by the failed check" "$(grafana_version)" "$MON_OLD" || fail "Grafana is not healthy after the failed check"
# the data is archived, then tar fails: the archive is discarded and the stopped Grafana comes back
rc=0; fb=$(SHIM_FAIL_ON=" tar -C " PATH="$W/shim-fail:$PATH" bash runner/install/monitoring-backup.sh 2>&1) || rc=$?
printf '%s\n' "$fb" | ci_redact > "$W/backup-fail-2.log"
[[ "$rc" != 0 ]] && pass "tar of the volume fails: monitoring-backup.sh exits non-zero (${rc})" || fail "monitoring-backup.sh exited 0 although tar failed"
[[ -z "$(ls -A /var/backups/monitoring 2>/dev/null)" ]] && pass "tar fails: no archive and no temp file left" || fail "left behind: $(ls -A /var/backups/monitoring)"
mon_retry 30 grafana_ok && expect_eq "tar fails: the stopped Grafana is started again" "$(grafana_version)" "$MON_OLD" || fail "Grafana was not started again after a failed backup"
# same major: no container at all, so a missing helper image does not matter
SHIM_FAIL_ON=" run " PATH="$W/shim-fail:$PATH" bash runner/install/monitoring-backup.sh --from-tag "$MON_OLD" --to-tag 12.4.13 >/dev/null 2>&1 \
  && pass "same major: no docker run is needed (every docker run fails here), exit 0" || fail "a same-major backup check ran a container"
# update.sh: the backup is the first change; when it fails, nothing is synced, pulled or restarted
rc=0; SHIM_FAIL_ON="$ALPINE" PATH="$W/shim-fail:$PATH" upd update_monitoring 2>&1 | ci_redact > "$W/update-fail.log" || rc=$?
[[ "$rc" != 0 ]] && pass "update_monitoring stops when the Grafana backup cannot run" || fail "update_monitoring went on without a backup"
grep -q 'Grafana data backup failed, nothing changed' "$W/update-fail.log" && pass "update_monitoring says the backup failed and nothing changed" || fail "update_monitoring did not report the failed backup: $(tail -3 "$W/update-fail.log")"
cmp -s "$MD/docker-compose.yml" "$W/compose-before.yml" && pass "backup failed: the installed compose file is unchanged (still ${MON_OLD})" || fail "the compose file was changed although the backup failed"
cmp -s "$MD/prometheus/prometheus.yml" "$W/prom-before.yml" && pass "backup failed: prometheus.yml is unchanged" || fail "prometheus.yml was synced although the backup failed"
expect_eq "backup failed: the old Grafana still runs" "$(grafana_version)" "$MON_OLD"
[[ -z "$(ls -A /var/backups/monitoring 2>/dev/null)" ]] && pass "backup failed: no archive" || fail "an archive exists after the failed backup"

echo "-- update.sh update_monitoring: ${MON_OLD} -> ${GTAG} (backup first, then sync, then start)"
if upd update_monitoring 2>&1 | ci_redact > "$W/update-1.log"; then pass "update_monitoring exits 0"; else fail "update_monitoring failed (see update-1.log)"; tail -15 "$W/update-1.log"; fi
b=$(grep -n 'grafana backup: wrote' "$W/update-1.log" | head -1 | cut -d: -f1)
c=$(grep -n 'updated /opt/monitoring/docker-compose.yml' "$W/update-1.log" | head -1 | cut -d: -f1)
[[ -n "$b" && -n "$c" ]] && (( b < c )) && pass "the archive is written before the compose file is synced (log lines ${b} < ${c})" || fail "backup/sync order is wrong or missing (backup line '${b}', compose line '${c}')"
mapfile -t ARCH < <(find /var/backups/monitoring -maxdepth 1 -type f -name 'grafana-*.tar.gz')
expect_eq "new major: one archive written" "${#ARCH[@]}" 1
BK="${ARCH[0]:-/nonexistent}"
[[ "$(basename "$BK")" =~ ^grafana-${MON_OLD//./\\.}-[0-9]{8}-[0-9]{6}\.tar\.gz$ ]] && pass "archive is named after the old version and the date" || fail "unexpected archive name: $(basename "$BK")"
expect_eq "archive mode and owner" "$(stat -c '%a %U' "$BK" 2>/dev/null)" "600 root"
expect_eq "backup directory mode" "$(stat -c %a /var/backups/monitoring)" 700
listing=$(tar -tzf "$BK" 2>/dev/null || true)   # a variable, not a pipe: grep -q would SIGPIPE tar under pipefail
grep -Eq '^(\./)?grafana\.db$' <<<"$listing" && pass "archive contains grafana.db" || fail "archive has no grafana.db"
grep -q 'default encryption key' "$W/update-1.log" && fail "update_monitoring warned about the default key although .env has its own" || pass "control: no default-key warning when .env has its own key"
cmp -s runner/stacks/monitoring/docker-compose.yml "$MD/docker-compose.yml" && pass "the repo compose file was synced to ${MD}" || fail "the installed compose file differs from the repo's"
# a rerun sees the same major now and must keep the one archive
bash runner/install/monitoring-backup.sh 2>&1 | tail -1
expect_eq "rerun after the compose update: still one archive" "$(find /var/backups/monitoring -maxdepth 1 -name 'grafana-*.tar.gz' | wc -l)" 1
mon_retry 90 grafana_ok && pass "Grafana ${GTAG} starts on the ${MON_OLD} data and migrates it" || { grafana_logs; fail "Grafana ${GTAG} did not become healthy on migrated data"; }
expect_eq "now running the new tag" "$(grafana_version)" "$GTAG"
expect_eq "no OOM kill and no restart during the migration" "$(docker inspect -f '{{.State.OOMKilled}} {{.RestartCount}}' monitoring-grafana-1)" "false 0"
expect_eq "Grafana runs with the 512m limit of the new compose file" "$(grafana_mem)" 536870912
expect_eq "folder made on ${MON_OLD} survived" "$(gapi "${GURL}/api/folders/ci-marker" 2>/dev/null | jq -r .title)" ci-upgrade-marker
expect_eq "dashboard made on ${MON_OLD} survived" "$(gapi "${GURL}/api/dashboards/uid/ci-dash" 2>/dev/null | jq -r .dashboard.title)" ci-upgrade-dash
mon_retry 30 ds_healthy && pass "provisioned datasource is healthy after the migration" || fail "datasource is not healthy after the migration"

# update.sh --rollback and the failure path restore the old compose file; they decide by the Grafana container that ran
echo "-- file rollback never lowers the Grafana major"
printf '    image: grafana/grafana:%s\n' 12.0.0 > "$W/old-compose.yml"
printf '    image: grafana/grafana:%s\n' 13.3.0 > "$W/new-compose.yml"
gkeep() { (source runner/install/update.sh; keep_grafana_major "$@"); }
expect_eq "newer installed major than the backup: keep it" "$(gkeep "$W/new-compose.yml" "$W/old-compose.yml")" 13.3.0
expect_eq "older installed major than the backup: restore allowed" "$(gkeep "$W/old-compose.yml" "$W/new-compose.yml")" ""
expect_eq "same major: restore allowed" "$(gkeep "$W/new-compose.yml" "$W/new-compose.yml")" ""
expect_eq "no backup of the compose file: nothing to keep" "$(gkeep "$W/new-compose.yml" "$W/none.yml")" ""
expect_eq "new file on disk but the 12 container is what ran: restore allowed" "$(gkeep "$W/new-compose.yml" "$W/old-compose.yml" 12.0.0)" ""
expect_eq "new file on disk and no started container found (unknown): keep the installed major, the safe side" "$(gkeep "$W/new-compose.yml" "$W/old-compose.yml" "")" 13.3.0
expect_eq "the 13 container ran: keep" "$(gkeep "$W/new-compose.yml" "$W/old-compose.yml" 13.3.0)" 13.3.0
expect_eq "grafana_ran_tag reads the container that ran" "$(upd grafana_ran_tag)" "$GTAG"
# grafana_ran_tag with a docker shim: containers that were created but never started give no answer (unknown, not "never ran")
mkdir -p "$W/shim-ran"
cat > "$W/shim-ran/docker" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  ps) printf 'c1\nc2\n' ;;
  inspect) printf '%s\n' "${SHIM_ROWS}" ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$W/shim-ran/docker"
ran_shim() { SHIM_ROWS=$1 PATH="$W/shim-ran:$PATH" upd grafana_ran_tag; }
expect_eq "grafana_ran_tag: created but never started containers: no answer" "$(ran_shim $'0001-01-01T00:00:00Z grafana/grafana:13.3.0\n0001-01-01T00:00:00Z grafana/grafana:13.3.0')" ""
expect_eq "grafana_ran_tag: the 13 container is new and failed, the old started 12 container still exists: 12" "$(ran_shim $'0001-01-01T00:00:00Z grafana/grafana:13.3.0\n2026-01-01T00:00:00Z grafana/grafana:12.0.0')" 12.0.0
expect_eq "grafana_ran_tag: a started 12 and a started 13: the newest tag" "$(ran_shim $'2026-01-01T00:00:00Z grafana/grafana:12.0.0\n2026-02-01T00:00:00Z grafana/grafana:13.3.0')" 13.3.0
# the old compose file as the 12.0.0 era had it: older image, 256m
awk '/^  grafana:/ { g = 1 } g && /mem_limit:/ { sub(/512m/, "256m") } { print }' runner/stacks/monitoring/docker-compose.yml \
  | sed "s|image: grafana/grafana:.*|image: grafana/grafana:${MON_OLD}|" > "$W/compose-old-full.yml"
expect_eq "control: the old compose fixture differs from the new one (image, limit)" "$(diff "$W/compose-old-full.yml" runner/stacks/monitoring/docker-compose.yml | grep -c '^>')" 2
mkdir -p "$W/bk/opt/monitoring"; cp "$W/compose-old-full.yml" "$W/bk/opt/monitoring/docker-compose.yml"
echo marker > "$W/bk/opt/monitoring/ci-restore-marker"
if UPD_BACKUP_DIR="$W/bk" upd restore_files 2>&1 | ci_redact > "$W/restore1.log"; then :; else fail "restore_files failed: $(tail -3 "$W/restore1.log")"; fi
cmp -s runner/stacks/monitoring/docker-compose.yml "$MD/docker-compose.yml" && pass "restore_files after the 13 container ran leaves the installed compose file whole (image and 512m limit)" || fail "restore_files changed the installed compose file: $(grep -E 'image:|mem_limit' "$MD/docker-compose.yml" | tr -s ' ' | tr '\n' ' ')"
grep -q 'WARN: grafana' "$W/restore1.log" && pass "restore_files says why the compose file was kept" || fail "restore_files kept the compose file silently"
[[ "$(cat "$MD/ci-restore-marker" 2>/dev/null)" == marker ]] && pass "the other files of the backup are still restored" || fail "restore_files did not restore the other files"
rm -f "$MD/ci-restore-marker"

echo "-- update.sh --rollback, CLI: the 13 container ran"
# the other stacks are not recreated here (they belong to sections 1 and 3): a docker shim skips `docker compose up` outside /opt/monitoring
mkdir -p "$W/shim-skip"
printf '#!/usr/bin/env bash\nif [[ "$1" == compose && "$2" == up && "$PWD" != /opt/monitoring ]]; then echo "docker compose up skipped in $PWD (CI shim)" >&2; exit 0; fi\nexec %s "$@"\n' "$(command -v docker)" > "$W/shim-skip/docker"
chmod +x "$W/shim-skip/docker"
RB=/var/backups/server-init-config/99991231-235959   # sorts after any real backup directory, so --rollback takes it
mkdir -p "$RB/opt/monitoring"; cp "$W/compose-old-full.yml" "$RB/opt/monitoring/docker-compose.yml"
if PATH="$W/shim-skip:$PATH" bash runner/install/update.sh --rollback 2>&1 | ci_redact > "$W/rollback-13.log"; then pass "update.sh --rollback exits 0"; else fail "update.sh --rollback failed"; tail -8 "$W/rollback-13.log"; fi
cmp -s runner/stacks/monitoring/docker-compose.yml "$MD/docker-compose.yml" && pass "--rollback with the 13 container run: the installed compose file stays whole" || fail "--rollback replaced the installed compose file"
grep -q 'WARN: grafana' "$W/rollback-13.log" && pass "--rollback says the Grafana image stays" || fail "--rollback kept the compose file silently"
mon_retry 90 grafana_ok && expect_eq "Grafana still runs ${GTAG} after the rollback recreate" "$(grafana_version)" "$GTAG" || { grafana_logs; fail "Grafana is not healthy after --rollback"; }
expect_eq "and still has its 512m limit" "$(grafana_mem)" 536870912
expect_eq "its migrated data is intact (folder)" "$(gapi "${GURL}/api/folders/ci-marker" 2>/dev/null | jq -r .title)" ci-upgrade-marker
install -m 0644 runner/stacks/monitoring/docker-compose.yml "$MD/docker-compose.yml"

# the rollback from runner/README.md, as written there
echo "-- rollback with the documented commands"
gapi -X DELETE "${GURL}/api/dashboards/uid/ci-dash" >/dev/null 2>&1 || true
# a truncated archive is refused before anything is stopped or deleted
# (a half Grafana database: kept outside $W, which is uploaded as the public failure artifact, and removed right after use)
TRUNC=$(umask 077; mktemp /tmp/ci-truncated.XXXXXX.tar.gz)
head -c "$(( $(stat -c %s "$BK") / 2 ))" "$BK" > "$TRUNC"
RESTORE_CMD=$(readme_cmd 'docker run --rm -i --network none -v monitoring_grafana-data' "$TRUNC")
[[ "$RESTORE_CMD" == *'tar -tzf'* ]] && pass "the README restore command checks the archive first (found in the README)" || fail "could not read the restore command from runner/README.md: '${RESTORE_CMD}'"
if bash -c "$RESTORE_CMD" >/dev/null 2>&1; then fail "the restore command accepted a truncated archive"; else pass "restore of a truncated archive fails"; fi
rm -f "$TRUNC"
grafana_ok && expect_eq "truncated archive: Grafana was not stopped and its volume not wiped (folder still there)" "$(gapi "${GURL}/api/folders/ci-marker" 2>/dev/null | jq -r .title)" ci-upgrade-marker || fail "the truncated archive stopped Grafana or wiped the volume"
RESTORE_CMD=$(readme_cmd 'docker run --rm -i --network none -v monitoring_grafana-data' "$BK")
bash -c "$RESTORE_CMD" >/dev/null 2>&1 && pass "restore command succeeded" || fail "restore command failed"
TAG_CMD=$(readme_cmd 'image: grafana/grafana:12.0.0|' x)
[[ "$TAG_CMD" == *"grafana:${MON_OLD}|"* ]] || fail "the README start command does not name ${MON_OLD}"
bash -c "$TAG_CMD" >/dev/null 2>&1 || true   # its closing curl may come before Grafana listens
mon_retry 60 grafana_ok && pass "the old image starts on the restored data" || { grafana_logs; fail "old image did not start after the restore"; }
expect_eq "rolled back to the old version" "$(grafana_version)" "$MON_OLD"
expect_eq "dashboard deleted after the upgrade is back (state is the backup's)" "$(gapi "${GURL}/api/dashboards/uid/ci-dash" 2>/dev/null | jq -r .dashboard.title)" ci-upgrade-dash

# An update synced the new compose file and aborted before `docker compose up` (pull failed): the old Grafana still runs on
# unmigrated data. --rollback must put the old file back instead of keeping the new tag (that would migrate on the recreate).
echo "-- update.sh --rollback, CLI: the new compose file is on disk but the ${MON_OLD} container is what ran"
install -m 0644 runner/stacks/monitoring/docker-compose.yml "$MD/docker-compose.yml"
expect_eq "control: the installed file says ${GTAG}, the container is ${MON_OLD}" "$(grafana_version) $(awk '/image: grafana\/grafana:/ { sub(/.*grafana\/grafana:/, ""); print $1 }' "$MD/docker-compose.yml")" "${MON_OLD} ${GTAG}"
expect_eq "grafana_ran_tag reads the old container" "$(upd grafana_ran_tag)" "$MON_OLD"
if PATH="$W/shim-skip:$PATH" bash runner/install/update.sh --rollback 2>&1 | ci_redact > "$W/rollback-12.log"; then pass "update.sh --rollback exits 0"; else fail "update.sh --rollback failed"; tail -8 "$W/rollback-12.log"; fi
cmp -s "$W/compose-old-full.yml" "$MD/docker-compose.yml" && pass "--rollback restored the old compose file (image ${MON_OLD}, 256m)" || fail "--rollback kept the new compose file although Grafana ${MON_OLD} never ran it: $(grep -E 'image: grafana|mem_limit' "$MD/docker-compose.yml" | tr -s ' ' | tr '\n' ' ')"
grep -q 'WARN: grafana' "$W/rollback-12.log" && fail "--rollback warned that a migrated Grafana stays, but nothing was migrated" || pass "no 'already migrated' warning: nothing was migrated"
mon_retry 60 grafana_ok && expect_eq "Grafana ${MON_OLD} runs again after the recreate, data unmigrated" "$(grafana_version)" "$MON_OLD" || { grafana_logs; fail "Grafana is not healthy after --rollback"; }
expect_eq "its limit is the old file's" "$(grafana_mem)" 268435456
rm -rf "$RB"

# no compose file (reinstall over a leftover volume): the version comes from the container that used the volume
unk=$(MON_DIR=/nonexistent bash runner/install/monitoring-backup.sh --to-tag 12.4.13 2>&1 | tail -1)
grep -q "stays on major 12" <<<"$unk" && pass "without a compose file the old version is read from the container: same major, no archive" || fail "leftover volume, same major, was not recognized: ${unk}"
unk=$(MON_DIR=/nonexistent bash runner/install/monitoring-backup.sh --dry-run --to-tag "$GTAG" 2>&1 | tail -1)
grep -q "(${MON_OLD} -> ${GTAG})" <<<"$unk" && pass "leftover volume, new major: archive named after ${MON_OLD}" || fail "leftover volume, new major, was not recognized: ${unk}"
# retention: 3 newest archives are kept
for i in 1 2 3; do
  f="/var/backups/monitoring/grafana-0.0.${i}-2020010${i}-000000.tar.gz"; : > "$f"; touch -d "2020-01-0${i}" "$f"
done
bash runner/install/monitoring-backup.sh --force 2>&1 | tail -1
expect_eq "retention: 3 archives kept" "$(find /var/backups/monitoring -maxdepth 1 -name 'grafana-*.tar.gz' | wc -l)" 3
[[ ! -e /var/backups/monitoring/grafana-0.0.1-20200101-000000.tar.gz && ! -e /var/backups/monitoring/grafana-0.0.2-20200102-000000.tar.gz && -e "$BK" ]] \
  && pass "retention removed the two oldest archives and kept the real one" || fail "retention kept an archive it should have removed (or removed a recent one)"
echo "-- teardown"
mcompose down -v >/dev/null 2>&1 && pass "monitoring stack removed" || fail "docker compose down failed"
rm -rf /var/backups/monitoring

# runner/COMMANDS.md (copy-paste install) writes monitoring.sh without monitoring-backup.sh: the installer must still work.
echo "-- install from the copy-paste file set (no monitoring-backup.sh)"
PT="$W/paste-tree"
mkdir -p "$PT/common" "$PT/runner/install" "$PT/runner/stacks"
cp common/lib.sh "$PT/common/"
cp runner/install/monitoring.sh "$PT/runner/install/"
cp -r runner/stacks/monitoring "$PT/runner/stacks/"
rm -rf "$MD"
if ci_run "$W/monitoring-2.log" 6 bash "$PT/runner/install/monitoring.sh"; then pass "monitoring.sh installs when monitoring-backup.sh is not there"; else fail "monitoring.sh failed without monitoring-backup.sh (see monitoring-2.log)"; fi
grep -q 'monitoring-backup.sh not found' "$W/monitoring-2.log" && pass "it says the backup step was skipped" || fail "no note about the skipped backup step"
mon_retry 60 grafana_ok && pass "Grafana is healthy after the copy-paste style install" || fail "Grafana is not healthy after the copy-paste style install"
SK2=$(grep '^GF_SECURITY_SECRET_KEY=' "$MD/.env" | cut -d= -f2-)
ci_mask "$SK2"
[[ "$SK2" =~ ^[A-Za-z0-9]{32,}$ && "$SK2" != "$SK" ]] && pass "a fresh install gets its own new encryption key" || fail "no new valid encryption key after the second fresh install"

# A volume that is left over from an earlier install may hold values encrypted with Grafana's default key: a new key would make them
# unreadable, so the installer must not introduce one there (and must say so).
echo "-- install over a leftover Grafana volume keeps the default encryption key"
mcompose down >/dev/null 2>&1 || fail "docker compose down failed"
rm -rf "$MD"
if ci_run "$W/monitoring-3.log" 0 bash runner/install/monitoring.sh; then pass "monitoring.sh installs over a leftover Grafana volume"; else fail "monitoring.sh failed over a leftover volume (see monitoring-3.log)"; tail -15 "$W/monitoring-3.log"; fi
grep -q '^GF_SECURITY_SECRET_KEY=' "$MD/.env" && fail "a new encryption key was generated for an existing volume" || pass "existing volume: no encryption key was added to .env"
grep -q 'built-in default key' "$W/monitoring-3.log" && pass "the installer says the default key stays" || fail "no note about the default encryption key"
grep -q "GF_SECURITY_SECRET_KEY line, put that same line back" "$W/monitoring-3.log" && pass "the installer says how to bring the earlier install's key back" || fail "no note about restoring the earlier GF_SECURITY_SECRET_KEY"
[[ -n "$(find /var/backups/monitoring -maxdepth 1 -name 'grafana-*.tar.gz' 2>/dev/null)" ]] && pass "the leftover volume was archived before the start" || fail "the leftover volume was not archived"
mon_retry 60 grafana_ok && pass "Grafana is healthy on the leftover volume" || fail "Grafana is not healthy on the leftover volume"
# an archive of data under the default key says so (the .env of this install has no key line)
out=$(bash runner/install/monitoring-backup.sh --force 2>&1 | ci_redact)
grep -q 'default encryption key, so whoever gets the archive' <<<"$out" && pass "the backup step warns that the archive is protected by the default key only" || fail "no warning about the default key in the backup step: ${out}"
mcompose down -v >/dev/null 2>&1 || fail "docker compose down failed"
rm -rf /var/backups/monitoring
endgroup
finish
