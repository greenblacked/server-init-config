#!/usr/bin/env bash
# Lampa stack installer: Caddy + Authelia + Lampac (serves Lampa) + TorrServer + qBittorrent.
# Idempotent: rerun after editing .env or after pulling a new version of this directory.
# Supported hosts: EL10 family (Rocky/Alma/CentOS Stream), Fedora 44, Debian 13, Ubuntu 26.04, openSUSE 16.
# Needs Docker Engine with the compose v2 plugin (install Docker first; this script does not).
set -Eeuo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR="${LAMPA_STACK_DIR:-/opt/lampa-stack}"
PROJECT=lampa-stack
UNIT_DIR=/etc/systemd/system

MODE_ARG=""          # public | local | vpn (empty: keep the mode from .env, default public)
SISI_ARG=""          # 1 | 0 from --enable-sisi / --disable-sisi
ENABLE_QBT_PORT=0
ACTION=install
TARGET_NAME=""
PURGE=0
NO_START=0
NO_FIREWALL=0
NO_SYSTEMD="${LAMPA_STACK_NO_SYSTEMD:-0}"
ADMIN_USER="${ADMIN_USER:-admin}"
NEW_CREDS=()   # lines printed once at the end
LAMPAC_CONF_CHANGED=0
AUTHELIA_CONF_CHANGED=0

