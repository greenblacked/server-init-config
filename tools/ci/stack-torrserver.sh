#!/usr/bin/env bash
# other/torrserver end to end on a real Docker host with internet (the GitHub ubuntu runner): the real pinned ghcr.io image.
#   local mode -> public mode -> back to local (mode switch) -> uninstall --purge (nothing left) -> public mode again with the
#   public IP found by the installer itself (real api.ipify.org; the Hetzner metadata address does not exist on a CI VM).
# Public mode runs with TS_TLS=internal (Caddy's own CA): Let's Encrypt cannot validate a name for a CI VM that has no
# inbound port 80 from the internet, and the sslip.io name would point at the pinned test IP, not at the VM. Everything else
# (Caddy, login, headers, redirect, fail2ban jail, firewall bookkeeping) is the real code path; the certificate issuance is
# the one thing this cannot test. Clients reach the stack with curl --resolve <name>:<port>:127.0.0.1 and -k.
# Installs fail2ban and changes iptables: CI only (or ALLOW_LOCAL=1 on a disposable VM).   Usage: sudo tools/ci/stack-torrserver.sh
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$CI_ROOT/other/torrserver"
[[ $EUID -eq 0 ]] || die "run as root (sudo)"
in_ci || [[ "${ALLOW_LOCAL:-0}" == 1 ]] || die "this installs packages and changes the firewall: set ALLOW_LOCAL=1 on a disposable VM"
W="$CI_OUT/torrserver"; mkdir -p "$W"
TS=/opt/torrserver
INSTALL=(./install.sh)

collect() { docker ps -a > "$W/docker-ps.txt" 2>&1; docker logs torrserver > "$W/torrserver.log" 2>&1; docker logs torrserver-caddy > "$W/caddy.log" 2>&1; iptables-save > "$W/iptables.txt" 2>&1; cp "$TS/.env" "$W/env.txt" 2>/dev/null; true; }
on_exit() { local rc=$?; collect; exit "$rc"; }
trap on_exit EXIT

env_get() { grep -m1 "^$1=" "$TS/.env" | cut -d= -f2-; }
creds() { TS_USER=$(grep -E '^TS_USER=' "$TS/credentials" | cut -d= -f2-); TS_PASS=$(grep -E '^TS_PASS=' "$TS/credentials" | cut -d= -f2-); }
code() { curl -ksS -m 10 -o /dev/null -w '%{http_code}' "$@" || true; }
settings_json() { # base-url [curl args]
  local url="$1"; shift
  curl -ksS -m 10 -X POST -d '{"action":"get"}' -H 'Content-Type: application/json' "$@" "$url/settings"
}
streaming_only() { # json
  jq -e '.UseDisk == false and .DisableUpload == true and .RemoveCacheOnDrop == true and .TorrentsSavePath == "" and .EnableDLNA == false and .EnableUPNP != true and .DisableUPNP == true and .EnableLPD == false and .EnableDebug == false and .CacheSize > 0' >/dev/null <<<"$1"
}

