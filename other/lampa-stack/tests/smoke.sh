#!/usr/bin/env bash
# Smoke test for a RUNNING stack, from the server itself (connects to 127.0.0.1 with the stack's host names; works in
# every mode because Caddy always listens on loopback). Read-only: it logs in, it never changes anything.
#   sudo tests/smoke.sh            checks that nothing is anonymous: every path of every host is refused without a
#                                  login or a key, that keys / tokens open exactly their own door, ports, headers
#   SMOKE_SKIP_LAMPAC=1            skip the checks that need the real Lampac (they fail against a stub)
#   SMOKE_USER=admin SMOKE_PASS=.. also checks the Authelia login (session reaches ts.*, qbt.* and the Lampa host)
#   SMOKE_BAN=1                    with the login: also trips Authelia's regulation (locks that user for the ban time)
# Exits non-zero when a check fails.
set -Eeuo pipefail
DIR="${LAMPA_STACK_DIR:-/opt/lampa-stack}"
PROJECT=lampa-stack
env_get() { grep -m1 "^$1=" "$DIR/.env" | cut -d= -f2- || true; }
D="${SMOKE_DOMAIN:-$(env_get BASE_HOST)}"
PORT="${SMOKE_PORT:-$(env_get SITE_PORT)}"
MODE=$(env_get ACCESS_MODE)
SKIP_LAMPAC="${SMOKE_SKIP_LAMPAC:-0}"
fail=0
ok() { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; fail=1; }
req() { # host path [curl args...] -> prints "code redirect-target"
  local host="$1" path="$2"; shift 2
  curl -ksS --noproxy '*' -o /dev/null --max-time 10 --resolve "${host}:${PORT}:127.0.0.1" -w '%{http_code} %{redirect_url}' "$@" "https://${host}:${PORT}${path}"
}
body() { local host="$1" path="$2"; shift 2; curl -ksS --noproxy '*' --max-time 10 --resolve "${host}:${PORT}:127.0.0.1" "$@" "https://${host}:${PORT}${path}"; }
expect() { # description, got, regex
  if [[ "$2" =~ $3 ]]; then ok "$1 ($2)"; else bad "$1 (got: $2, wanted: $3)"; fi
}
LOGIN="^302 https://auth\\.${D//./\\.}"
LOGIN_POST="^30[23] https://auth\\.${D//./\\.}"   # a POST is answered with 303

[[ -r "$DIR/secrets/users.tsv" ]] || { echo "needs root (secrets/users.tsv)"; exit 2; }
KEY=$(head -n1 "$DIR/secrets/users.tsv" | cut -f3)
TOK=$(head -n1 "$DIR/secrets/users.tsv" | cut -f4)
echo "mode ${MODE}, https://${D}:${PORT}"

expect "login page reachable" "$(req "auth.$D" /)" '^200'
expect "ts.* without login redirects to the portal" "$(req "ts.$D" /)" "$LOGIN"
expect "qbt.* without login redirects to the portal" "$(req "qbt.$D" /)" "$LOGIN"
expect "Lampa host without a key redirects to the portal" "$(req "$D" /)" "$LOGIN"

# --- TorrServer: no path is anonymous, in particular not the ones players use
for p in '/stream/x.mp4?link=0000000000000000000000000000000000000000&index=1&play' '/stream' '/play/0000000000000000000000000000000000000000/1' \
         '/subs/x' '/playlist?hash=0000000000000000000000000000000000000000' '/playlist/x.m3u' '/settings' '/torrents' '/echo' '/shutdown' '/viewed'; do
  expect "ts.* ${p%%\?*} without token / session is refused" "$(req "ts.$D" "$p")" "$LOGIN"
