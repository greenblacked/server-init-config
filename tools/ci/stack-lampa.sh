#!/usr/bin/env bash
# other/lampa-stack end to end on a real Docker host with internet: the REAL Lampac NextGen, TorrServer, qBittorrent, Authelia
# and Caddy images (pinned in .env.example), and a real WireGuard tunnel.
#   1 --local install, then tests/smoke.sh WITHOUT SMOKE_SKIP_LAMPAC (accsdb keys, SISI/online toggles, /online.js loaders,
#     second-layer checks inside the network) and WITH the Authelia login
#   2 --enable-sisi / --disable-sisi, smoke again each time
#   3 --add-device / --remove-device (key works, then is refused)
#   4 --vpn: IP override (PUBLIC_IP) once, then auto-detection through the real api.ipify.org; --add-device prints a WireGuard
#     config; a network namespace plays the phone: wg-quick up there, reach the stack through the tunnel; --remove-device revokes
#   5 --uninstall --purge leaves nothing
# Public mode is not run: it needs Let's Encrypt to reach port 80 of the CI VM from the internet (not possible), and the
# sslip.io name would point at the VM's public address. --vpn covers the public-IP detection code (it is shared).
# Installs wireguard-tools and changes iptables: CI only (or ALLOW_LOCAL=1 on a disposable VM). Usage: sudo tools/ci/stack-lampa.sh
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$CI_ROOT/other/lampa-stack"
[[ $EUID -eq 0 ]] || die "run as root (sudo)"
in_ci || [[ "${ALLOW_LOCAL:-0}" == 1 ]] || die "this installs packages and changes the firewall: set ALLOW_LOCAL=1 on a disposable VM"
W="$CI_OUT/lampa"; mkdir -p "$W"
DIR=/opt/lampa-stack
NS=ci-wgc
export LAMPA_STACK_DIR="$DIR"
INSTALL=(./install.sh)

collect() {
  docker ps -a > "$W/docker-ps.txt" 2>&1
  local c; for c in $(docker ps -a --filter label=com.docker.compose.project=lampa-stack --format '{{.Names}}'); do docker logs "$c" > "$W/$c.log" 2>&1; done
  iptables-save > "$W/iptables.txt" 2>&1; ip -br addr > "$W/ip-addr.txt" 2>&1; wg show > "$W/wg-show.txt" 2>&1
  cp "$DIR/.env" "$W/env.txt" 2>/dev/null
  true
}
on_exit() { local rc=$?; set +e; collect; ip netns pids "$NS" 2>/dev/null | xargs -r kill; ip netns del "$NS" 2>/dev/null; ip link del vwg0 2>/dev/null; exit "$rc"; }
trap on_exit EXIT

env_get() { grep -m1 "^$1=" "$DIR/.env" | cut -d= -f2-; }
code() { curl -ksS --noproxy '*' -m 10 -o /dev/null -w '%{http_code}' "$@" || true; }
lcode() { # path [curl args] against the local-mode Caddy (loopback with the stack's host name)
  local p="$1"; shift
  code --resolve "$(env_get BASE_HOST):$(env_get SITE_PORT):127.0.0.1" "$@" "https://$(env_get BASE_HOST):$(env_get SITE_PORT)${p}"
}
wait_lampa() { # wait until Lampac serves the Lampa page for the first user's key (LampaWeb is downloaded on first start)
  local key; key=$(head -n1 "$DIR/secrets/users.tsv" | cut -f3)
  for _ in $(seq 1 90); do [[ "$(lcode "/?token=${key}")" == 200 ]] && return 0; sleep 4; done
  return 1
}
smoke() { # name [env...] ; real Lampac, no SMOKE_SKIP_LAMPAC
  local name="$1"; shift
  if env "$@" bash tests/smoke.sh > "$W/smoke-${name}.log" 2>&1; then
    pass "smoke.sh ($name): $(grep -c '^PASS' "$W/smoke-${name}.log") checks, none failed"
  else
    grep '^FAIL' "$W/smoke-${name}.log" | head -20 || true
    fail "smoke.sh ($name): $(grep -c '^FAIL' "$W/smoke-${name}.log") failed (artifact smoke-${name}.log)"
  fi
}

group "1. --local with the real images"
"${INSTALL[@]}" --local 2>&1 | tee "$W/install-local.log" | tail -30
ADMIN_PW=$(sed -n 's/^ *user admin: web login password //p' "$W/install-local.log" | head -1)
[[ -n "$ADMIN_PW" ]] && pass "install printed the admin web password once" || fail "no admin password in the install output"
expect_eq "mode in .env" "$(env_get ACCESS_MODE)" local
for c in lampac torrserver qbittorrent authelia caddy; do
  docker ps --filter label=com.docker.compose.project=lampa-stack --format '{{.Names}}' | grep -q "$c" && pass "container $c is running" || fail "container $c is not running"
