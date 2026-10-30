#!/usr/bin/env bash
# Smoke test for a RUNNING stack in local mode (127.0.0.1:8443). Read-only: logs in, never changes anything.
#   sudo tests/smoke.sh            checks unauthenticated rejection, blocked paths, exposed ports, TorrServer Basic
#   SMOKE_USER=admin SMOKE_PASS=... sudo tests/smoke.sh    also checks the Authelia login reaches ts.* and qbt.*
# Exits non-zero when a check fails.
set -Eeuo pipefail
DIR="${LAMPA_STACK_DIR:-/opt/lampa-stack}"
PORT="${SMOKE_PORT:-8443}"
D="${SMOKE_DOMAIN:-lampa.localhost}"
PROJECT=lampa-stack
fail=0
ok() { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }
req() { # host path [curl args...] -> prints "code redirect-target"
  local host="$1" path="$2"; shift 2
  curl -ksS -o /dev/null --max-time 10 --resolve "${host}:${PORT}:127.0.0.1" -w '%{http_code} %{redirect_url}' "$@" "https://${host}:${PORT}${path}"
}
expect() { # description, got, regex
  if [[ "$2" =~ $3 ]]; then ok "$1 ($2)"; else bad "$1 (got: $2, wanted: $3)"; fi
}

expect "login page reachable" "$(req "auth.$D" /)" '^200'
expect "ts.* without login redirects to the portal" "$(req "ts.$D" /)" "^302 https://auth\\.${D//./\\.}"
expect "qbt.* without login redirects to the portal" "$(req "qbt.$D" /)" "^302 https://auth\\.${D//./\\.}"
expect "ts.* API without login does not answer" "$(req "ts.$D" /settings -X POST -d '{"action":"get"}')" '^(302|303|401|403)'
expect "ts.* wrong Basic is refused by TorrServer" "$(req "ts.$D" /settings -X POST -d '{"action":"get"}' -H 'Authorization: Basic d3Jvbmc6d3Jvbmc=')" '^401'
expect "ts.* swagger docs blocked" "$(req "ts.$D" /swagger/index.html -H 'Authorization: Basic d3Jvbmc6d3Jvbmc=')" '^404'
for p in /admin /adminpanel /stats /weblog /ts /ADMIN /dlna; do
  expect "Lampac control path ${p} blocked" "$(req "$D" "$p")" '^404'
done
expect "lcrqpasswd header cannot open admin" "$(req "$D" /admin -H 'lcrqpasswd: x')" '^404'

if [[ -r "$DIR/secrets/ts_password" ]]; then
  pw=$(cat "$DIR/secrets/ts_password")
  expect "ts.* with the TorrServer Basic credential works (TV path)" "$(req "ts.$D" /settings -X POST -d '{"action":"get"}' -u "lampa:${pw}")" '^200'
fi

# Only Caddy (and the qBittorrent peer port, loopback by default) may publish host ports.
ports=$(docker ps --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Names}} {{.Ports}}')
echo "$ports" | sed 's/^/      /'
if echo "$ports" | grep -E 'lampac|torrserver|authelia' | grep -q -- '->'; then bad "a backend service publishes a host port"; else ok "no backend service publishes a host port"; fi
if echo "$ports" | grep -o '0\.0\.0\.0:[0-9]*' | grep -qv ':\(80\|443\)$'; then
  qp=$(grep -m1 '^QBT_PORT=' "$DIR/.env" | cut -d= -f2)
  if echo "$ports" | grep -o '0\.0\.0\.0:[0-9]*' | grep -qv ":\\(80\\|443\\|${qp}\\)\$"; then bad "unexpected 0.0.0.0 port"; else ok "only the opted-in qBittorrent peer port is public besides 80/443"; fi
else ok "no unexpected 0.0.0.0 ports"; fi
for p in 9118 9091 8090 8085; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then bad "127.0.0.1:${p} reachable from the host"; else ok "127.0.0.1:${p} not reachable from the host"; fi
done

if [[ -n "${SMOKE_USER:-}" && -n "${SMOKE_PASS:-}" ]]; then
  jar=$(mktemp); trap 'rm -f "$jar"' EXIT
  code=$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 10 --resolve "auth.${D}:${PORT}:127.0.0.1" -c "$jar" \
    -H 'Content-Type: application/json' -d "{\"username\":\"${SMOKE_USER}\",\"password\":\"${SMOKE_PASS}\",\"keepMeLoggedIn\":false}" \
    "https://auth.${D}:${PORT}/api/firstfactor")
  expect "Authelia first factor accepts the user" "$code" '^200'
  bc=$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 10 --resolve "auth.${D}:${PORT}:127.0.0.1" -H 'Content-Type: application/json' \
    -d "{\"username\":\"${SMOKE_USER}\",\"password\":\"wrong-${RANDOM}\",\"keepMeLoggedIn\":false}" "https://auth.${D}:${PORT}/api/firstfactor")
  expect "Authelia refuses a wrong password" "$bc" '^(401|403)'
  expect "ts.* with Authelia session works" "$(req "ts.$D" /settings -X POST -d '{"action":"get"}' -b "$jar")" '^200'
  expect "qbt.* with Authelia session reaches qBittorrent" "$(req "qbt.$D" / -b "$jar")" '^200'
fi
exit "$fail"