done
expect "ts.* CORS preflight without token is refused" "$(req "ts.$D" /settings -X OPTIONS -H "Origin: https://${D}:${PORT}" -H 'Access-Control-Request-Method: POST')" "$LOGIN"
expect "ts.* POST without token is refused" "$(req "ts.$D" /settings -X POST -d '{"action":"get"}')" "$LOGIN_POST"
expect "ts.* a wrong Basic header is refused" "$(req "ts.$D" /settings -X POST -d '{"action":"get"}' -H 'Authorization: Basic d3Jvbmc6d3Jvbmc=')" "$LOGIN_POST"
expect "ts.* a made-up token is refused" "$(req "ts.$D" /t/00000000000000000000000000000000/echo)" "$LOGIN"
expect "ts.* a token of the wrong length is refused" "$(req "ts.$D" "/t/${TOK:0:16}/echo")" "$LOGIN"
expect "ts.* the main key is not a TorrServer token" "$(req "ts.$D" "/t/${KEY}/echo")" "$LOGIN"
expect "ts.* the token in a query string does not count" "$(req "ts.$D" "/echo?token=${TOK}")" "$LOGIN"
expect "ts.* swagger docs blocked" "$(req "ts.$D" "/t/${TOK}/swagger/index.html")" '^404 '
expect "ts.* with the device token works (Lampa on the TV)" "$(req "ts.$D" "/t/${TOK}/settings" -X POST -d '{"action":"get"}')" '^200'
expect "ts.* CORS preflight with the token is answered" "$(req "ts.$D" "/t/${TOK}/settings" -X OPTIONS -H "Origin: https://${D}:${PORT}" -H 'Access-Control-Request-Method: POST')" '^2[0-9][0-9] $'
expect "ts.* the torrent list with the token reaches TorrServer" "$(req "ts.$D" "/t/${TOK}/torrents" -X POST -d '{"action":"list"}')" '^200'
expect "ts.* cross-site POST with a session cookie is refused" "$(req "ts.$D" /settings -X POST -d '{}' -H 'Sec-Fetch-Site: same-site' -H 'Cookie: lampa_session=x')" "$LOGIN_POST|^403"
if [[ -r "$DIR/secrets/ts_password" ]]; then
  pw=$(cat "$DIR/secrets/ts_password")
  # TorrServer's own layer: the container refuses a request without its Basic credential, even from inside the stack
  got=$(docker exec "${PROJECT}-qbittorrent-1" curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -X POST -d '{"action":"get"}' http://torrserver:8090/settings 2>/dev/null || true)
  expect "TorrServer itself refuses an unauthenticated request (second layer)" "${got} " '^401 '
  # the credential must not be visible in any process list, inside or outside the containers
  ps_all=$({ ps -eo args; docker exec "${PROJECT}-torrserver-1" ps -eo args 2>/dev/null; docker exec "${PROJECT}-qbittorrent-1" ps -eo args 2>/dev/null; } || true)
  if grep -qF -- "$pw" <<<"$ps_all"; then bad "the TorrServer password is visible in a process list"; else ok "the TorrServer password is in no process list"; fi
  if grep -qF -- "$(printf 'lampa:%s' "$pw" | base64 -w0)" <<<"$ps_all"; then bad "the TorrServer Basic header is visible in a process list"; else ok "the TorrServer Basic header is in no process list"; fi
fi

# --- Lampa host (Lampac): no key, no entry
for p in / /online.js /sisi.js /lampainit.js /privateinit.js /on.js /startpage.js /version /reqinfo /api/geo /api/myip /testaccsdb /lite/events /sisi /externalids /app.min.js /online/js/bad /on/js/bad; do
  expect "Lampa host ${p} without a key is refused" "$(req "$D" "$p")" "$LOGIN"
done
expect "Lampa host with a wrong key is refused" "$(req "$D" "/lite/events?token=00000000000000000000000000000000")" "$LOGIN"
expect "Lampa host: the TorrServer token is not a Lampa key" "$(req "$D" "/lite/events?token=${TOK}")" "$LOGIN"
expect "Lampa host: key in a cookie of the wrong name is refused" "$(req "$D" /app.min.js -H "Cookie: token=${KEY}")" "$LOGIN"
for p in /admin /adminpanel /stats /weblog /ts /ADMIN /dlna /extensions /api/headers; do
  expect "Lampac control / plugin-store path ${p} blocked even with a key" "$(req "$D" "$p?token=${KEY}")" '^404'
done
expect "lcrqpasswd header cannot open admin" "$(req "$D" /admin -H 'lcrqpasswd: x')" '^404'
expect "Lampa host with the key (query) is served" "$(req "$D" "/lite/events?token=${KEY}")" '^200'
expect "Lampa host with the key as account_email is served" "$(req "$D" "/lite/events?account_email=${KEY}")" '^200'
expect "Lampa host with the key in the /on/js/ loader path is served" "$(req "$D" "/on/js/${KEY}")" '^200'
expect "Lampa host with the key in the /online/js/ loader path is served" "$(req "$D" "/online/js/${KEY}")" '^200'
cookie=$(curl -ksS --noproxy '*' -D- -o /dev/null --max-time 10 --resolve "${D}:${PORT}:127.0.0.1" "https://${D}:${PORT}/?token=${KEY}" | tr -d '\r' | sed -n 's/^[Ss]et-[Cc]ookie: \(lampa_key=[^;]*\);.*/\1/p')
expect "a valid ?token= sets the key cookie" "${cookie:+set }" '^set'
expect "the cookie alone opens the page assets" "$(req "$D" /app.min.js -H "Cookie: ${cookie}")" '^(200|404) '
if [[ "$(env_get LAMPAC_PROXY_ANON)" == 1 ]]; then
  got=$(req "$D" /proxy/zzz)
  if [[ "$got" =~ $LOGIN ]]; then bad "/proxy/ should be open (LAMPAC_PROXY_ANON=1): $got"; else ok "signed /proxy links are open as configured (LAMPAC_PROXY_ANON=1) ($got)"; fi
else
  expect "/proxy/ needs a key (LAMPAC_PROXY_ANON=0)" "$(req "$D" /proxy/zzz)" "$LOGIN"
fi
hdr=$(curl -ksS --noproxy '*' -D- -o /dev/null --max-time 10 --resolve "auth.${D}:${PORT}:127.0.0.1" "https://auth.${D}:${PORT}/" | tr -d '\r')
if [[ "$MODE" == public ]]; then
  if grep -qi '^strict-transport-security: max-age=31536000; includeSubDomains' <<<"$hdr"; then ok "HSTS is sent in public mode"; else bad "no HSTS header in public mode"; fi
fi
if grep -qi '^x-content-type-options: nosniff' <<<"$hdr"; then ok "security headers are sent"; else bad "no X-Content-Type-Options header"; fi

# Real Lampac only: the Lampa page, https links in what it generates, and the key check inside Lampac.
if [[ "$SKIP_LAMPAC" != 1 ]]; then
  expect "Lampa page is served (LampaWeb downloaded it)" "$(req "$D" "/?token=${KEY}")" '^200'
  b=$(body "$D" "/lampainit.js?token=${KEY}" || true)
  if grep -Eq "http://[^'\" ]*${D//./\\.}" <<<"$b"; then bad "lampainit.js builds http:// links to this host"; else ok "lampainit.js has no http:// links to this host"; fi
  for s in pirate_store /extensions cubproxy.js tmdbproxy.js ts.js timecode.js jacred; do
    if grep -q -- "$s" <<<"$b"; then bad "lampainit.js still references ${s}"; else ok "lampainit.js does not reference ${s}"; fi
  done
  if grep -q '/online.js' <<<"$b"; then ok "lampainit.js loads /online.js"; else bad "lampainit.js does not load /online.js"; fi
  if [[ "$(env_get LAMPAC_SISI)" == 1 ]]; then
    if grep -q '/sisi.js' <<<"$b"; then ok "SISI enabled: lampainit.js loads /sisi.js"; else bad "SISI enabled but lampainit.js does not load /sisi.js"; fi
  else
    if grep -q '/sisi.js' <<<"$b"; then bad "SISI is off but lampainit.js loads /sisi.js"; else ok "SISI off: lampainit.js does not load /sisi.js"; fi
    expect "SISI off: /sisi.js is gone even with a key" "$(req "$D" "/sisi.js?token=${KEY}")" '^(404|500) '
  fi
  appjs=$(body "$D" "/app.min.js?token=${KEY}" --max-time 20 || true)
  if grep -Eq "${D//./\\.}(:[0-9]+)?/(cub|tmdb)" <<<"$appjs"; then bad "app.min.js routes CUB/TMDB through this host (those modules are skipped)"; else ok "app.min.js does not route CUB/TMDB through this host"; fi
  # Lampac's own accsdb (second layer): reach it from inside the network, without Caddy's check
  anon=$(docker exec "${PROJECT}-qbittorrent-1" curl -sS --max-time 10 'http://lampac:9118/lite/events' 2>/dev/null || true)
  if grep -q '"accsdb":true' <<<"$anon"; then ok "Lampac itself refuses an anonymous API call (accsdb, second layer)"; else bad "Lampac answered an anonymous API call: ${anon:0:80}"; fi
  ok_body=$(body "$D" "/lite/events?token=${KEY}" || true)
  if grep -q '"accsdb":true' <<<"$ok_body"; then bad "Lampac refused a valid key"; else ok "Lampac accepts a key from users.json"; fi
fi

# Only Caddy (and the qBittorrent peer port, loopback by default) may publish host ports.
ports=$(docker ps --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Names}} {{.Ports}}')
echo "$ports" | sed 's/^/      /'
if echo "$ports" | grep -E 'lampac|torrserver|authelia' | grep -q -- '->'; then bad "a backend service publishes a host port"; else ok "no backend service publishes a host port"; fi
qp=$(env_get QBT_PORT)
if [[ "$MODE" == public ]]; then allowed="${PORT}|80|${qp}"; else allowed="${qp}"; fi
if echo "$ports" | grep -o '0\.0\.0\.0:[0-9]*' | sort -u | grep -Evq ":(${allowed})\$"; then bad "unexpected 0.0.0.0 port"; else ok "only expected ports are public (${MODE}: ${allowed//|/ })"; fi
if [[ "$MODE" != public ]] && echo "$ports" | grep -q '0\.0\.0\.0:80->'; then bad "port 80 is published outside public mode"; else ok "port 80 only in public mode"; fi
for p in 9118 9091 8090 8085; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then bad "127.0.0.1:${p} reachable from the host"; else ok "127.0.0.1:${p} not reachable from the host"; fi
done