group "1. --local (fresh install)"
"${INSTALL[@]}" --local 2>&1 | tee "$W/install-local.log" | tail -12
creds
expect_eq ".env records the mode" "$(env_get TS_MODE)" local
expect_eq "local: 401 without credentials" "$(code http://127.0.0.1:8090/settings -X POST -d '{"action":"get"}')" 401
expect_eq "local: 200 with credentials" "$(code -u "$TS_USER:$TS_PASS" http://127.0.0.1:8090/settings -X POST -d '{"action":"get"}')" 200
expect_eq "local: /echo answers (healthcheck path)" "$(code http://127.0.0.1:8090/echo)" 200
j=$(settings_json http://127.0.0.1:8090 -u "$TS_USER:$TS_PASS")
if streaming_only "$j"; then pass "settings read back: streaming only (UseDisk=false, DisableUpload, RemoveCacheOnDrop, no save path, DLNA/UPnP/LPD off)"; else echo "$j" | head -c 800; fail "settings are not streaming-only"; fi
ss -ltn | awk '$4 ~ /:8090$/ {print $4}' | grep -qv '^127.0.0.1:' && fail "8090 is bound beyond loopback" || pass "8090 is bound to 127.0.0.1 only"
docker ps --format '{{.Names}}' | grep -qx torrserver-caddy && fail "local mode runs Caddy" || pass "local mode: no Caddy"
echo "-- container hardening"
expect_eq "container user is non-root" "$(docker inspect -f '{{.Config.User}}' torrserver)" "10001:10001"
expect_eq "read-only root filesystem" "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' torrserver)" true
expect_eq "no-new-privileges" "$(docker inspect -f '{{.HostConfig.SecurityOpt}}' torrserver)" "[no-new-privileges:true]"
expect_eq "healthcheck healthy" "$(for _ in $(seq 1 30); do s=$(docker inspect -f '{{.State.Health.Status}}' torrserver); [[ $s == healthy ]] && break; sleep 3; done; echo "$s")" healthy
echo "-- cleanup safety net, dry run"
"$TS/cleanup.sh" --dry-run > "$W/cleanup-dry-run.log" 2>&1 && pass "cleanup.sh --dry-run exits 0" || { tail "$W/cleanup-dry-run.log"; fail "cleanup.sh --dry-run"; }
systemctl is-active --quiet torrserver-cleanup.timer && pass "torrserver-cleanup.timer active" || fail "cleanup timer not active"
echo "-- rerun changes nothing"
"${INSTALL[@]}" --local > "$W/install-local-2.log" 2>&1 && pass "rerun exits 0" || fail "rerun failed"
grep -q 'settings already as wanted' "$W/install-local-2.log" && pass "rerun: settings already as wanted" || warn "rerun did not report 'settings already as wanted'"
[[ "$(grep -E '^TS_PASS=' "$TS/credentials" | cut -d= -f2-)" == "$TS_PASS" ]] && pass "credentials kept on rerun" || fail "rerun replaced the password"
endgroup

group "2. switch to public mode (TS_TLS=internal, PUBLIC_IP override: no metadata service involved)"
PUBLIC_IP=8.8.4.4 TS_TLS=internal "${INSTALL[@]}" --public 2>&1 | tee "$W/install-public.log" | tail -14
HOST=$(env_get TS_HOSTNAME); PORT=$(env_get TS_PUBLIC_PORT)
expect_eq "host name from the override IP" "$HOST" "8-8-4-4.sslip.io"
expect_match "random port in 20000-60000" "$PORT" '^(2[0-9]{4}|[3-5][0-9]{4}|60000)$'
BASE="https://${HOST}:${PORT}"; R=(--resolve "${HOST}:${PORT}:127.0.0.1")
for _ in $(seq 1 30); do [[ "$(code "${R[@]}" "$BASE/echo")" == 200 ]] && break; sleep 2; done
expect_eq "public: /echo answers without login" "$(code "${R[@]}" "$BASE/echo")" 200
expect_eq "public: / without credentials is 401" "$(code "${R[@]}" "$BASE/")" 401
expect_eq "public: POST /settings without credentials is 401" "$(code "${R[@]}" "$BASE/settings" -X POST -d '{"action":"get"}')" 401
expect_eq "public: wrong password is 401" "$(code "${R[@]}" -u "$TS_USER:wrong" "$BASE/settings" -X POST -d '{"action":"get"}')" 401
for p in "/play/0000000000000000000000000000000000000000/1" "/playlist?hash=0000000000000000000000000000000000000000" "/swagger/index.html" "/stream?link=x&play" "/subs/x/1"; do
  expect_eq "public: ${p%%\?*} without credentials is 401 (TorrServer itself leaves it open)" "$(code "${R[@]}" "$BASE$p")" 401
done
expect_eq "public: 200 with credentials" "$(code "${R[@]}" -u "$TS_USER:$TS_PASS" "$BASE/settings" -X POST -d '{"action":"get"}')" 200
j=$(settings_json "$BASE" "${R[@]}" -u "$TS_USER:$TS_PASS")
if streaming_only "$j"; then pass "public: settings still streaming-only"; else fail "public: settings not streaming-only"; fi
hdr=$(curl -ksSI -m 10 "${R[@]}" "$BASE/echo" | tr -d '\r')
grep -qi '^strict-transport-security:' <<<"$hdr" && pass "HSTS header" || fail "no HSTS header"
grep -qi '^x-content-type-options: nosniff' <<<"$hdr" && pass "nosniff header" || fail "no nosniff header"
grep -qi '^server:' <<<"$hdr" && fail "Server header present" || pass "Server header removed"
echo "-- port 80: redirect only, never the login"
c80=$(curl -sS -m 10 -o /dev/null -w '%{http_code} %{redirect_url}' -u "$TS_USER:$TS_PASS" -H "Host: ${HOST}" http://127.0.0.1:80/settings || true)
expect_match "port 80 redirects to https" "$c80" "^30[1-8] https://${HOST//./\\.}:${PORT}/"
echo "-- exposure"
ss -ltn | awk '$4 ~ /:8090$/ {print $4}' | grep -qv '^127.0.0.1:' && fail "TorrServer 8090 is beyond loopback in public mode" || pass "TorrServer stays on 127.0.0.1:8090; only Caddy publishes (${PORT}, 80)"
ss -ltn | grep -qE ":${PORT}\b" && pass "Caddy listens on ${PORT}" || fail "nothing listens on ${PORT}"
echo "-- fail2ban jail"
if systemctl is-active --quiet fail2ban; then
  for _ in $(seq 1 15); do fail2ban-client status 2>/dev/null | grep -q torrserver-caddy && break; sleep 2; done
  fail2ban-client status 2>/dev/null | grep -q torrserver-caddy && pass "jail torrserver-caddy is running" || fail "jail torrserver-caddy is not running: $(fail2ban-client status 2>&1 | tr '\n' ' ')"
  for _ in $(seq 1 10); do code "${R[@]}" -u "$TS_USER:bad$RANDOM" "$BASE/settings" >/dev/null; done
  banned=0
  for _ in $(seq 1 30); do banned=$(fail2ban-client status torrserver-caddy 2>/dev/null | awk -F: '/Currently banned/ {gsub(/ /,"",$2); print $2}'); [[ "${banned:-0}" -ge 1 ]] && break; sleep 2; done
  if [[ "${banned:-0}" -ge 1 ]]; then pass "10 failed logins -> the address is banned by the jail"; else fail "no ban after 10 failed logins ($(fail2ban-client status torrserver-caddy 2>&1 | tr '\n' ' '))"; fi
  iptables -S DOCKER-USER 2>/dev/null | grep -q 'f2b-torrserver' && pass "ban rule sits in DOCKER-USER" || warn "no f2b-torrserver rule in DOCKER-USER (check iptables.txt)"
  for ip in $(fail2ban-client status torrserver-caddy 2>/dev/null | sed -n 's/.*Banned IP list:[[:space:]]*//p'); do fail2ban-client set torrserver-caddy unbanip "$ip" >/dev/null; done
else
  fail "fail2ban is not active after public install (installer says it installs it)"
fi
cat "$TS/.firewall-added" 2>/dev/null | sed 's/^/      firewall-added: /' || true
endgroup

group "3. switch back to local: what public mode opened is closed"
"${INSTALL[@]}" --local 2>&1 | tee "$W/install-switch.log" | tail -6
sleep 3
docker ps --format '{{.Names}}' | grep -qx torrserver-caddy && fail "Caddy still running after switching to local" || pass "Caddy removed"
ss -ltn | grep -qE ":(${PORT}|80)\b" && fail "port ${PORT} or 80 still listening" || pass "public port and 80 closed"
fail2ban-client status 2>/dev/null | grep -q torrserver-caddy && fail "jail still configured after leaving public mode" || pass "fail2ban jail removed"
expect_eq "local again: 200 with credentials" "$(code -u "$TS_USER:$TS_PASS" http://127.0.0.1:8090/settings -X POST -d '{"action":"get"}')" 200
"${INSTALL[@]}" --status 2>&1 | tee "$W/status.log" | head -8
endgroup

group "4. uninstall --purge leaves nothing"
"${INSTALL[@]}" --uninstall --purge 2>&1 | tail -5
[[ ! -e "$TS" ]] && pass "$TS is gone" || fail "$TS still exists"
[[ -z "$(docker ps -a --filter name=torrserver -q)" ]] && pass "no torrserver containers" || fail "torrserver containers remain"
[[ -z "$(docker volume ls -q | grep -i torrserver)" ]] && pass "no torrserver volumes" || fail "torrserver volumes remain: $(docker volume ls -q | grep -i torrserver | tr '\n' ' ')"
ls /etc/systemd/system/torrserver-cleanup.* /etc/fail2ban/jail.d/torrserver-caddy.conf /etc/fail2ban/filter.d/torrserver-caddy.conf /etc/systemd/system/fail2ban.service.d/torrserver.conf /etc/wireguard/wg0.conf 2>/dev/null && fail "files remain (listed above)" || pass "no units, jails or WireGuard files remain"
[[ -z "$(docker network ls --format '{{.Name}}' | grep -i torrserver)" ]] && pass "no torrserver networks" || fail "torrserver network remains"
iptables-save | grep -qi torrserver && fail "iptables rules mention torrserver" || pass "no iptables rules left"
endgroup

group "5. public mode again, IP found by the installer (real api.ipify.org)"
EXPECT_IP=$(curl -fsS -m 10 https://api.ipify.org)
log "ipify says ${EXPECT_IP}"
env -u PUBLIC_IP TS_TLS=internal "${INSTALL[@]}" 2>&1 | tee "$W/install-autodetect.log" | tail -14
grep -qi 'api.ipify.org' "$W/install-autodetect.log" && pass "the log says the IP came from api.ipify.org" || warn "log does not name api.ipify.org (metadata or route may have answered): $(grep -i 'public IP' "$W/install-autodetect.log" | head -2)"
expect_eq "PUBLIC_IP in .env is what ipify reports" "$(env_get PUBLIC_IP)" "$EXPECT_IP"
expect_eq "host name built from it" "$(env_get TS_HOSTNAME)" "${EXPECT_IP//./-}.sslip.io"
HOST=$(env_get TS_HOSTNAME); PORT=$(env_get TS_PUBLIC_PORT)
for _ in $(seq 1 30); do [[ "$(code --resolve "${HOST}:${PORT}:127.0.0.1" "https://${HOST}:${PORT}/echo")" == 200 ]] && break; sleep 2; done
expect_eq "auto-detected install: 401 without credentials" "$(code --resolve "${HOST}:${PORT}:127.0.0.1" "https://${HOST}:${PORT}/")" 401
creds
expect_eq "auto-detected install: 200 with credentials" "$(code --resolve "${HOST}:${PORT}:127.0.0.1" -u "$TS_USER:$TS_PASS" "https://${HOST}:${PORT}/settings" -X POST -d '{"action":"get"}')" 200
"${INSTALL[@]}" --uninstall --purge >/dev/null 2>&1 || true
endgroup
finish