done
wait_lampa && pass "Lampac serves the Lampa page for a device key" || fail "Lampac did not serve the Lampa page in 6 minutes (LampaWeb download?)"
smoke local-sisi-off SMOKE_USER=admin SMOKE_PASS="$ADMIN_PW"
"${INSTALL[@]}" --status > "$W/status-local.log" 2>&1 && pass "--status exits 0" || fail "--status failed"
endgroup

group "2. SISI (18+) on and off"
"${INSTALL[@]}" --local --enable-sisi 2>&1 | tail -5
expect_eq "LAMPAC_SISI=1 in .env" "$(env_get LAMPAC_SISI)" 1
wait_lampa || fail "Lampac not ready after --enable-sisi"
smoke sisi-on SMOKE_USER=admin SMOKE_PASS="$ADMIN_PW"
KEY=$(head -n1 "$DIR/secrets/users.tsv" | cut -f3)
body=$(curl -ksS --noproxy '*' -m 20 --resolve "$(env_get BASE_HOST):$(env_get SITE_PORT):127.0.0.1" "https://$(env_get BASE_HOST):$(env_get SITE_PORT)/lampainit.js?token=${KEY}" || true)
grep -q '/sisi.js' <<<"$body" && pass "SISI on: lampainit.js loads /sisi.js" || fail "SISI on but lampainit.js does not load /sisi.js"
"${INSTALL[@]}" --local --disable-sisi 2>&1 | tail -5
expect_eq "LAMPAC_SISI=0 in .env" "$(env_get LAMPAC_SISI)" 0
wait_lampa || fail "Lampac not ready after --disable-sisi"
smoke sisi-off-again SMOKE_USER=admin SMOKE_PASS="$ADMIN_PW"
endgroup

group "3. devices"
"${INSTALL[@]}" --add-device tv 2>&1 | tee "$W/add-tv.log" | tail -12
TVKEY=$(awk -F'\t' '$1=="tv"{print $3}' "$DIR/secrets/users.tsv")
[[ -n "$TVKEY" ]] && pass "device tv has a key" || fail "no key for device tv"
expect_eq "device key opens the Lampa host" "$(lcode "/lite/events?token=${TVKEY}")" 200
"${INSTALL[@]}" --show tv > "$W/show-tv.log" 2>&1 && grep -q "$TVKEY" "$W/show-tv.log" && pass "--show prints the device URLs" || fail "--show tv"
"${INSTALL[@]}" --remove-device tv 2>&1 | tail -3
expect_match "revoked key is refused" "$(lcode "/lite/events?token=${TVKEY}")" '^(302|401|403)$'
endgroup