if [[ -n "${SMOKE_USER:-}" && -n "${SMOKE_PASS:-}" ]]; then
  jar=$(mktemp); trap 'rm -f "$jar"' EXIT
  code=$(curl -ksS --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 10 --resolve "auth.${D}:${PORT}:127.0.0.1" -c "$jar" \
    -H 'Content-Type: application/json' -d "{\"username\":\"${SMOKE_USER}\",\"password\":\"${SMOKE_PASS}\",\"keepMeLoggedIn\":false}" \
    "https://auth.${D}:${PORT}/api/firstfactor")
  expect "Authelia first factor accepts the user" "$code" '^200'
  bc=$(curl -ksS --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 10 --resolve "auth.${D}:${PORT}:127.0.0.1" -H 'Content-Type: application/json' \
    -d "{\"username\":\"${SMOKE_USER}\",\"password\":\"wrong-${RANDOM}\",\"keepMeLoggedIn\":false}" "https://auth.${D}:${PORT}/api/firstfactor")
  expect "Authelia refuses a wrong password" "$bc" '^(401|403)'
  expect "ts.* with Authelia session works" "$(req "ts.$D" /settings -X POST -d '{"action":"get"}' -b "$jar")" '^200'
  expect "ts.* /echo with the session reaches TorrServer" "$(req "ts.$D" /echo -b "$jar")" '^200'
  expect "ts.* cross-site POST with a valid session is refused" "$(req "ts.$D" /settings -X POST -d '{"action":"get"}' -H 'Sec-Fetch-Site: same-site' -b "$jar")" '^403'
  expect "Lampa host with the session gets the user's key added" "$(req "$D" /lite/events -b "$jar")" '^200'
  if [[ "$SKIP_LAMPAC" == 1 ]]; then
    seen=$(body "$D" /x -b "$jar" || true)
    ukey=$(awk -F'\t' -v u="$SMOKE_USER" '$1 == u {print $3}' "$DIR/secrets/users.tsv")
    if grep -q "token=${ukey}" <<<"$seen"; then ok "the stub saw ?token=<the user's key>"; else bad "no key reached Lampac for a session user (${seen:0:100})"; fi
  fi
  expect "Lampa host: session + cross-site POST is refused" "$(req "$D" /x -X POST -d '{}' -H 'Sec-Fetch-Site: cross-site' -b "$jar")" '^403'
  expect "qbt.* with Authelia session reaches qBittorrent" "$(req "qbt.$D" / -b "$jar")" '^200'
  # regulation: repeated wrong passwords ban the account (last, it locks the user for the ban time)
  if [[ "${SMOKE_BAN:-0}" == 1 ]]; then
    for _ in 1 2 3 4; do curl -ksS --noproxy '*' -o /dev/null --max-time 10 --resolve "auth.${D}:${PORT}:127.0.0.1" -H 'Content-Type: application/json' \
      -d "{\"username\":\"${SMOKE_USER}\",\"password\":\"wrong-${RANDOM}\",\"keepMeLoggedIn\":false}" "https://auth.${D}:${PORT}/api/firstfactor"; done
    expect "Authelia bans the user after repeated failures (even the right password; Authelia answers 401, the log says banned)" "$(curl -ksS --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 10 --resolve "auth.${D}:${PORT}:127.0.0.1" -H 'Content-Type: application/json' \
      -d "{\"username\":\"${SMOKE_USER}\",\"password\":\"${SMOKE_PASS}\",\"keepMeLoggedIn\":false}" "https://auth.${D}:${PORT}/api/firstfactor")" '^(401|403|429)'
    if docker logs "${PROJECT}-authelia-1" 2>&1 | grep -q "they are banned until"; then ok "Authelia logged the ban"; else bad "no ban in the Authelia log"; fi
  fi
fi
exit "$fail"
