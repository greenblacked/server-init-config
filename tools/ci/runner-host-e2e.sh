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
#   4. monitoring stack (runner/install/monitoring.sh, the product's own installer): Grafana healthy, provisioned Prometheus
#      datasource present and healthy, Prometheus ready and scraping node_exporter; Grafana data backed up before a new major,
#      data made by the old version survives the upgrade, and the documented rollback restores it
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
(cd /opt/npm-cache && docker compose config -q && docker compose up -d) 2>&1 | tail -3
for _ in $(seq 1 30); do curl -fsS "http://${GW}:4873/-/ping" >/dev/null 2>&1 && break; sleep 2; done
curl -fsS "http://${GW}:4873/-/ping" >/dev/null && pass "verdaccio answers on the docker0 IP" || { (cd /opt/npm-cache && docker compose logs --tail 30); fail "verdaccio did not start"; }
if ss -ltn | awk '/:4873 /{print $4}' | grep -qv "^${GW}:4873$"; then fail "port 4873 is bound beyond the docker0 IP: $(ss -ltn | awk '/:4873 /{print $4}' | tr '\n' ' ')"; else pass "port 4873 is bound to ${GW} only"; fi
reach "http://${GW}:4873/-/ping" && pass "a job container reaches the cache through the isolation rules" || fail "job container cannot reach the npm cache"
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
[[ -n "$GTAG" ]] || fail "cannot read the Grafana tag from the repo compose file"

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

echo "-- Grafana"
mon_retry 60 grafana_ok && pass "Grafana /api/health reports database ok" || { grafana_logs; fail "Grafana never became healthy"; }
expect_eq "Grafana runs the pinned tag" "$(grafana_version)" "$GTAG"
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
docker run --rm --network none -v monitoring_grafana-data:/v alpine:3.20 chown -R "$(id -u monitoring):$(id -g monitoring)" /v
mcompose up -d grafana >/dev/null 2>&1
mon_retry 60 grafana_ok && pass "control: Grafana ${MON_OLD} starts on a clean volume" || { grafana_logs; fail "Grafana ${MON_OLD} did not start"; }
expect_eq "control: the old version is what runs" "$(grafana_version)" "$MON_OLD"
gapi -X POST -H 'Content-Type: application/json' -d '{"title":"ci-upgrade-marker","uid":"ci-marker"}' "${GURL}/api/folders" >/dev/null 2>&1 \
  && gapi -X POST -H 'Content-Type: application/json' -d '{"dashboard":{"uid":"ci-dash","title":"ci-upgrade-dash","panels":[],"schemaVersion":39},"folderUid":"ci-marker","overwrite":true}' "${GURL}/api/dashboards/db" >/dev/null 2>&1 \
  && pass "control: a folder and a dashboard were created on ${MON_OLD}" || fail "could not create the marker folder and dashboard on ${MON_OLD}"
# same major: no archive
bash runner/install/monitoring-backup.sh --from-tag "$MON_OLD" --to-tag 12.4.13 2>&1 | tail -1
[[ -z "$(ls -A /var/backups/monitoring 2>/dev/null)" ]] && pass "same major: no backup is made" || fail "a backup was made without a major change"
# the installer step update.sh runs: installed compose says the old tag, the repo says the new one
bash runner/install/monitoring-backup.sh 2>&1 | tail -4
mapfile -t ARCH < <(find /var/backups/monitoring -maxdepth 1 -type f -name 'grafana-*.tar.gz')
expect_eq "new major: one archive written" "${#ARCH[@]}" 1
BK="${ARCH[0]:-/nonexistent}"
[[ "$(basename "$BK")" =~ ^grafana-${MON_OLD//./\\.}-[0-9]{8}-[0-9]{6}\.tar\.gz$ ]] && pass "archive is named after the old version and the date" || fail "unexpected archive name: $(basename "$BK")"
expect_eq "archive mode and owner" "$(stat -c '%a %U' "$BK" 2>/dev/null)" "600 root"
expect_eq "backup directory mode" "$(stat -c %a /var/backups/monitoring)" 700
listing=$(tar -tzf "$BK" 2>/dev/null || true)   # a variable, not a pipe: grep -q would SIGPIPE tar under pipefail
grep -Eq '^(\./)?grafana\.db$' <<<"$listing" && pass "archive contains grafana.db" || fail "archive has no grafana.db"
mon_retry 30 grafana_ok && pass "Grafana is running again after the backup" || fail "Grafana was not restarted by the backup step"
# update.sh syncs the compose file next; a rerun then sees the same major and must keep the one archive
install -m 0644 runner/stacks/monitoring/docker-compose.yml "$MD/docker-compose.yml"
bash runner/install/monitoring-backup.sh 2>&1 | tail -1
expect_eq "rerun after the compose update: still one archive" "$(find /var/backups/monitoring -maxdepth 1 -name 'grafana-*.tar.gz' | wc -l)" 1
mcompose up -d grafana 2>&1 | tail -2
mon_retry 90 grafana_ok && pass "Grafana ${GTAG} starts on the ${MON_OLD} data and migrates it" || { grafana_logs; fail "Grafana ${GTAG} did not become healthy on migrated data"; }
expect_eq "now running the new tag" "$(grafana_version)" "$GTAG"
expect_eq "no OOM kill and no restart during the migration" "$(docker inspect -f '{{.State.OOMKilled}} {{.RestartCount}}' monitoring-grafana-1)" "false 0"
expect_eq "folder made on ${MON_OLD} survived" "$(gapi "${GURL}/api/folders/ci-marker" 2>/dev/null | jq -r .title)" ci-upgrade-marker
expect_eq "dashboard made on ${MON_OLD} survived" "$(gapi "${GURL}/api/dashboards/uid/ci-dash" 2>/dev/null | jq -r .dashboard.title)" ci-upgrade-dash
mon_retry 30 ds_healthy && pass "provisioned datasource is healthy after the migration" || fail "datasource is not healthy after the migration"
# the rollback from runner/README.md, word for word apart from the file name
echo "-- rollback with the documented commands"
gapi -X DELETE "${GURL}/api/dashboards/uid/ci-dash" >/dev/null 2>&1 || true
bash -c 'cd /opt/monitoring && docker compose stop grafana && docker run --rm -i --network none -v monitoring_grafana-data:/v alpine:3.20 sh -c "find /v -mindepth 1 -delete && tar -xzf - -C /v" < "$0"' "$BK" >/dev/null 2>&1 \
  && pass "restore command succeeded" || fail "restore command failed"
bash -c 'cd /opt/monitoring && sed -i "s|image: grafana/grafana:.*|image: grafana/grafana:$0|" docker-compose.yml && docker compose up -d grafana' "$MON_OLD" >/dev/null 2>&1
mon_retry 60 grafana_ok && pass "the old image starts on the restored data" || { grafana_logs; fail "old image did not start after the restore"; }
expect_eq "rolled back to the old version" "$(grafana_version)" "$MON_OLD"
expect_eq "dashboard deleted after the upgrade is back (state is the backup's)" "$(gapi "${GURL}/api/dashboards/uid/ci-dash" 2>/dev/null | jq -r .dashboard.title)" ci-upgrade-dash
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
endgroup
finish