log() { printf '\033[1;34m[lampa]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[lampa] WARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[lampa] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 [options]

Installs or updates the Lampa stack in ${DIR} (override with LAMPA_STACK_DIR).

Access mode (the choice is remembered in ${DIR}/.env; switching cleans up what the old mode opened)
  (no option)          PUBLIC (default): one HTTPS port on a random high TCP port, a Let's Encrypt certificate for
                       <your-ip-dashed>.sslip.io (or DOMAIN=...), port 80 opened for the certificate check only.
                       Every path needs a login or a per-device key.
  --local              nothing public: 127.0.0.1:8443 only, reached over an SSH tunnel
  --vpn                OPTIONAL: WireGuard (wg0, random UDP port); the stack is reachable only on the wg address
                       and on localhost. Needs wireguard-tools (the script installs it if it can).
  --public             same as the default (to switch back from --local / --vpn)
Devices and users (shown once; \`--show NAME\` prints the URLs of a device or user again)
  --add-device NAME    a TV / phone: a Lampac key + a TorrServer token; with --vpn also a WireGuard peer
                       (client config and QR code)
  --remove-device NAME revoke the keys and the WireGuard peer
  --add-user NAME      a person: login for the web UIs (Authelia) + their own key; --remove-user NAME revokes both
  --show NAME          print the URLs and keys of a device or user (never a password)
Modules
  --enable-sisi        enable SISI (18+, /sisi.js). Adults only. Off by default.
  --disable-sisi       disable it again (SISI and the Adult sources are not loaded)
Ports
  --enable-qbt-port    publish qBittorrent's peer port (random, remembered) on 0.0.0.0 and open it in the host firewall
Maintenance
  --rotate-secrets     new session secret, TorrServer / qBittorrent / Lampac root passwords, every user's password and
                       every key / token (everyone is logged out; devices must be re-paired; new values printed once)
  --export-ca          local / vpn mode: write Caddy's local CA certificate to ${DIR}/caddy-local-root.crt
  --status             mode, URLs, port, devices, enabled modules, containers, published ports, checks
  --uninstall          stop the stack, remove the cleanup timer, firewall rules and WireGuard; KEEPS ${DIR}/data and secrets
  --purge              with --uninstall: also delete ${DIR} (data, secrets) and Docker volumes
Other
  --no-start           write all files but do not start containers
  --no-firewall        do not touch the host firewall
  -h, --help           this help

Environment: DOMAIN (your own domain instead of sslip.io; ts./qbt./auth. subdomains must resolve to this server),
             PUBLIC_IP (skip the automatic detection), ACME_EMAIL (optional, certificate expiry mail),
             ADMIN_USER (first user, default admin), TZ, LAMPA_STACK_DIR, LAMPA_STACK_NO_SYSTEMD=1,
             LAMPA_STACK_SKIP_PULL=1 / LAMPA_STACK_SKIP_TLS_CHECK=1 (testing: use local images / do not wait for the certificate).
Settings live in ${DIR}/.env (see .env.example); rerun this script after editing it.
USAGE
}

parse_args() {
  while (( $# )); do
    case "$1" in
      --public) MODE_ARG=public ;;
      --local) MODE_ARG=local ;;
      --vpn) MODE_ARG=vpn ;;
      --enable-qbt-port) ENABLE_QBT_PORT=1 ;;
      --enable-sisi) SISI_ARG=1 ;;
      --disable-sisi) SISI_ARG=0 ;;
      --add-user|--add-device|--remove-user|--remove-device|--show)
        ACTION="${1#--}"; TARGET_NAME="${2:-}"
        [[ -n "$TARGET_NAME" ]] || die "$1 needs a name"
        shift ;;
      --rotate-secrets) ACTION=rotate ;;
      --status) ACTION=status ;;
      --export-ca) ACTION=export-ca ;;
      --uninstall) ACTION=uninstall ;;
      --purge) PURGE=1 ;;
      --no-start) NO_START=1 ;;
      --no-firewall) NO_FIREWALL=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
  done
  if (( PURGE )) && [[ "$ACTION" != uninstall ]]; then die "--purge only works with --uninstall"; fi
  return 0
}

# ---------------------------------------------------------------- helpers
# Credentials are printed once. If a later step fails, still show the ones already created.
print_pending() {
  if (( ${#NEW_CREDS[@]} )); then
    echo "Credentials created before the failure (shown once):" >&2
    printf '  %s\n' "${NEW_CREDS[@]}" >&2
  fi
  if (( ${#NEW_BLOCKS[@]} )); then printf '%s\n' "${NEW_BLOCKS[@]}" >&2; fi
}

dc() { docker compose --project-directory "$DIR" -p "$PROJECT" -f "$DIR/docker-compose.yml" -f "$DIR/compose.ports.yml" --env-file "$DIR/.env" "$@"; }

env_get() { [[ -f "$DIR/.env" ]] && grep -m1 "^$1=" "$DIR/.env" | cut -d= -f2- || true; }
env_set() { # KEY VALUE (value must not contain newline or '|')
  local k="$1" v="$2"
  if grep -q "^${k}=" "$DIR/.env"; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$DIR/.env"
  else
    printf '%s=%s\n' "$k" "$v" >> "$DIR/.env"
  fi
}
env_unset() { sed -i "/^$1=/d" "$DIR/.env"; }

rand_hex() { openssl rand -hex "$1"; }
rand_pw() { # 24 URL-safe alphanumerics from the CSPRNG
  local out=""
  while (( ${#out} < 24 )); do out+=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9'); done
  printf '%s' "${out:0:24}"
}

# ---------------------------------------------------------------- network helpers
valid_ipv4() { # a.b.c.d with every octet 0-255, no leading zeros
  local ip="$1" o
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  local IFS=.
  for o in $ip; do
    [[ "$o" == 0 || "$o" =~ ^[1-9][0-9]*$ ]] || return 1
    (( o <= 255 )) || return 1
  done
}
is_public_ipv4() { # valid and not loopback / private / link-local / CGNAT / multicast / reserved
  valid_ipv4 "$1" || return 1
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  (( a == 0 || a == 10 || a == 127 || a >= 224 )) && return 1
  (( a == 100 && b >= 64 && b <= 127 )) && return 1
  (( a == 169 && b == 254 )) && return 1
  (( a == 172 && b >= 16 && b <= 31 )) && return 1
  (( a == 192 && b == 168 )) && return 1
  (( a == 192 && b == 0 && c == 0 )) && return 1
  (( a == 192 && b == 0 && c == 2 )) && return 1
  (( a == 198 && (b == 18 || b == 19) )) && return 1
  (( a == 198 && b == 51 && c == 100 )) && return 1
  (( a == 203 && b == 0 && c == 113 )) && return 1
  return 0
}
dashed_ip() { printf '%s' "${1//./-}"; }

# Public IPv4 of this server, in order: the Hetzner metadata service, the source address the kernel would use to
# reach the internet (only when that is itself a public address), then api.ipify.org. Every answer is validated.
# The URLs can be overridden for tests (LAMPA_STACK_META_URL, LAMPA_STACK_IPIFY_URL).
detect_public_ip() {
  local ip="" meta="${LAMPA_STACK_META_URL:-http://169.254.169.254/hetzner/v1/metadata/public-ipv4}"
  local ipify="${LAMPA_STACK_IPIFY_URL:-https://api.ipify.org}"
  ip=$(curl -fsS --max-time 3 "$meta" 2>/dev/null | tr -d '[:space:]') || ip=""
  if is_public_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1) || ip=""
  if is_public_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi
  ip=$(curl -fsS --max-time 5 "$ipify" 2>/dev/null | tr -d '[:space:]') || ip=""
  if is_public_ipv4 "$ip"; then printf '%s' "$ip"; return 0; fi
  return 1
}

port_in_use() { # proto(tcp|udp) port
  if command -v ss >/dev/null 2>&1; then
    if [[ "$1" == tcp ]]; then ss -H -ltn "sport = :$2" 2>/dev/null | grep -q .; else ss -H -lun "sport = :$2" 2>/dev/null | grep -q .; fi
  elif [[ "$1" == tcp ]]; then
    (exec 3<>"/dev/tcp/127.0.0.1/$2") 2>/dev/null
  else
    return 1
  fi
}
ssh_ports() { { echo 22; sshd -T 2>/dev/null | awk '$1 == "port" {print $2}'; ss -Hltnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}'; } | sort -u; }
rand_port() { local n; n=$(od -An -N4 -tu4 /dev/urandom | tr -d ' '); echo $(( 20000 + n % 40001 )); }
pick_port() { # proto, then ports to avoid: a random free port in 20000-60000, never an SSH port
  local proto="$1" p sp bad; shift
  for _ in $(seq 1 200); do
    p=$(rand_port); bad=0
    for sp in "$@" $(ssh_ports); do [[ "$p" == "$sp" ]] && bad=1; done
    (( bad )) && continue
    port_in_use "$proto" "$p" && continue
    printf '%s' "$p"; return 0
  done
  die "no free ${proto} port found in 20000-60000"
}
mem_mb() { case "$1" in *[mM]) echo "${1%[mM]}" ;; *[gG]) echo $(( ${1%[gG]} * 1024 )) ;; *) echo 0 ;; esac; }

check_os() {
  local id="" ver="" like=""
  # shellcheck disable=SC1091
  [[ -r /etc/os-release ]] && . /etc/os-release && { id="${ID:-}"; ver="${VERSION_ID:-}"; like="${ID_LIKE:-}"; }
  case "${id}:${ver}" in
    rocky:10*|almalinux:10*|centos:10*|rhel:10*|fedora:44*|debian:13*|ubuntu:26.04*|opensuse-leap:16*|sles:16*) log "host: ${id} ${ver}" ;;
    *) warn "untested host (${id:-unknown} ${ver:-}; like: ${like:-none}); supported: EL10, Fedora 44, Debian 13, Ubuntu 26.04, openSUSE 16. Continuing." ;;
  esac
}

check_docker() {
  command -v docker >/dev/null || die "docker not found; install Docker Engine with the compose plugin first"
  docker info >/dev/null 2>&1 || die "docker daemon not reachable"
  docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin missing"
  command -v openssl >/dev/null || die "openssl not found"
  command -v python3 >/dev/null || die "python3 not found (derives the qBittorrent password hash without putting it on a command line)"
  command -v curl >/dev/null || die "curl not found"
}

selinux_note() {
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == Enforcing ]]; then
    log "SELinux is enforcing: bind mounts carry :z labels in docker-compose.yml"
  fi
}


# ---------------------------------------------------------------- files and layout
install_files() {
  # $DIR is 0750 root: Lampac and TorrServer data are owned by container uids (1000, STACK_UID) that may match a
  # human account on the host; without the search bit on $DIR those accounts cannot reach any of it.
  install -d -m 0750 "$DIR"
  install -d -m 0755 "$DIR/caddy" "$DIR/authelia" "$DIR/scripts" "$DIR/systemd" "$DIR/tests"
  install -d -m 0750 -o root -g 1000 "$DIR/lampac"   # init.conf, users.json (group-readable by the Lampac uid)
  install -d -m 0700 "$DIR/secrets"
  install -m 0644 "$SRC/docker-compose.yml" "$DIR/docker-compose.yml"
  install -m 0644 "$SRC/caddy/Caddyfile" "$DIR/caddy/Caddyfile"
  install -m 0644 "$SRC/authelia/configuration.yml.tmpl" "$DIR/authelia/configuration.yml.tmpl"
  install -m 0644 "$SRC/.env.example" "$DIR/.env.example"
  install -m 0755 "$SRC/scripts/cleanup.sh" "$DIR/scripts/cleanup.sh"
  install -m 0755 "$SRC/install.sh" "$DIR/install.sh"
  install -m 0755 "$SRC/tests/smoke.sh" "$DIR/tests/smoke.sh"
  install -m 0644 "$SRC/systemd/lampa-stack-cleanup.service" "$SRC/systemd/lampa-stack-cleanup.timer" "$DIR/systemd/"
  install -m 0644 "$SRC/README.md" "$DIR/README.md"
  # Data dirs: TorrServer and qBittorrent run as STACK_UID, Lampac as uid 1000 (fixed in its image; a host
  # account with uid 1000 is the same user to the kernel, which is why $DIR itself is closed to others).
  local uid; uid=$(env_get STACK_UID); uid="${uid:-10000}"
  install -d -m 0750 -o "$uid" -g "$uid" "$DIR/data/torrserver" "$DIR/data/torrserver/config" \
    "$DIR/data/torrserver/torrents" "$DIR/data/torrserver/cache" "$DIR/data/qbt" "$DIR/data/qbt/config" "$DIR/data/qbt/downloads"
  install -d -m 0750 -o 1000 -g 1000 "$DIR/data/lampac" "$DIR/data/lampac/database" "$DIR/data/lampac/cache" "$DIR/data/lampac/lampa-main"
  install -d -m 0750 "$DIR/data/authelia"
}

ensure_env() {
  if [[ ! -f "$DIR/.env" ]]; then
    install -m 0600 "$DIR/.env.example" "$DIR/.env"
    log "created ${DIR}/.env"
  else
    # add keys that a newer .env.example introduced, keep every existing value (including your edits)
    local line k
    while IFS= read -r line; do
      [[ "$line" =~ ^[A-Z0-9_]+= ]] || continue
      k="${line%%=*}"
      grep -q "^${k}=" "$DIR/.env" || { printf '%s\n' "$line" >> "$DIR/.env"; log ".env: added ${k}"; }
    done < "$DIR/.env.example"
    chmod 0600 "$DIR/.env"
  fi
  # keys of the first version of this stack: a DOMAIN other than the local one was a custom domain; the rest is
  # derived from the access mode now
  local old; old=$(env_get DOMAIN)
  if [[ -n "$old" && "$old" != lampa.localhost && -z "$(env_get DOMAIN_CUSTOM)" ]]; then env_set DOMAIN_CUSTOM "$old"; fi
  for old in DOMAIN SITE_PREFIX SITE_SUFFIX TLS_LINE AUTH_URL_SCHEME AUTH_URL_PORT PUBLISH_HTTP PUBLISH_HTTPS; do env_unset "$old"; done
  [[ -n "${TZ:-}" ]] && env_set TZ "$TZ"
  if [[ -n "$SISI_ARG" ]]; then
    env_set LAMPAC_SISI "$SISI_ARG"
    if [[ "$SISI_ARG" == 1 ]]; then log "SISI (18+, /sisi.js) enabled: for adults only. Add the sisi plugin URL shown by --show NAME in Lampa."; else log "SISI (18+) disabled"; fi
  fi
  local k v
  for k in STACK_UID QBT_WEBUI_PORT QBT_PORT TS_CACHE_MB TS_IDLE_SECONDS LOCAL_PORT; do
    v=$(env_get "$k"); [[ "$v" =~ ^[1-9][0-9]*$ ]] || die "invalid ${k} in .env: '${v}'"
  done
  for k in TS_PRELOAD_PCT TS_READAHEAD_PCT; do
    v=$(env_get "$k"); [[ "$v" =~ ^[0-9]+$ ]] && (( v <= 100 )) || die "${k} must be 0-100 (got '${v}')"
  done
  (( $(env_get TS_READAHEAD_PCT) >= 5 )) || die "TS_READAHEAD_PCT must be 5-100"
  for k in LAMPAC_ONLINE LAMPAC_SISI LAMPAC_PROXY_ANON; do
    [[ "$(env_get "$k")" =~ ^[01]$ ]] || die "${k} must be 0 or 1"
  done
  [[ "$(env_get LAMPAC_PROXY_ANON)" == 1 ]] && log "LAMPAC_PROXY_ANON=1 (default): signed /proxy* media links are reachable without a key; set it to 0 in .env to close them"
  [[ "$(env_get AUTHELIA_POLICY)" =~ ^(one_factor|two_factor)$ ]] || die "AUTHELIA_POLICY must be one_factor or two_factor"
  [[ "$(env_get QBT_MAX_RATIO)" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "invalid QBT_MAX_RATIO"
  [[ "$(env_get QBT_MAX_SEED_MINUTES)" =~ ^[0-9]+$ ]] || die "invalid QBT_MAX_SEED_MINUTES"
  [[ "$(env_get QBT_DELETE_COMPLETED_DAYS)" =~ ^[0-9]+$ ]] || die "invalid QBT_DELETE_COMPLETED_DAYS"
  [[ "$(env_get QBT_USER)" =~ ^[A-Za-z][A-Za-z0-9_]{1,31}$ ]] || die "invalid QBT_USER"
  [[ "$(env_get LAMPA_AUTOUPDATE)" =~ ^(true|false)$ ]] || die "LAMPA_AUTOUPDATE must be true or false"
  [[ "$(env_get LAMPA_TREE)" =~ ^[0-9a-f]{40}$ ]] || die "LAMPA_TREE must be a 40-character git commit id"
  [[ "$(env_get WG_NET)" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || die "WG_NET must look like 10.88.77"
  # The RAM cache lives inside TorrServer's memory limit: cache + about 160 MB for the Go runtime, peers and buffers.
  local ts_mem; ts_mem=$(mem_mb "$(env_get TORRSERVER_MEM)")
  (( ts_mem > 0 )) || die "invalid TORRSERVER_MEM: $(env_get TORRSERVER_MEM)"
  (( $(env_get TS_CACHE_MB) + 160 <= ts_mem )) || die "TS_CACHE_MB=$(env_get TS_CACHE_MB) does not fit TORRSERVER_MEM=$(env_get TORRSERVER_MEM) (needs cache + 160 MB); lower the cache or raise the limit"
  env_set TS_GOMEMLIMIT_MB "$(( ts_mem - 48 ))"
  return 0
}

# Access mode, public address, host name and ports. Everything is written to .env so the compose file, the
# templates and the next run see the same values.
resolve_mode() {
  local mode ip stored custom host port
  PREV_MODE=$(env_get ACCESS_MODE)
  mode="${MODE_ARG:-${PREV_MODE:-public}}"
  [[ "$mode" =~ ^(public|local|vpn)$ ]] || die "ACCESS_MODE must be public, local or vpn (got '${mode}')"
  env_set ACCESS_MODE "$mode"; MODE="$mode"
  if [[ -n "${ACME_EMAIL:-}" ]]; then
    [[ "$ACME_EMAIL" =~ ^[^[:space:]@|]+@[^[:space:]@|]+$ ]] || die "invalid ACME_EMAIL"
    env_set ACME_EMAIL "$ACME_EMAIL"
  fi
  if [[ -n "${DOMAIN:-}" ]]; then
    [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$DOMAIN" == *.* ]] || die "invalid DOMAIN: ${DOMAIN}"
    env_set DOMAIN_CUSTOM "${DOMAIN,,}"
  fi
  custom=$(env_get DOMAIN_CUSTOM)

  # public IP: PUBLIC_IP wins, otherwise detect (Hetzner metadata, local route, api.ipify.org); re-checked every run
  ip=""
  if [[ "$mode" == public || "$mode" == vpn || -n "${PUBLIC_IP:-}" ]]; then
    if [[ -n "${PUBLIC_IP:-}" ]]; then
      is_public_ipv4 "$PUBLIC_IP" || die "PUBLIC_IP='${PUBLIC_IP}' is not a public IPv4 address"
      ip="$PUBLIC_IP"
    else
      ip=$(detect_public_ip) || ip=""
    fi
    stored=$(env_get PUBLIC_IP)
    if [[ -z "$ip" ]]; then
      if [[ -n "$stored" ]]; then
        warn "could not detect the public IP now; keeping the one from the last run (${stored})"; ip="$stored"
      elif [[ "$mode" == vpn || -z "$custom" ]]; then
        die "could not detect the public IPv4 (Hetzner metadata, route, api.ipify.org all failed). Run again with PUBLIC_IP=<address>"
      fi
    fi
    if [[ -n "$ip" ]]; then
      if [[ -n "$stored" && "$stored" != "$ip" ]]; then
        warn "public IP changed: ${stored} -> ${ip}. The sslip.io host name, the certificate and every URL / Lampa setting change with it."
      fi
      env_set PUBLIC_IP "$ip"
    fi
  fi

  case "$mode" in
    public)
      host="${custom:-$(dashed_ip "$ip").sslip.io}"
      port=$(env_get HTTPS_PORT) ;;
    vpn)
      host="$(dashed_ip "$(env_get WG_NET).1").sslip.io"
      port=$(env_get HTTPS_PORT) ;;
    local)
      host=lampa.localhost
      port=$(env_get LOCAL_PORT) ;;
  esac
  if [[ "$mode" != local ]]; then
    local sp bad=0
    if ! [[ "$port" =~ ^[1-9][0-9]*$ ]] || (( port < 1024 || port > 65535 )); then bad=1; fi
    for sp in $(ssh_ports) 80 443; do [[ "$port" == "$sp" ]] && bad=1; done
    if (( bad )); then
      port=$(pick_port tcp "$(env_get QBT_PORT)")
      env_set HTTPS_PORT "$port"
      log "random HTTPS port: ${port} (kept for later runs; change HTTPS_PORT in .env to move it)"
    fi
  fi
  if [[ "$mode" == vpn ]]; then
    local wp; wp=$(env_get WG_PORT)
    if ! [[ "$wp" =~ ^[1-9][0-9]*$ ]] || (( wp < 1024 || wp > 65535 )); then
      env_set WG_PORT "$(pick_port udp "$port" "$(env_get QBT_PORT)")"
      log "random WireGuard UDP port: $(env_get WG_PORT)"
    fi
  fi
  env_set BASE_HOST "$host"; env_set SITE_PORT "$port"

  # qBittorrent peer port: the 6881 default is replaced by a random one as soon as the port is opened to the internet
  local qp; qp=$(env_get QBT_PORT)
  if (( ENABLE_QBT_PORT )); then env_set QBT_PEER_BIND 0.0.0.0; fi
  if [[ "$(env_get QBT_PEER_BIND)" == 0.0.0.0 && "$qp" == 6881 ]]; then
    qp=$(pick_port tcp "$port" "$(env_get WG_PORT)")
    env_set QBT_PORT "$qp"
    log "random qBittorrent peer port: ${qp} (TCP and UDP)"
  fi
  # The peer port is opened in the host firewall: never a system port, never the SSH port.
  (( qp >= 1024 && qp <= 65535 )) || die "QBT_PORT must be 1024-65535 (got ${qp})"
  local sp
  for sp in $(ssh_ports); do [[ "$qp" != "$sp" ]] || die "QBT_PORT ${qp} is the SSH port"; done
  [[ "$qp" != "$port" ]] || die "QBT_PORT and HTTPS_PORT are both ${qp}"

  if [[ "$mode" == public ]]; then
    # Let's Encrypt validates over plain HTTP on port 80; nothing but the certificate check and a redirect to https is served there
    local who; who=$(ss -Hltnp 'sport = :80' 2>/dev/null | head -n1 || true)
    if [[ -n "$who" && "$who" != *docker-proxy* && "$who" != *caddy* ]]; then
      die "port 80 is in use by another program (${who}); the certificate check needs it. Free it, or use --local (no certificate needed)"
    fi
  fi
  return 0
}

# Writes what depends on the mode: the Caddy TLS/HSTS snippet and the published ports of the Caddy container.
render_mode_files() {
  local mode="$MODE" port host email
  port=$(env_get SITE_PORT); host=$(env_get BASE_HOST); email=$(env_get ACME_EMAIL)
  case "$mode" in
    public)
      {
        echo "# generated by install.sh (public mode): Let's Encrypt over HTTP-01 on port 80 (the TLS-ALPN check would need port 443)"
        echo "tls {"
        echo "	issuer acme {"
        echo "		disable_tlsalpn_challenge"
        [[ -n "$email" ]] && echo "		email ${email}"
        echo "	}"
        echo "}"
        echo 'header Strict-Transport-Security "max-age=31536000; includeSubDomains"'
      } > "$DIR/caddy/mode.caddy"
      printf 'services:\n  caddy:\n    ports:\n      - "0.0.0.0:%s:%s"\n      - "0.0.0.0:80:80"\n' "$port" "$port" > "$DIR/compose.ports.yml" ;;
    vpn)
      { echo "# generated by install.sh (vpn mode): Caddy's own CA (a private address cannot get a public certificate)"; echo "tls internal"; } > "$DIR/caddy/mode.caddy"
      printf 'services:\n  caddy:\n    ports:\n      - "%s.1:%s:%s"\n      - "127.0.0.1:%s:%s"\n' "$(env_get WG_NET)" "$port" "$port" "$port" "$port" > "$DIR/compose.ports.yml" ;;
    local)
      { echo "# generated by install.sh (local mode): Caddy's own CA"; echo "tls internal"; } > "$DIR/caddy/mode.caddy"
      printf 'services:\n  caddy:\n    ports:\n      - "127.0.0.1:%s:%s"\n' "$port" "$port" > "$DIR/compose.ports.yml" ;;
  esac
  chmod 0644 "$DIR/caddy/mode.caddy" "$DIR/compose.ports.yml"
  log "mode ${mode}: https://${host}:${port}"
}

gen_secret() { # file bytes ; creates only when missing
  local f="$DIR/secrets/$1"
  if [[ ! -s "$f" ]]; then
    ( umask 077; rand_hex "$2" > "$f" )
    log "generated secrets/$1"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------- users, devices and keys
# secrets/users.tsv (0600), one line per person or device, tab separated:
#   name  kind(user|device)  lampac key (32 hex)  torrserver token (32 hex)  argon2id hash (users) or "-" (devices)
# The key is what Lampa sends (Lampac accsdb); the token is the first path segment of the TorrServer address.
users_file() { printf '%s' "$DIR/secrets/users.tsv"; }
valid_name() { [[ "$1" =~ ^[a-z][a-z0-9_-]{1,31}$ ]]; }
user_has() { [[ -s "$(users_file)" ]] && cut -f1 "$(users_file)" | grep -qx "$1"; }
user_field() { # name column(1-5)
  awk -F'\t' -v n="$1" -v c="$2" '$1 == n {print $c; exit}' "$(users_file)"
}

users_migrate() { # first version: name, token, hash  ->  name, user, token, new TorrServer token, hash
  local f; f="$(users_file)"
  [[ -s "$f" ]] || return 0
  awk -F'\t' 'NF == 3 {exit 0} {exit 1}' "$f" || return 0
  local tmp="${f}.new" name key hash
  : > "$tmp"; chmod 0600 "$tmp"
  while IFS=$'\t' read -r name key hash; do
    [[ -n "$name" ]] || continue
    printf '%s\tuser\t%s\t%s\t%s\n' "$name" "$key" "$(rand_hex 16)" "$hash" >> "$tmp"
  done < "$f"
  mv -f "$tmp" "$f"
  log "users.tsv: migrated to the per-device token format"
}

argon2_pair() { # prints "<password> <hash>" for a fresh random password (password never in argv)
  local out pw hash
  out=$(docker run --rm --network none "$(env_get AUTHELIA_IMAGE)" authelia crypto hash generate argon2 --memory 32768 \
    --random --random.length 24 --random.charset alphanumeric 2>/dev/null) || die "could not generate argon2id hash (is the Authelia image pulled?)"
  pw=$(sed -n 's/^Random Password: //p' <<<"$out")
  hash=$(sed -n 's/^Digest: //p' <<<"$out")
  [[ -n "$pw" && "$hash" == '$argon2id$'* ]] || die "unexpected authelia hash output"
  printf '%s %s' "$pw" "$hash"
}

add_record() { # kind name ; appends to users.tsv, prints the login password (users) once
  local kind="$1" name="$2" pw="" hash="-" pair
  valid_name "$name" || die "name must be 2-32 chars of a-z 0-9 _ - (starting with a letter)"
  touch "$(users_file)"; chmod 0600 "$(users_file)"
  if user_has "$name"; then die "${name} already exists"; fi
  if [[ "$kind" == user ]]; then
    pair=$(argon2_pair); pw="${pair%% *}"; hash="${pair#* }"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$kind" "$(rand_hex 16)" "$(rand_hex 16)" "$hash" >> "$(users_file)"
  if [[ "$kind" == user ]]; then NEW_CREDS+=("user ${name}: web login password ${pw}"); fi
  return 0
}

# One block of Caddy `map` rows per way of presenting a key. Written in place (same inode) so the container's
# bind mount follows it, and it is a Docker secret: not in `docker inspect`, not in `docker compose config`.
render_keymaps() {
  local f="$DIR/secrets/keymaps.caddy" tmp name kind key ts hash
  [[ -e "$f" ]] || install -m 0600 /dev/null "$f"
  tmp=$(mktemp "$DIR/secrets/.keymaps.XXXXXX")
  emit() { # placeholder variable ; rows come from stdin
    printf '\tmap %s {%s} {\n' "$1" "$2"
    sed 's/^/\t\t/'
    printf '\t\tdefault 0\n\t}\n'
  }
  {
    echo "# generated by install.sh from secrets/users.tsv; do not edit"
    echo "(keymaps) {"
    for src in "{query.token}:k_token" "{query.account_email}:k_email" "{query.uid}:k_uid" "{query.box_mac}:k_mac" "{http.request.cookie.lampa_key}:k_cookie"; do
      while IFS=$'\t' read -r name kind key ts hash; do if [[ -n "$name" ]]; then printf '%s 1\n' "$key"; fi; done < "$(users_file)" | emit "${src%%:*}" "${src#*:}"
    done
    {
      while IFS=$'\t' read -r name kind key ts hash; do
        [[ -n "$name" ]] || continue
        printf '~^/(on|online|sisi|dorama)/(js|h)/%s(/|$) 1\n~^/on/%s$ 1\n' "$key" "$key"
      done < "$(users_file)"
      # Lampac's own /proxy links are encrypted by Lampac and carry no key (players cannot add one); see README.
      # Only the shape Lampac generates (/proxy/<payload>[.ext], /proxyimg:W:H/<payload>) and no dot segments (the
      # nodotseg snippet in the Caddyfile refuses those before this map is used).
      if [[ "$(env_get LAMPAC_PROXY_ANON)" == 1 ]]; then
        printf '%s\n' '~^/(proxy|proxy-dash|proxyimg(:[0-9]+:[0-9]+)?)(/[A-Za-z0-9_=.,:%+-]+)+$ 1'
      fi
      # SISI's start page plugin is a static script that Lampac lists in /on/js/<key> without a token; Lampa on a TV
      # loads plugins cross-origin, where the key cookie is not sent. It holds no data.
      if sisi_on; then printf '%s\n' '~^/startpage\.js$ 1'; fi
    } | emit '{path}' k_path
    while IFS=$'\t' read -r name kind key ts hash; do if [[ -n "$name" ]]; then printf '~^/t/%s(/|$) 1\n' "$ts"; fi; done < "$(users_file)" | emit '{path}' ts_ok
    echo "}"
    echo "(userkeys) {"
    while IFS=$'\t' read -r name kind key ts hash; do
      if [[ "$kind" == user ]]; then printf '\t%s %s\n' "$name" "$key"; fi
    done < "$(users_file)"
    echo "}"
  } > "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"; chmod 0600 "$f"
}

render_users() {
  local f name kind key ts hash first=1
  f="$(users_file)"
  [[ -f "$f" ]] || return 0
  { echo "# Rendered by install.sh from secrets/users.tsv. Do not edit; use --add-user / --remove-user."
    echo "users:"
    while IFS=$'\t' read -r name kind key ts hash; do
      [[ "$kind" == user ]] || continue
      printf "  %s:\n    disabled: false\n    displayname: '%s'\n    password: '%s'\n    email: '%s@lampa.invalid'\n    groups: []\n" "$name" "$name" "$hash" "$name"
    done < "$f"
  } > "$DIR/authelia/users.yml.new"
  chmod 0600 "$DIR/authelia/users.yml.new"
  # Authelia watches the file; replace atomically.
  mv -f "$DIR/authelia/users.yml.new" "$DIR/authelia/users.yml"
  # Lampac accsdb users (hot-reloaded). Written in place so the single-file bind mount keeps its inode.
  { echo "["
    while IFS=$'\t' read -r name kind key ts hash; do
      [[ -n "$name" ]] || continue
      (( first )) || echo ","
      first=0
      printf '  {"id": "%s", "expires": "2099-12-31T00:00:00", "comment": "%s"}' "$key" "$name"
    done < "$f"
    echo
    echo "]"
  } > "$DIR/lampac/users.json.new"
  cat "$DIR/lampac/users.json.new" > "$DIR/lampac/users.json"; rm -f "$DIR/lampac/users.json.new"
  # The keys are the only credential on the Lampac API: root and the Lampac uid (group) only.
  chown root:1000 "$DIR/lampac/users.json"; chmod 0640 "$DIR/lampac/users.json"
  render_keymaps
}

reload_caddy() {
  [[ -n "$(dc ps -q caddy 2>/dev/null)" ]] || return 0
  if ! dc exec -T caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
    warn "caddy reload failed; restarting caddy"
    dc restart caddy >/dev/null 2>&1 || warn "could not restart caddy"
  fi
}

render_authelia() {
  local domain port before=""
  [[ -f "$DIR/authelia/configuration.yml" ]] && before=$(md5sum < "$DIR/authelia/configuration.yml")
  domain=$(env_get BASE_HOST); port=$(env_get SITE_PORT)
  sed -e "s|@@DOMAIN@@|${domain}|g" \
      -e "s|@@POLICY@@|$(env_get AUTHELIA_POLICY)|g" \
      -e "s|@@AUTH_URL@@|https://auth.${domain}:${port}|g" \
      -e "s|@@MAIN_URL@@|https://${domain}:${port}|g" \
      "$DIR/authelia/configuration.yml.tmpl" > "$DIR/authelia/configuration.yml"
  chmod 0644 "$DIR/authelia/configuration.yml"
  # Authelia reads its configuration once, at start: a new host name / port / policy needs a restart
  [[ "$before" == "$(md5sum < "$DIR/authelia/configuration.yml")" ]] || AUTHELIA_CONF_CHANGED=1
}

# Module switches in init.conf. The names are the folder names Lampac matches against BaseModule.SkipModules
# (module/<name>, or a group folder without a manifest of its own), checked against the Lampac 1.28.4 source.
sisi_on() { [[ "$(env_get LAMPAC_SISI)" == 1 ]]; }
online_on() { [[ "$(env_get LAMPAC_ONLINE)" == 1 ]]; }

render_lampac() {
  local f="$DIR/lampac/init.conf" skip m sisi online
  # Skipped always: embedded TorrServer (we run our own), admin/stat/log pages, DLNA and the modules whose endpoints
  # are open relays or anonymous bind helpers by design (relays to cub.red / TMDB, media proxies, device binding,
  # Telegram login, Kit, WatchTogether, ForkPlayer, MSX), the third-party plugin store is blocked in Caddy.
  # init.conf's SkipModules REPLACES the list in base.conf (arrays are not merged), so base.conf's own entries
  # (Catalog DLNA Tracks Transcoding WebLog CacheMedia ProxyLimiter ForkPlayerXML MsxNative TelegramAuth
  # TelegramAuthBot) are all repeated here. PidTor searches an external indexer (jac.red); we have no use for it.
  skip=(AdminPanel Catalog CacheMedia CorsMedia Corseu CubProxy DLNA ExternalBind ForkPlayerXML JacRed Kit MsxNative PidTor ProxyLimiter Sync TelegramAuth TelegramAuthBot TimeCode TmdbProxy TorrServer Tracks Transcoding WatchTogether WebLog)
  online=false; sisi=false
  if online_on; then online=true; else skip+=(Online OnlineAnime OnlineENG OnlineGEO OnlinePaid OnlineRUS OnlineUKR); fi
  # SISI = the 18+ section (/sisi.js). The Adult group holds its sources and needs SISI to compile. NextHUB is an
  # 18+ hub of its own (/nexthub, adult site definitions) that compiles without SISI, so it goes with it.
  if sisi_on; then sisi=true; else skip+=(SISI Adult NextHUB); fi
  local list="" before=""
  [[ -f "$f" ]] && before=$(md5sum < "$f")
  for m in "${skip[@]}"; do list+="\"${m}\", "; done
  list="${list%, }"
  # LampaWeb.initPlugins decides which scripts lampainit.js tells Lampa to load. The defaults (base.conf) switch on
  # pirate_store (a store of third-party, unpinned plugins), jacred, tmdbProxy, cubProxy, torrserver, timecode, sisi,
  # online: every one that points at a skipped module or an external source is switched off explicitly, and the
  # ones that this stack serves follow LAMPAC_ONLINE / LAMPAC_SISI.
  # accsdb: Lampac checks the key as well (Caddy already did). scheme is "https" because Caddy terminates TLS and
  # Lampac sees plain HTTP from it; it builds every link it hands out (lampainit.js, online.js ...) from this value.
  cat > "$f" <<CONF
{
  "listen": { "ip": "0.0.0.0", "port": 9118, "scheme": "https", "localhost": "127.0.0.1", "version": true },
  "lowMemoryMode": true,
  "BaseModule": {
    "NotCheckLocalIp": true,
    "SkipModules": [${list}]
  },
  "accsdb": {
    "enable": true,
    "authMesage": "Personal access only. Ask the owner for your link.",
    "denyMesage": "Access denied."
  },
  "LampaWeb": {
    "autoupdate": $(env_get LAMPA_AUTOUPDATE), "tree": "$(env_get LAMPA_TREE)",
    "initPlugins": {
      "pirate_store": false, "jacred": false, "dlna": false, "tracks": false, "transcoding": false,
      "tmdbProxy": false, "cubProxy": false, "online": ${online}, "catalog": false, "dorama": false,
      "sisi": ${sisi}, "torrserver": false, "backup": false, "sync": false, "bookmark": false,
      "timecode": false, "watch_together": false
    }
  },
  "chromium": { "enable": true, "executablePath": "/usr/bin/chromium" },
  "openstat": { "enable": false },
  "online": { "name": "Lampac", "version": true }
}
CONF
  chown root:1000 "$f"; chmod 0640 "$f"
  [[ "$before" == "$(md5sum < "$f")" ]] || LAMPAC_CONF_CHANGED=1
  if [[ ! -s "$DIR/lampac/passwd" ]]; then
    ( umask 077; rand_pw > "$DIR/lampac/passwd" )
    log "generated lampac/passwd (root password, only for admin pages that Caddy blocks anyway)"
  fi
  chown 1000:1000 "$DIR/lampac/passwd"; chmod 0400 "$DIR/lampac/passwd"
}

render_torrserver_auth() {
  local f="$DIR/secrets/ts_password" uid user=lampa
  uid=$(env_get STACK_UID)
  if [[ ! -s "$f" ]]; then
    ( umask 077; rand_pw > "$f" )
  fi
  # TorrServer reads accs.db as JSON {"user":"password"} from its config dir.
  ( umask 077; printf '{"%s":"%s"}\n' "$user" "$(cat "$f")" > "$DIR/data/torrserver/config/accs.db" )
  chown "$uid:$uid" "$DIR/data/torrserver/config/accs.db"; chmod 0600 "$DIR/data/torrserver/config/accs.db"
  # base64(user:password): Caddy adds it to every request it lets through to TorrServer (second authentication layer).
  # Mounted as a Docker secret file (no trailing newline), never an environment variable. Nobody else gets this
  # password: the TV uses its per-device token.
  ( umask 077; printf '%s:%s' "$user" "$(cat "$f")" | base64 -w0 > "$DIR/secrets/ts_basic" )
  rm -f "$DIR/secrets/caddy.env"   # older versions kept the credential here, as an environment file
}


# ---------------------------------------------------------------- WireGuard (optional --vpn mode)
WG_IF=wg0
WG_CONF=/etc/wireguard/wg0.conf
WG_DROPIN_DIR=/etc/systemd/system/docker.service.d
WG_DROPIN="$WG_DROPIN_DIR/lampa-stack-wg.conf"
wg_peers_file() { printf '%s' "$DIR/secrets/wg_peers.tsv"; }   # name  ip  public key  preshared key   (0600)
have_systemd() { [[ "$NO_SYSTEMD" != 1 ]] && command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

pkg_install() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" >/dev/null
  elif command -v dnf >/dev/null 2>&1; then dnf install -y -q "$@" >/dev/null
  elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive --quiet install "$@" >/dev/null
  else return 1
  fi
}

wg_require() {
  if ! command -v wg >/dev/null 2>&1 || ! command -v wg-quick >/dev/null 2>&1; then
    log "installing wireguard-tools"
    pkg_install wireguard-tools || die "wireguard-tools missing and could not be installed; install it (EL: EPEL) and rerun"
  fi
  if ! command -v qrencode >/dev/null 2>&1; then
    pkg_install qrencode || warn "qrencode not installed: client configs are printed without a QR code"
  fi
  modprobe wireguard >/dev/null 2>&1 || true
  return 0
}

wg_server_pub() {
  local k="$DIR/secrets/wg_server.key"
  if [[ ! -s "$k" ]]; then ( umask 077; wg genkey > "$k" ); log "generated secrets/wg_server.key"; fi
  wg pubkey < "$k"
}

wg_next_ip() {
  local net n used; net=$(env_get WG_NET)
  used=$( [[ -f "$(wg_peers_file)" ]] && cut -f2 "$(wg_peers_file)" || true )
  for n in $(seq 2 254); do
    grep -qx "${net}.${n}" <<<"$used" || { printf '%s.%s' "$net" "$n"; return 0; }
  done
  die "no free address left in ${net}.0/24"
}

wg_render() { # /etc/wireguard/wg0.conf from the key and secrets/wg_peers.tsv
  local net name ip pub psk
  net=$(env_get WG_NET)
  wg_server_pub >/dev/null
  install -d -m 0700 /etc/wireguard
  (
    umask 077
    {
      echo "# generated by lampa-stack install.sh; peers are managed with --add-device / --remove-device"
      echo "[Interface]"
      echo "Address = ${net}.1/24"
      echo "ListenPort = $(env_get WG_PORT)"
      echo "PrivateKey = $(cat "$DIR/secrets/wg_server.key")"
      if [[ -f "$(wg_peers_file)" ]]; then
        while IFS=$'\t' read -r name ip pub psk; do
          [[ -n "$name" ]] || continue
          printf '\n# %s\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' "$name" "$pub" "$psk" "$ip"
        done < "$(wg_peers_file)"
      fi
    } > "$WG_CONF"
  )
  chmod 0600 "$WG_CONF"
}

wg_apply() { # bring wg0 up, or push the new peer list into the running interface
  if have_systemd; then
    install -d -m 0755 "$WG_DROPIN_DIR"
    # published ports on the wg address need the interface to exist before Docker starts the containers at boot
    printf '[Unit]\nAfter=wg-quick@%s.service\nWants=wg-quick@%s.service\n' "$WG_IF" "$WG_IF" > "$WG_DROPIN"
    systemctl daemon-reload
  fi
  if ip link show "$WG_IF" >/dev/null 2>&1; then
    if [[ "$(wg show "$WG_IF" listen-port 2>/dev/null)" == "$(env_get WG_PORT)" ]]; then
      wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF") || die "wg syncconf failed"
      return 0
    fi
    if have_systemd; then systemctl restart "wg-quick@${WG_IF}"; else wg-quick down "$WG_IF" >/dev/null 2>&1 || true; wg-quick up "$WG_IF" >/dev/null; fi
  elif have_systemd; then
    systemctl enable --now "wg-quick@${WG_IF}" >/dev/null 2>&1 || die "could not start wg-quick@${WG_IF} (journalctl -u wg-quick@${WG_IF}); is the wireguard kernel module available?"
  else
    wg-quick up "$WG_IF" >/dev/null || die "wg-quick up ${WG_IF} failed"
  fi
  ip link show "$WG_IF" >/dev/null 2>&1 || die "${WG_IF} did not come up"
  log "WireGuard ${WG_IF} up on UDP $(env_get WG_PORT), address $(env_get WG_NET).1"
}

wg_teardown() { # leaves secrets/ (server key, peer list) so --vpn restores the same peers
  if have_systemd; then
    systemctl disable --now "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
    rm -f "$WG_DROPIN"; rmdir "$WG_DROPIN_DIR" 2>/dev/null || true
    systemctl daemon-reload || true
  fi
  if ip link show "$WG_IF" >/dev/null 2>&1; then wg-quick down "$WG_IF" >/dev/null 2>&1 || ip link del "$WG_IF" >/dev/null 2>&1 || true; fi
  rm -f "$WG_CONF"
  log "WireGuard ${WG_IF} removed (server key and peer list kept in ${DIR}/secrets)"
}

wg_add_peer() { # name -> appends the peer; stores the client config in WG_CLIENT_CONF (printed once, never saved)
  local name="$1" priv pub psk ip net
  net=$(env_get WG_NET)
  priv=$(wg genkey); pub=$(printf '%s' "$priv" | wg pubkey); psk=$(wg genpsk); ip=$(wg_next_ip)
  touch "$(wg_peers_file)"; chmod 0600 "$(wg_peers_file)"
  printf '%s\t%s\t%s\t%s\n' "$name" "$ip" "$pub" "$psk" >> "$(wg_peers_file)"
  # Split tunnel: only the stack's own address goes through the VPN, the rest of the device's traffic is untouched.
  WG_CLIENT_CONF="[Interface]
PrivateKey = ${priv}
Address = ${ip}/32

[Peer]
PublicKey = $(wg_server_pub)
PresharedKey = ${psk}
Endpoint = $(env_get PUBLIC_IP):$(env_get WG_PORT)
AllowedIPs = ${net}.1/32
PersistentKeepalive = 25"
}

wg_client_block() { # name -> appends the client config (WG_CLIENT_CONF, set by wg_add_peer) to NEW_BLOCKS, shown once
  local qr=""
  if command -v qrencode >/dev/null 2>&1; then qr=$(printf '%s\n' "$WG_CLIENT_CONF" | qrencode -t ansiutf8 2>/dev/null || true); fi
  NEW_BLOCKS+=("WireGuard client config for '${1}' (shown ONCE, save it as ${1}.conf or scan the QR code in the WireGuard app):
${WG_CLIENT_CONF}
${qr}")
}

WG_BACKFILLED=0
wg_backfill_peers() { # --vpn on a stack that has devices from public / local mode: give each one a peer, once
  local name kind rest
  [[ -f "$(users_file)" ]] || return 0
  while IFS=$'\t' read -r name kind rest; do
    [[ "$kind" == device ]] || continue
    if [[ -f "$(wg_peers_file)" ]] && cut -f1 "$(wg_peers_file)" | grep -qx "$name"; then continue; fi
    wg_add_peer "$name"
    wg_client_block "$name"
    WG_BACKFILLED=1
    log "device '${name}' had no WireGuard peer: created one (its client config is printed below, once)"
  done < "$(users_file)"
}

wg_remove_peer() {
  local f; f="$(wg_peers_file)"
  [[ -f "$f" ]] || return 0
  awk -F'\t' -v n="$1" '$1 != n' "$f" > "${f}.new"; chmod 0600 "${f}.new"; mv -f "${f}.new" "$f"
}
qbt_hash() { # password -> prints the @ByteArray(...) value. The password goes in on stdin, never in argv.
  local pw="$1" out
  out=$(printf '%s' "$pw" | python3 -I -c '
import base64, hashlib, os, sys
pw = sys.stdin.buffer.read()
salt = os.urandom(16)
key = hashlib.pbkdf2_hmac("sha512", pw, salt, 100000, 64)
sys.stdout.write("@ByteArray(%s:%s)" % (base64.b64encode(salt).decode(), base64.b64encode(key).decode()))
') || die "PBKDF2 derivation failed"
  [[ "$out" == '@ByteArray('*')' ]] || die "unexpected PBKDF2 output"
  printf '%s' "$out"
}

QBT_TRUSTED_PROXIES="172.16.0.0/12;192.168.0.0/16;10.0.0.0/8"   # Docker's private ranges; the backend network is internal

seed_qbt() { # $1 = "force" to replace the password of an existing config
  local conf="$DIR/data/qbt/config/qBittorrent/qBittorrent.conf" uid hash pwf="$DIR/secrets/qbt_password" new=0
  uid=$(env_get STACK_UID)
  if [[ ! -s "$pwf" ]]; then ( umask 077; rand_pw > "$pwf" ); new=1; fi
  [[ "${1:-}" == force ]] && new=1
  if [[ -f "$conf" && $new -eq 0 ]]; then return 0; fi
  hash=$(qbt_hash "$(cat "$pwf")")
  install -d -m 0750 -o "$uid" -g "$uid" "$(dirname "$conf")"
  if [[ -f "$conf" ]]; then
    # Existing config: replace only the credentials; the container must be stopped (qBittorrent rewrites the file on exit).
    sed -i -e '/^Password_PBKDF2=/d' -e '/^Username=/d' "$conf"
    if grep -q '^\[WebUI\]' "$conf"; then
      sed -i "/^\[WebUI\]/a Username=$(env_get QBT_USER)\nPassword_PBKDF2=\"${hash}\"" "$conf"
    else
      printf '\n[WebUI]\nUsername=%s\nPassword_PBKDF2="%s"\n' "$(env_get QBT_USER)" "$hash" >> "$conf"
    fi
  else
    # qBittorrent 5.x layout: keys live in [WebUI] without the old "WebUI\\" prefix (verified on 5.3.0).
    # Host header validation is off: qBittorrent 5.3.0 does not match a Host header that carries a non-standard
    # port (https://qbt.x:8443) even when listed, and only Caddy can reach it; Caddy answers just the exact
    # qbt.<domain> site name. CSRF and clickjacking protection stay on. Reverse proxy support makes the ban
    # counter (5 failures, 1 hour) work per client address (Caddy's X-Forwarded-For) instead of locking out
    # everyone behind Caddy's single address; only the private ranges of the internal backend network are trusted.
    cat > "$conf" <<CONF
[LegalNotice]
Accepted=true

[WebUI]
Username=$(env_get QBT_USER)
Password_PBKDF2="${hash}"
LocalHostAuth=true
CSRFProtection=true
ClickjackingProtection=true
HostHeaderValidation=false
ReverseProxySupportEnabled=true
TrustedReverseProxiesList=${QBT_TRUSTED_PROXIES}
SessionTimeout=3600
MaxAuthenticationFailCount=5
BanDuration=3600
CONF
  fi
  chown "$uid:$uid" "$conf"; chmod 0600 "$conf"
  # The password is only shown when it was newly created in this run.
  if (( new )); then NEW_CREDS+=("qBittorrent (behind the Authelia login): user $(env_get QBT_USER)  password $(cat "$pwf")"); fi
}


# ---------------------------------------------------------------- stack control
wait_healthy() {
  local st bad
  for _ in $(seq 1 90); do
    bad=0
    for s in authelia caddy lampac torrserver qbittorrent; do
      st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${PROJECT}-${s}-1" 2>/dev/null || echo missing)
      [[ "$st" == healthy ]] || bad=1
    done
    (( bad == 0 )) && { log "all services healthy"; return 0; }
    sleep 4
  done
  for s in authelia caddy lampac torrserver qbittorrent; do
    printf '%s: %s\n' "$s" "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${PROJECT}-${s}-1" 2>/dev/null || echo missing)" >&2
  done
  return 1
}


ts_basic() { printf 'Basic %s' "$(printf 'lampa:%s' "$(cat "$DIR/secrets/ts_password")" | base64 -w0)"; }

# TorrServer settings: POST /settings {"action":"get"} -> change keys -> {"action":"set","sets":{...}}.
# Keys are the Go field names of BTSets (server/settings/btsets.go has no json tags). The request runs as curl
# inside the qBittorrent container (same internal network) with the whole request (credential, body) given as a
# curl config on stdin, so neither the credential nor the body is ever on a command line / in /proc.
ts_post() { # json body -> stdout
  local body="${1//\\/\\\\}"; body="${body//\"/\\\"}"
  { printf 'header = "Authorization: %s"\nheader = "Content-Type: application/json"\n' "$(ts_basic)"
    printf 'data = "%s"\nurl = "http://torrserver:8090/settings"\n' "$body"
  } | dc exec -T qbittorrent curl -sS --fail --max-time 20 -K -
}

# Streaming only. The cache is RAM (UseDisk=false, CacheSize), a torrent is dropped TS_IDLE_SECONDS after its last
# reader goes away and its cache with it (RemoveCacheOnDrop), nothing is uploaded (DisableUpload), and the
# disk path of the cache is pinned to the mounted data/torrserver/cache so the cleanup timer covers it even if
# someone switches UseDisk on in the TorrServer UI (the container root is read-only: there is nowhere else to write).
apply_torrserver() {
  local cur new cache_bytes kv k v
  local -a want opt
  cache_bytes=$(( $(env_get TS_CACHE_MB) * 1024 * 1024 ))
  want=("UseDisk=false" "DisableUpload=true" "RemoveCacheOnDrop=true" "EnableDLNA=false"
        "CacheSize=${cache_bytes}" "PreloadCache=$(env_get TS_PRELOAD_PCT)" "ReaderReadAHead=$(env_get TS_READAHEAD_PCT)"
        "TorrentDisconnectTimeout=$(env_get TS_IDLE_SECONDS)" 'TorrentsSavePath="/opt/ts/cache"')
  opt=("EnableBonjour=false" "EnableRutorSearch=false" "EnableTorznabSearch=false")
  cur=$(ts_post '{"action":"get"}') || { warn "TorrServer settings: API not reachable"; return 1; }
  [[ "$cur" == \{* ]] || { warn "TorrServer settings: unexpected reply"; return 1; }
  new="$cur"
  for kv in "${want[@]}" "${opt[@]}"; do
    k="${kv%%=*}"; v="${kv#*=}"
    if ! grep -qE "\"${k}\":(true|false|-?[0-9]+|\"[^\"]*\")" <<<"$new"; then
      case " ${opt[*]} " in *" ${kv} "*) continue ;; esac
      warn "TorrServer settings: key ${k} not in reply (version changed?)"; return 1
    fi
    new=$(sed -E "s#\"${k}\":(true|false|-?[0-9]+|\"[^\"]*\")#\"${k}\":${v}#" <<<"$new")
  done
  ts_post "{\"action\":\"set\",\"sets\":${new}}" >/dev/null || { warn "TorrServer settings: set failed"; return 1; }
  cur=$(ts_post '{"action":"get"}')
  for kv in "${want[@]}"; do
    k="${kv%%=*}"; v="${kv#*=}"
    grep -q "\"${k}\":${v}" <<<"$cur" || { warn "TorrServer setting ${k} did not stick"; return 1; }
  done
  log "TorrServer: streaming only (RAM cache $(env_get TS_CACHE_MB) MB, preload $(env_get TS_PRELOAD_PCT)%, read-ahead $(env_get TS_READAHEAD_PCT)%, dropped $(env_get TS_IDLE_SECONDS)s after playback stops, no upload)"
}

qbt_exec() { dc exec -T qbittorrent "$@"; }

qbt_login_code() { # user password -> prints the HTTP status of /auth/login (5.3.0: 204 = logged in, 401 = refused)
  printf 'username=%s&password=%s' "$1" "$2" | qbt_exec curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -c /tmp/lampa.cj -d @- "http://127.0.0.1:$(env_get QBT_WEBUI_PORT)/api/v2/auth/login"
}

apply_qbt() {
  local port pw json host sp
  port=$(env_get QBT_WEBUI_PORT); pw=$(cat "$DIR/secrets/qbt_password")
  host=$(env_get BASE_HOST); sp=$(env_get SITE_PORT)
  [[ "$(qbt_login_code "$(env_get QBT_USER)" "$pw")" == 204 ]] || { warn "qBittorrent: login with the generated password failed"; return 1; }
  json=$(printf '{"max_ratio_enabled":true,"max_ratio":%s,"max_seeding_time_enabled":true,"max_seeding_time":%s,"max_ratio_act":0,"listen_port":%s,"upnp":false,"save_path":"/downloads","web_ui_clickjacking_protection_enabled":true,"web_ui_csrf_protection_enabled":true,"web_ui_host_header_validation_enabled":false,"web_ui_reverse_proxy_enabled":true,"web_ui_reverse_proxies_list":"%s","web_ui_domain_list":"%s"}' \
    "$(env_get QBT_MAX_RATIO)" "$(env_get QBT_MAX_SEED_MINUTES)" "$(env_get QBT_PORT)" "$QBT_TRUSTED_PROXIES" "qbt.${host};qbt.${host}:${sp};localhost;127.0.0.1")
  printf 'json=%s' "$json" | qbt_exec curl -sS --max-time 10 -b /tmp/lampa.cj --data @- "http://127.0.0.1:${port}/api/v2/app/setPreferences" >/dev/null \
    || { warn "qBittorrent: setPreferences failed"; return 1; }
  # the temporary/default passwords must not work
  for bad in adminadmin admin; do
    if [[ "$(qbt_login_code "$(env_get QBT_USER)" "$bad")" == 204 ]]; then warn "qBittorrent accepts the default password '${bad}'"; return 1; fi
  done
  log "qBittorrent: generated password only; seeding stops at ratio $(env_get QBT_MAX_RATIO) or $(env_get QBT_MAX_SEED_MINUTES) min (paused, not deleted)"
}

# ---------------------------------------------------------------- firewall (additive, never SSH)
FW_RECORD() { printf '%s' "$DIR/secrets/firewall-opened"; }
fw_open() { # proto/port ...
  (( NO_FIREWALL )) && { warn "firewall untouched (--no-firewall); open $* yourself"; return 0; }
  local p
  # (output captured first: `ufw status | grep -q` can die of SIGPIPE under pipefail and read as "inactive")
  local ufw_st=""
  if command -v ufw >/dev/null 2>&1; then ufw_st=$(ufw status 2>/dev/null || true); fi
  if [[ "$ufw_st" == *"Status: active"* ]]; then
    # Record only the rules this script adds: --uninstall must not remove a rule the operator already had.
    for p in "$@"; do
      if grep -Eq "^${p}[[:space:]]+ALLOW" <<<"$(ufw status 2>/dev/null || true)"; then
        log "ufw: ${p} already allowed (left as is)"
      else
        ufw allow "$p" >/dev/null && echo "ufw $p" >> "$(FW_RECORD)"
      fi
    done
    log "ufw: ports ready: $*"
  elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    # lockout guard: SSH must already be allowed in the saved rules of the default zone
    local zone; zone=$(firewall-cmd --get-default-zone)
    if ! { firewall-cmd --permanent --zone="$zone" --query-service=ssh >/dev/null 2>&1 || firewall-cmd --permanent --zone="$zone" --query-port=22/tcp >/dev/null 2>&1; }; then
      warn "firewalld: ssh not in zone ${zone}; leaving the firewall alone. Open $* yourself."; return 0
    fi
    for p in "$@"; do
      if firewall-cmd --permanent --zone="$zone" --query-port="$p" >/dev/null 2>&1; then
        log "firewalld: ${p} already open in ${zone} (left as is)"
      else
        firewall-cmd --permanent --zone="$zone" --add-port="$p" >/dev/null && echo "firewalld $zone $p" >> "$(FW_RECORD)"
      fi
    done
    firewall-cmd --reload >/dev/null
    firewall-cmd --zone="$zone" --query-service=ssh >/dev/null 2>&1 || firewall-cmd --zone="$zone" --query-port=22/tcp >/dev/null 2>&1 || warn "ssh not visible in zone ${zone} after reload; check the firewall!"
    log "firewalld (${zone}): opened $*"
  else
    log "no active ufw/firewalld: nothing to open on the host. A cloud firewall (Hetzner) must allow $* too."
  fi
}
fw_close_recorded() {
  local f; f="$(FW_RECORD)"; [[ -f "$f" ]] || return 0
  local kind a b
  while read -r kind a b; do
    case "$kind" in
      ufw) ufw delete allow "$a" >/dev/null 2>&1 || true ;;
      firewalld) firewall-cmd --permanent --zone="$a" --remove-port="$b" >/dev/null 2>&1 || true ;;
    esac
  done < "$f"
  command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld && firewall-cmd --reload >/dev/null 2>&1 || true
  rm -f "$f"
}

install_timer() {
  if [[ "$NO_SYSTEMD" == 1 ]] || ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
    warn "systemd not available: cleanup timer not installed (run ${DIR}/scripts/cleanup.sh from cron)"; return 0
  fi
  sed "s|/opt/lampa-stack|${DIR}|g" "$DIR/systemd/lampa-stack-cleanup.service" > "$UNIT_DIR/lampa-stack-cleanup.service"
  install -m 0644 "$DIR/systemd/lampa-stack-cleanup.timer" "$UNIT_DIR/lampa-stack-cleanup.timer"
  systemctl daemon-reload
  systemctl enable --now lampa-stack-cleanup.timer >/dev/null
  log "cleanup timer enabled (every 3 days; dry run: ${DIR}/scripts/cleanup.sh --dry-run)"
}


# ---------------------------------------------------------------- firewall reconcile
# Every run: close what an earlier run opened, then open what the current mode needs. A rule the operator
# already had is never recorded and so never removed.
fw_reconcile() {
  fw_close_recorded
  local ports=()
  case "$MODE" in
    public) ports+=("$(env_get SITE_PORT)/tcp" 80/tcp) ;;
    vpn) ports+=("$(env_get WG_PORT)/udp") ;;
  esac
  if [[ "$(env_get QBT_PEER_BIND)" == 0.0.0.0 ]]; then ports+=("$(env_get QBT_PORT)/tcp" "$(env_get QBT_PORT)/udp"); fi
  if (( ${#ports[@]} )); then fw_open "${ports[@]}"; else log "firewall: nothing needs to be open in ${MODE} mode"; fi
}

# ---------------------------------------------------------------- checks after start
check_dns() { # public mode: every host name must resolve to this server
  local ip h got; ip=$(env_get PUBLIC_IP)
  [[ -n "$ip" ]] || return 0
  for h in "$(env_get BASE_HOST)" "auth.$(env_get BASE_HOST)" "ts.$(env_get BASE_HOST)" "qbt.$(env_get BASE_HOST)"; do
    got=$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1; exit}' || true)
    if [[ "$got" == "$ip" ]]; then log "DNS ok: ${h} -> ${ip}"
    else warn "DNS: ${h} resolves to '${got:-nothing}', expected ${ip}"; fi
  done
}

check_tls() { # public mode: wait for a certificate that this host trusts (no -k)
  local h p; h="auth.$(env_get BASE_HOST)"; p=$(env_get SITE_PORT)
  for _ in $(seq 1 18); do
    if curl -sS -o /dev/null --max-time 5 --resolve "${h}:${p}:127.0.0.1" "https://${h}:${p}/" 2>/dev/null; then
      log "HTTPS ok: a trusted certificate is served for ${h}:${p}"; return 0
    fi
    sleep 5
  done
  warn "no trusted certificate for ${h} after 90 s. Check: DNS of the host names, TCP 80 reachable from the internet (cloud firewall), Let's Encrypt rate limits (see README), docker logs ${PROJECT}-caddy-1"
  return 1
}

# ---------------------------------------------------------------- summary
urls() {
  local d p; d=$(env_get BASE_HOST); p=$(env_get SITE_PORT)
  MAIN_URL="https://${d}:${p}"; TS_URL="https://ts.${d}:${p}"; QBT_URL="https://qbt.${d}:${p}"; AUTH_URL="https://auth.${d}:${p}"
}

show_access() { # name: what to type into Lampa
  urls
  local name="$1" kind key ts
  kind=$(user_field "$name" 2); key=$(user_field "$name" 3); ts=$(user_field "$name" 4)
  echo "  ${kind} '${name}'"
  echo "    Open Lampa (once; Caddy then remembers the key in a cookie): ${MAIN_URL}/?token=${key}"
  if online_on || sisi_on; then
    echo "    Lampa > Settings > Extensions > add plugin: ${MAIN_URL}/on/js/${key}   (all enabled sections in one)"
    online_on && echo "      or separately: ${MAIN_URL}/online/js/${key}   (this is /online.js with your key)"
    sisi_on && echo "      or separately: ${MAIN_URL}/sisi/js/${key}   (18+, this is /sisi.js with your key)"
  fi
  echo "    Lampa > Settings > TorrServer > URL: ${TS_URL}/t/${ts}   (leave the login / password switch OFF)"
}

print_summary() {
  urls
  echo
  echo "================ Lampa stack ================"
  echo "Mode: ${MODE}   Port: $(env_get SITE_PORT)   Modules: Online $(online_on && echo on || echo off), SISI 18+ $(sisi_on && echo on || echo off)"
  case "$MODE" in
    public)
      echo "Lampa / Lampac : ${MAIN_URL}   (needs a device key)"
      echo "Login (Authelia): ${AUTH_URL}"
      echo "TorrServer UI  : ${TS_URL}   qBittorrent UI: ${QBT_URL}   (after the login)"
      echo "Open in the CLOUD firewall (Hetzner): TCP $(env_get SITE_PORT) and TCP 80 (Let's Encrypt checks the certificate there; nothing is served on 80 but a redirect)." ;;
    vpn)
      echo "Reachable only through WireGuard (UDP $(env_get WG_PORT), address $(env_get WG_NET).1) and on this server's localhost."
      echo "Lampa / Lampac : ${MAIN_URL}   Login: ${AUTH_URL}   TorrServer UI: ${TS_URL}   qBittorrent UI: ${QBT_URL}"
      echo "The certificate is signed by Caddy's own CA: ${0##*/} --export-ca, trust it on each device. Open UDP $(env_get WG_PORT) in the cloud firewall." ;;
    local)
      echo "Nothing public. On your laptop:  ssh -N -L $(env_get SITE_PORT):127.0.0.1:$(env_get SITE_PORT) <you>@<this-server>"
      echo "then open ${MAIN_URL}  (TorrServer ${TS_URL}, qBittorrent ${QBT_URL}, login ${AUTH_URL}). A TV cannot use a tunnel: use the default public mode." ;;
  esac
  if (( ${#NEW_CREDS[@]} )); then
    echo
    echo "Credentials (shown ONCE; passwords are stored only as hashes, keys in ${DIR}/secrets, root 0600):"
    local c; for c in "${NEW_CREDS[@]}"; do echo "  $c"; done
    NEW_CREDS=()
  fi
  if (( ${#NEW_ACCESS[@]} )); then
    echo
    echo "Access for the Lampa app (print again any time: $0 --show NAME):"
    local n; for n in "${NEW_ACCESS[@]}"; do show_access "$n"; done
    NEW_ACCESS=()
  fi
  if (( ${#NEW_BLOCKS[@]} )); then
    local b; for b in "${NEW_BLOCKS[@]}"; do echo; printf '%s\n' "$b"; done
    NEW_BLOCKS=()
  fi
  echo
  echo "Status: $0 --status      Docs: ${DIR}/README.md"
  echo "============================================="
}
NEW_ACCESS=()
NEW_BLOCKS=()   # multi-line secrets printed once (WireGuard client config + QR)

# ---------------------------------------------------------------- actions
do_install() {
  check_os; check_docker; selinux_note
  install_files
  ensure_env
  install_files   # again: STACK_UID may have been read from a pre-existing .env
  resolve_mode
  render_mode_files
  gen_secret authelia_jwt 32 || true
  gen_secret authelia_session 32 || true
  gen_secret authelia_storage 32 || true
  users_migrate
  if [[ ! -s "$(users_file)" ]]; then add_record user "$ADMIN_USER"; NEW_ACCESS+=("$ADMIN_USER"); fi
  render_users; render_authelia; render_lampac
  render_torrserver_auth
  seed_qbt
  if [[ "$MODE" == vpn ]]; then wg_require; wg_render; fi
  dc config -q || die "docker compose config failed"
  if (( NO_START )); then log "--no-start: files written, containers not started"; print_summary; return 0; fi
  if [[ "${LAMPA_STACK_SKIP_PULL:-0}" != 1 ]]; then
    log "pulling images (pinned tags + digests)"
    dc pull --quiet || die "image pull failed"
  fi
  if [[ "$MODE" == vpn ]]; then wg_apply; fi
  local lampac_was_up=0 authelia_was_up=0
  [[ -n "$(dc ps -q lampac 2>/dev/null)" ]] && lampac_was_up=1
  [[ -n "$(dc ps -q authelia 2>/dev/null)" ]] && authelia_was_up=1
  dc up -d --remove-orphans
  if (( authelia_was_up && AUTHELIA_CONF_CHANGED )); then log "Authelia configuration changed: restarting Authelia"; dc restart authelia >/dev/null; fi
  # module switches (LAMPAC_ONLINE / LAMPAC_SISI) only take effect when Lampac starts
  if (( lampac_was_up && LAMPAC_CONF_CHANGED )); then log "init.conf changed: restarting Lampac (it recompiles its modules, this takes a minute or two)"; dc restart lampac >/dev/null; fi
  wait_healthy || die "services did not become healthy; see: docker compose -p ${PROJECT} logs"
  reload_caddy
  apply_torrserver || warn "TorrServer settings not applied; rerun $0 once the container is up"
  apply_qbt || warn "qBittorrent settings not applied"
  # Peers for devices that predate --vpn are made last, once the stack is up, so a failed run cannot lose the one-time
  # client configs it would have printed.
  if [[ "$MODE" == vpn ]]; then
    wg_backfill_peers
    if (( WG_BACKFILLED )); then wg_render; wg_apply; fi
  fi
  # leaving vpn mode: Caddy no longer publishes on the wg address (recreated above), so the interface can go
  if [[ "$MODE" != vpn && "$PREV_MODE" == vpn ]]; then wg_teardown; fi
  fw_reconcile
  install_timer
  if [[ "$MODE" == public ]]; then
    check_dns || true
    [[ "${LAMPA_STACK_SKIP_TLS_CHECK:-0}" == 1 ]] || check_tls || true
  fi
  print_summary
}

require_installed() { check_docker; [[ -f "$DIR/.env" ]] || die "not installed; run $0 first"; MODE=$(env_get ACCESS_MODE); MODE="${MODE:-public}"; }

do_add() { # kind
  local kind="$1"
  require_installed
  users_migrate
  if [[ "$kind" == device && "$MODE" == vpn ]]; then wg_require; fi
  add_record "$kind" "$TARGET_NAME"
  NEW_ACCESS+=("$TARGET_NAME")
  if [[ "$kind" == device && "$MODE" == vpn ]]; then
    wg_add_peer "$TARGET_NAME"
    wg_render; wg_apply
    wg_client_block "$TARGET_NAME"
  elif [[ "$kind" == device ]]; then
    log "mode ${MODE}: '${TARGET_NAME}' gets a key and a TorrServer token (no WireGuard peer outside --vpn)"
  fi
  render_users; reload_caddy
  print_summary
}

do_remove() { # name (user or device)
  require_installed
  user_has "$TARGET_NAME" || die "no such user or device: ${TARGET_NAME}"
  local kind; kind=$(user_field "$TARGET_NAME" 2)
  if [[ "$kind" == user && $(awk -F'\t' '$2 == "user"' "$(users_file)" | wc -l) -le 1 ]]; then
    die "refusing to remove the last user (nobody could log in to the web UIs)"
  fi
  awk -F'\t' -v n="$TARGET_NAME" '$1 != n' "$(users_file)" > "$(users_file).new"
  chmod 0600 "$(users_file).new"; mv -f "$(users_file).new" "$(users_file)"
  render_users
  reload_caddy    # the key and the TorrServer token stop working at once
  # The peer goes in every mode: the peer list outlives a switch away from --vpn, and a later --vpn would write a
  # revoked device back into wg0.conf. Only touch the live interface when it is the active mode.
  if [[ -f "$(wg_peers_file)" ]] && cut -f1 "$(wg_peers_file)" | grep -qx "$TARGET_NAME"; then
    wg_remove_peer "$TARGET_NAME"
    if [[ "$MODE" == vpn ]]; then wg_render; wg_apply; fi
  fi
  # Lampac only ever adds users from users.json while running; it forgets a removed one on restart.
  # (a removed person's browser sessions end with the Authelia restart; a device has none)
  if [[ "$kind" == user ]]; then
    dc restart authelia lampac >/dev/null 2>&1 || warn "could not restart authelia/lampac: Lampac still accepts the removed key until it restarts"
  else
    dc restart lampac >/dev/null 2>&1 || warn "could not restart lampac: it still accepts the removed key until it restarts (Caddy already refuses it)"
  fi
  log "removed ${TARGET_NAME}: its key and TorrServer token (and login / VPN peer, if it had them) no longer work (Caddy reloaded, Lampac restarted)"
}

do_show() {
  require_installed
  user_has "$TARGET_NAME" || die "no such user or device: ${TARGET_NAME}"
  urls
  echo "Access for the Lampa app:"; show_access "$TARGET_NAME"
}

do_rotate() {
  require_installed
  local f name kind key ts hash pair pw tmp
  ( umask 077; rand_hex 32 > "$DIR/secrets/authelia_session"; rand_hex 32 > "$DIR/secrets/authelia_jwt"
    rand_pw > "$DIR/secrets/ts_password"; rand_pw > "$DIR/secrets/qbt_password" )
  NEW_CREDS+=("TorrServer UI and qBittorrent passwords are replaced (the TorrServer one is only used by Caddy; qBittorrent: $(env_get QBT_USER)  password $(cat "$DIR/secrets/qbt_password"))")
  rm -f "$DIR/lampac/passwd"; ( umask 077; rand_pw > "$DIR/lampac/passwd" ); chown 1000:1000 "$DIR/lampac/passwd"; chmod 0400 "$DIR/lampac/passwd"
  f="$(users_file)"; tmp="${f}.new"; : > "$tmp"; chmod 0600 "$tmp"
  while IFS=$'\t' read -r name kind key ts hash; do
    [[ -n "$name" ]] || continue
    key=$(rand_hex 16); ts=$(rand_hex 16)
    if [[ "$kind" == user ]]; then
      pair=$(argon2_pair); pw="${pair%% *}"; hash="${pair#* }"
      NEW_CREDS+=("user ${name}: web login password ${pw}")
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$kind" "$key" "$ts" "$hash" >> "$tmp"
    NEW_ACCESS+=("$name")
  done < "$f"
  mv -f "$tmp" "$f"
  render_users
  render_torrserver_auth
  dc stop qbittorrent >/dev/null
  seed_qbt force
  dc up -d --force-recreate authelia caddy lampac torrserver qbittorrent >/dev/null
  wait_healthy || die "services did not become healthy after rotation"
  apply_torrserver || warn "TorrServer settings not re-applied"
  apply_qbt || warn "qBittorrent settings not re-applied"
  print_summary
}

do_export_ca() {
  require_installed
  dc cp caddy:/data/caddy/pki/authorities/local/root.crt "$DIR/caddy-local-root.crt" || die "no local CA yet (public mode uses Let's Encrypt, or Caddy has not issued a certificate)"
  log "wrote ${DIR}/caddy-local-root.crt; copy it to the device and trust it for https://*.$(env_get BASE_HOST)"
}

do_status() {
  require_installed
  urls
  echo "Mode           : ${MODE}"
  echo "Public IP      : $(env_get PUBLIC_IP)$( [[ -n "$(env_get DOMAIN_CUSTOM)" ]] && echo "   (custom domain $(env_get DOMAIN_CUSTOM))" )"
  echo "HTTPS port     : $(env_get SITE_PORT)$( [[ "$MODE" == vpn ]] && echo "   WireGuard UDP $(env_get WG_PORT), address $(env_get WG_NET).1" )"
  echo "URLs           : ${MAIN_URL}   ${AUTH_URL}   ${TS_URL}   ${QBT_URL}"
  echo "Modules        : Online $(online_on && echo ENABLED || echo disabled)   SISI 18+ $(sisi_on && echo ENABLED || echo disabled)   (signed /proxy links open: $( [[ "$(env_get LAMPAC_PROXY_ANON)" == 1 ]] && echo yes || echo no ))"
  echo "Users/devices  :"
  if [[ -s "$(users_file)" ]]; then awk -F'\t' '{printf "  %-20s %s\n", $1, $2}' "$(users_file)"; else echo "  none"; fi
  if [[ "$MODE" == vpn ]] && command -v wg >/dev/null 2>&1; then
    echo "WireGuard peers (latest handshake):"
    wg show "$WG_IF" latest-handshakes 2>/dev/null | while read -r pub t; do
      name=$(awk -F'\t' -v k="$pub" '$3 == k {print $1}' "$(wg_peers_file)" 2>/dev/null || true)
      printf '  %-20s %s\n' "${name:-$pub}" "$([[ "$t" == 0 ]] && echo never || date -d "@$t" '+%F %T')"
    done
  fi
  echo
  dc ps
  echo
  echo "Published host ports (expected: only Caddy; qBittorrent peer port on 127.0.0.1 unless enabled):"
  docker ps --filter "label=com.docker.compose.project=${PROJECT}" --format '  {{.Names}}  {{.Ports}}'
  echo
  [[ -f "$DIR/secrets/ts_password" ]] && { apply_torrserver_check || true; }
  [[ -f "$DIR/secrets/qbt_password" ]] && { qbt_check || true; }
  systemctl list-timers lampa-stack-cleanup.timer --no-pager 2>/dev/null | head -3 || true
}
apply_torrserver_check() {
  local cur k; cur=$(ts_post '{"action":"get"}' 2>/dev/null) || { echo "TorrServer: API not reachable"; return 1; }
  for k in DisableUpload RemoveCacheOnDrop; do grep -q "\"${k}\":true" <<<"$cur" && echo "TorrServer ${k}: true" || echo "TorrServer ${k}: NOT set"; done
  grep -q '"UseDisk":false' <<<"$cur" && echo "TorrServer UseDisk: false (RAM cache)" || echo "TorrServer UseDisk: NOT false"
}
qbt_check() {
  [[ "$(qbt_login_code "$(env_get QBT_USER)" "$(cat "$DIR/secrets/qbt_password")" 2>/dev/null)" == 204 ]] && echo "qBittorrent: generated password works" || echo "qBittorrent: login FAILED"
  [[ "$(qbt_login_code "$(env_get QBT_USER)" adminadmin 2>/dev/null)" == 204 ]] && echo "qBittorrent: DEFAULT PASSWORD ACCEPTED" || echo "qBittorrent: default password rejected"
}

do_uninstall() {
  check_docker
  if [[ -f "$DIR/docker-compose.yml" && -f "$DIR/.env" ]]; then
    [[ -f "$DIR/compose.ports.yml" ]] || printf 'services: {}\n' > "$DIR/compose.ports.yml"
    if (( PURGE )); then dc down -v --remove-orphans || true; else dc down --remove-orphans || true; fi
  fi
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl disable --now lampa-stack-cleanup.timer >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/lampa-stack-cleanup.service" "$UNIT_DIR/lampa-stack-cleanup.timer"
    systemctl daemon-reload || true
  fi
  if [[ -f "$DIR/secrets/wg_server.key" || -f "$WG_CONF" ]]; then wg_teardown; fi
  fw_close_recorded
  if (( PURGE )); then
    [[ "$DIR" != / && "$DIR" == /* && -d "$DIR" ]] || die "refusing to delete '${DIR}'"
    rm -rf --one-file-system "$DIR"
    log "purged ${DIR}"
  else
    log "stack stopped. Data and secrets kept in ${DIR}; use --uninstall --purge to delete them"
  fi
}

main() {
  parse_args "$@"
  trap print_pending EXIT
  [[ $EUID -eq 0 ]] || die "run as root (sudo $0 ...)"
  MODE=""; PREV_MODE=""
  case "$ACTION" in
    install) do_install ;;
    add-user) do_add user ;;
    add-device) do_add device ;;
    remove-user|remove-device) do_remove ;;
    show) do_show ;;
    rotate) do_rotate ;;
    status) do_status ;;
    export-ca) do_export_ca ;;
    uninstall) do_uninstall ;;
  esac
}

# sourced (tests) or executed
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
