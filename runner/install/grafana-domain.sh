#!/usr/bin/env bash
# Publish Grafana on an HTTPS domain via Caddy (automatic Let's Encrypt).
# Requires: monitoring installed, A record pointing to this server (DNS only, no proxy), ports 80/443 open.
set -Eeuo pipefail
# shellcheck source=../../common/lib.sh
source "$(dirname "$0")/../../common/lib.sh"

DOMAIN="${DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2.10.0}"
DIR=/opt/monitoring

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || -z "$DOMAIN" || -z "$ACME_EMAIL" ]]; then
  echo "Usage: DOMAIN=grafana.example.com ACME_EMAIL=you@example.com $0"
  [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && exit 0
  exit 1
fi
require_root
[[ -f "$DIR/docker-compose.yml" && -f "$DIR/.env" ]] || die "monitoring stack not found in $DIR"
command -v openssl >/dev/null || pkg_install openssl

server_ip=$(curl -fsS --max-time 5 http://169.254.169.254/hetzner/v1/metadata/public-ipv4 2>/dev/null || curl -4 -fsS --max-time 5 https://ifconfig.me)
dns_ip=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 { print $1 }')
log "server ip: $server_ip, dns ip: ${dns_ip:-<none>}"
[[ -n "$dns_ip" ]] || die "$DOMAIN does not resolve yet"
[[ "$dns_ip" == "$server_ip" ]] || die "$DOMAIN points to $dns_ip, expected $server_ip (DNS proxy enabled?)"
if ss -ltn | awk '$4 ~ /:(80|443)$/' | grep -q .; then die "ports 80/443 already in use"; fi

# Let's Encrypt (HTTP-01, TLS-ALPN) and visitors reach Caddy on the host network: open 80/443 in the host firewall if
# one runs. Only added, never removed, and SSH rules are not touched.
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  for svc in http https; do
    firewall-cmd --permanent --zone=public --add-service="$svc" >/dev/null && firewall-cmd --zone=public --add-service="$svc" >/dev/null \
      || die "cannot open ${svc} in firewalld"
  done
  log "firewalld: http and https opened in the public zone"
elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null || die "cannot open 80/443 in ufw"
  log "ufw: 80/tcp and 443/tcp opened"
fi

backup "$DIR/.env"
set_env() {
  if grep -q "^$1=" "$DIR/.env"; then sed -i "s|^$1=.*|$1=$2|" "$DIR/.env"; else echo "$1=$2" >> "$DIR/.env"; fi
}
set_env GF_SERVER_DOMAIN "$DOMAIN"
set_env GF_SERVER_ROOT_URL "https://${DOMAIN}/"
set_env GF_SECURITY_COOKIE_SECURE "true"
set_env GF_SECURITY_COOKIE_SAMESITE "lax"
set_env GF_SECURITY_DISABLE_GRAVATAR "true"
set_env GF_SECURITY_CONTENT_SECURITY_POLICY "true"
chmod 600 "$DIR/.env"

install -d -m 0755 "$DIR/caddy"
sed -e "s|__DOMAIN__|${DOMAIN}|g" -e "s|__ACME_EMAIL__|${ACME_EMAIL}|g" \
  "$REPO_ROOT/runner/stacks/monitoring/caddy/Caddyfile.tmpl" > "$DIR/caddy/Caddyfile"

cat > "$DIR/docker-compose.override.yml" <<YAML
services:
  caddy:
    image: ${CADDY_IMAGE}
    restart: unless-stopped
    network_mode: host
    mem_limit: 128m
    cap_add:
      - NET_BIND_SERVICE
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    depends_on: [grafana]

volumes:
  caddy-data:
  caddy-config:
YAML
restorecon_if -R "$DIR"

docker run --rm -v "$DIR/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" "$CADDY_IMAGE" \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

cd "$DIR"
docker compose pull -q caddy
docker compose up -d

ok=0
for _ in $(seq 1 40); do
  if curl -fsS --max-time 5 "https://${DOMAIN}/api/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 3
done
if [[ "$ok" != "1" ]]; then
  docker compose logs caddy --tail 40
  die "https://${DOMAIN} not reachable, check firewall ports 80/443 and DNS"
fi

echo | openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" 2>/dev/null | openssl x509 -noout -issuer -dates
curl -sS -o /dev/null -w "http redirect: %{http_code} -> %{redirect_url}\n" "http://${DOMAIN}/"
exposed=$(ss -ltn | awk '/:(3000|9090|9100|9252) / && $4 !~ /^127\.0\.0\.1:/' | wc -l)
[[ "$exposed" == "0" ]] || die "an internal port is exposed"
log "OK: https://${DOMAIN}"