group "4. --vpn with a real WireGuard tunnel"
need wg || { apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q wireguard-tools qrencode; }
modprobe wireguard 2>/dev/null || true
echo "-- PUBLIC_IP override"
PUBLIC_IP=8.8.4.4 "${INSTALL[@]}" --vpn 2>&1 | tail -4
expect_eq "override is used" "$(env_get PUBLIC_IP)" 8.8.4.4
echo "-- auto-detection through api.ipify.org (no override; the Hetzner metadata address does not exist here)"
EXPECT_IP=$(curl -fsS -m 10 https://api.ipify.org)
log "ipify says ${EXPECT_IP}"
env -u PUBLIC_IP "${INSTALL[@]}" --vpn 2>&1 | tee "$W/install-vpn.log" | tail -12
expect_eq "mode in .env" "$(env_get ACCESS_MODE)" vpn
expect_eq "PUBLIC_IP in .env follows ipify after the override was dropped" "$(env_get PUBLIC_IP)" "$EXPECT_IP"
ip link show wg0 >/dev/null 2>&1 && pass "wg0 exists on the server" || fail "wg0 missing"
WGPORT=$(env_get WG_PORT)
expect_eq "wg0 listens on the port from .env" "$(wg show wg0 listen-port)" "$WGPORT"
"${INSTALL[@]}" --add-device phone > "$W/add-phone.log" 2>&1 || { tail -20 "$W/add-phone.log"; fail "--add-device phone failed"; }
awk '/^\[Interface\]/{p=1} p{print} /^PersistentKeepalive/{exit}' "$W/add-phone.log" > "$W/phone.conf.orig"
grep -q '^PrivateKey' "$W/phone.conf.orig" && pass "--add-device printed a WireGuard client config" || fail "no client config in the output"
grep -q "^Endpoint = ${EXPECT_IP}:${WGPORT}\$" "$W/phone.conf.orig" && pass "client Endpoint is the detected public IP and the WG port" || fail "client Endpoint is $(grep '^Endpoint' "$W/phone.conf.orig")"
grep -q '^AllowedIPs = 10.88.77.1/32$' "$W/phone.conf.orig" && pass "split tunnel: only the stack address is routed" || fail "AllowedIPs is not the single stack address"
# the phone is a network namespace joined to the host by a veth pair; its Endpoint is pointed at the host side of the pair
ip netns add "$NS"
ip link add vwg0 type veth peer name vwg1 netns "$NS"
ip addr add 10.98.0.1/30 dev vwg0; ip link set vwg0 up
ip -n "$NS" addr add 10.98.0.2/30 dev vwg1; ip -n "$NS" link set vwg1 up; ip -n "$NS" link set lo up
ip -n "$NS" route add default via 10.98.0.1
sed "s|^Endpoint = .*|Endpoint = 10.98.0.1:${WGPORT}|" "$W/phone.conf.orig" > "$W/phone.conf"; chmod 600 "$W/phone.conf"
HOSTN=$(env_get BASE_HOST); SPORT=$(env_get SITE_PORT)
ip netns exec "$NS" wg-quick up "$W/phone.conf" > "$W/wg-quick-up.log" 2>&1 && pass "wg-quick up in the client namespace" || { cat "$W/wg-quick-up.log"; fail "wg-quick up failed (kernel module?)"; }
vcurl() { ip netns exec "$NS" curl -ksS --noproxy '*' -m 8 -o /dev/null -w '%{http_code}' --resolve "${HOSTN}:${SPORT}:10.88.77.1" "$@" || true; }
PKEY=$(awk -F'\t' '$1=="phone"{print $3}' "$DIR/secrets/users.tsv")
ok=0; for _ in $(seq 1 10); do [[ "$(vcurl "https://${HOSTN}:${SPORT}/lite/events?token=${PKEY}")" == 200 ]] && { ok=1; break; }; sleep 2; done
(( ok )) && pass "through the tunnel: the stack answers 200 for the device key" || fail "no answer through the tunnel"
hs=$(ip netns exec "$NS" wg show phone latest-handshakes | awk '{print $2}')
[[ "${hs:-0}" -gt 0 ]] && pass "a WireGuard handshake happened" || fail "no handshake recorded"
expect_match "through the tunnel without a key: redirected to the login" "$(vcurl "https://${HOSTN}:${SPORT}/lite/events")" '^302$'
expect_eq "through the tunnel: login page reachable" "$(vcurl --resolve "auth.${HOSTN}:${SPORT}:10.88.77.1" "https://auth.${HOSTN}:${SPORT}/")" 200
smoke vpn SMOKE_USER=admin SMOKE_PASS="$ADMIN_PW"
"${INSTALL[@]}" --remove-device phone 2>&1 | tail -3
sleep 2
if wg show wg0 peers | grep -q .; then fail "wg0 still has peers after --remove-device"; else pass "peer removed from wg0"; fi
r=$(vcurl "https://${HOSTN}:${SPORT}/lite/events?token=${PKEY}")
[[ "$r" != 200 ]] && pass "revoked device: no answer through the tunnel any more (${r})" || fail "revoked device still reaches the stack"
endgroup

group "5. uninstall --purge leaves nothing"
ip netns exec "$NS" wg-quick down "$W/phone.conf" >/dev/null 2>&1 || true
"${INSTALL[@]}" --uninstall --purge 2>&1 | tail -5
[[ ! -e "$DIR" ]] && pass "$DIR is gone" || fail "$DIR remains"
[[ -z "$(docker ps -a --filter label=com.docker.compose.project=lampa-stack -q)" ]] && pass "no stack containers" || fail "containers remain"
[[ -z "$(docker volume ls -q --filter label=com.docker.compose.project=lampa-stack)" ]] && pass "no stack volumes" || fail "volumes remain"
ip link show wg0 >/dev/null 2>&1 && fail "wg0 remains" || pass "wg0 removed"
ls /etc/wireguard/wg0.conf /etc/systemd/system/lampa-stack-cleanup.* /etc/systemd/system/docker.service.d/*lampa* 2>/dev/null && fail "files remain (listed above)" || pass "no WireGuard config or timer files remain"
endgroup
finish
