#!/usr/bin/env bash
# Smoke test for a RUNNING stack in local mode (127.0.0.1:8443). Read-only: logs in, never changes anything.
#   sudo tests/smoke.sh            checks unauthenticated rejection, blocked paths, exposed ports, TorrServer Basic
#   SMOKE_SKIP_LAMPAC=1 skips the checks that need the real Lampac (they fail against a stub)
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
expect "ts.* wrong Basic does not reach TorrServer (goes to the login)" "$(req "ts.$D" /settings -X POST -d '{"action":"get"}' -H 'Authorization: Basic d3Jvbmc6d3Jvbmc=')" '^(302|303|401|403)'
expect "ts.* swagger docs blocked" "$(req "ts.$D" /swagger/index.html -H 'Authorization: Basic d3Jvbmc6d3Jvbmc=')" '^404'
for p in /admin /adminpanel /stats /weblog /ts /ADMIN /dlna; do
  expect "Lampac control path ${p} blocked" "$(req "$D" "$p")" '^404'
done
expect "lcrqpasswd header cannot open admin" "$(req "$D" /admin -H 'lcrqpasswd: x')" '^404'
expect "Lampac header echo endpoint blocked" "$(req "$D" /api/headers)" '^404'

# TV / player paths on ts.*: no Authelia redirect, TorrServer answers itself.
pre=$(curl -ksS -o /dev/null --max-time 10 --resolve "ts.${D}:${PORT}:127.0.0.1" -X OPTIONS \
  -H "Origin: https://${D}:${PORT}" -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: authorization,content-type' \
  -w '%{http_code} %{redirect_url}' "https://ts.${D}:${PORT}/settings")
expect "ts.* CORS preflight is answered by TorrServer, not the login" "$pre" '^2[0-9][0-9] $'
expect "ts.* playback of an unknown torrent is refused by TorrServer (401, not the login)" \
  "$(req "ts.$D" '/stream/x.mp4?link=0000000000000000000000000000000000000000&index=1&play')" '^401'
expect "ts.* preload without credentials is refused by TorrServer" \
  "$(req "ts.$D" '/stream/x.mp4?link=0000000000000000000000000000000000000000&index=1&preload')" '^401'
expect "ts.* cross-site POST with a session cookie is refused" "$(req "ts.$D" /settings -X POST -d '{}' -H 'Sec-Fetch-Site: same-site' -H 'Cookie: lampa_session=x')" '^(302|303|401|403)'

if [[ -r "$DIR/secrets/ts_password" ]]; then
  pw=$(cat "$DIR/secrets/ts_password")
  # credential via a curl config on a pipe, not on the command line
  expect "ts.* with the TorrServer Basic credential works (TV path)" "$(req "ts.$D" /settings -X POST -d '{"action":"get"}' -K <(printf 'user = "lampa:%s"\n' "$pw"))" '^200'
fi

# Real Lampac only: the Lampa page, https links in what it generates, and the token check.
if [[ "${SMOKE_SKIP_LAMPAC:-0}" != 1 ]]; then
  expect "Lampa page is served (LampaWeb downloaded it)" "$(req "$D" /)" '^200'
  body=$(curl -ksS --max-time 10 --resolve "${D}:${PORT}:127.0.0.1" "https://${D}:${PORT}/lampainit.js" || true)
  if grep -Eq "http://[^'\" ]*${D//./\\.}" <<<"$body"; then bad "lampainit.js builds http:// links to this host"; else ok "lampainit.js has no http:// links to this host"; fi
  body=$(curl -ksS --max-time 10 --resolve "${D}:${PORT}:127.0.0.1" "https://${D}:${PORT}/lampainit.js" || true)
  if grep -Eq "jackett_url[^;]*${D//./\\.}" <<<"$body"; then bad "lampainit.js points jackett_url at this host (JacRed is skipped)"; else ok "lampainit.js leaves jackett_url alone"; fi
  appjs=$(curl -ksS --max-time 20 --resolve "${D}:${PORT}:127.0.0.1" "https://${D}:${PORT}/app.min.js" || true)
  if grep -Eq "${D//./\\.}(:[0-9]+)?/(cub|tmdb)" <<<"$appjs"; then bad "app.min.js routes CUB/TMDB through this host (those modules are skipped)"; else ok "app.min.js does not route CUB/TMDB through this host"; fi
  anon=$(curl -ksS --max-time 10 --resolve "${D}:${PORT}:127.0.0.1" "https://${D}:${PORT}/lite/events" || true)
  if grep -q '"accsdb":true' <<<"$anon"; then ok "Lampac refuses an anonymous API call (accsdb)"; else bad "Lampac answered an anonymous API call: ${anon:0:80}"; fi
  if [[ -r "$DIR/secrets/users.tsv" ]]; then
    tok=$(head -n1 "$DIR/secrets/users.tsv" | cut -f2)
    ok_body=$(curl -ksS --max-time 10 --resolve "${D}:${PORT}:127.0.0.1" "https://${D}:${PORT}/lite/events?token=${tok}" || true)
    if grep -q '"accsdb":true' <<<"$ok_body"; then bad "Lampac refused a valid token"; else ok "Lampac accepts a token from users.json"; fi
  fi
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
  expect "ts.* cross-site POST with a valid session is refused" "$(req "ts.$D" /settings -X POST -d '{"action":"get"}' -H 'Sec-Fetch-Site: same-site' -b "$jar")" '^403'
  expect "main host never forwards the session cookie (header echo blocked)" "$(req "$D" /api/headers -b "$jar")" '^404'
  expect "qbt.* with Authelia session reaches qBittorrent" "$(req "qbt.$D" / -b "$jar")" '^200'
fi
exit "$fail"
