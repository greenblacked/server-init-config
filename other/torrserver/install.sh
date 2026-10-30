#!/usr/bin/env bash
# Install TorrServer in Docker for streaming (not downloading), hardened. Idempotent: rerun to apply changes.
# Needs Docker Engine with the compose plugin already installed. Run as root.
#
# Modes (one at a time; switching cleans up what the previous mode opened):
#   public (default)  HTTPS with a login on a random high TCP port, certificate from Let's Encrypt via Caddy
#                     for <ip>.sslip.io (or your DOMAIN). Port 80 is opened for the ACME challenge only.
#   --local           127.0.0.1 only (SSH tunnel), no Caddy, no firewall change.
#   --vpn             optional: WireGuard on a random UDP port; TorrServer answers only on the VPN address.
#
# Sources (checked at tag MatriX.147.2, commit 8a69ead):
#   https://github.com/YouROK/TorrServer           Dockerfile, docker-entrypoint.sh (env vars, paths)
#   server/web/auth/auth.go                         accs.db: JSON object {"user":"password"} in the config dir
#   server/settings/btsets.go, web/api/settings.go  settings keys, POST /settings {"action":"get|set|def"}
#   server/torr/btserver.go                         DisableUpload -> anacrolix NoUpload
set -Eeuo pipefail

TS_VERSION="${TS_VERSION:-MatriX.147.2}"
# Index digest of ghcr.io/yourok/torrserver:MatriX.147.2 (linux/amd64, arm64, arm/v7), resolved from the registry.
# Set TS_IMAGE_DIGEST="" to pin by tag only.
TS_IMAGE_DIGEST="${TS_IMAGE_DIGEST-sha256:056e0cf1003c4e6c2c2343797f84734fe4dc48f57d1ed18af6d5ef982fce0f40}"
TS_IMAGE_REPO="${TS_IMAGE_REPO:-ghcr.io/yourok/torrserver}"
CADDY_IMAGE="${CADDY_IMAGE:-caddy:2.10.0@sha256:133b5eb7ef9d42e34756ba206b06d84f4e3eb308044e268e182c2747083f09de}"
TS_DIR="${TS_DIR:-/opt/torrserver}"
TS_HOST_PORT="${TS_HOST_PORT:-8090}"        # localhost API port (and the port on the VPN address)
TS_UID="${TS_UID:-10001}"
TS_GID="${TS_GID:-10001}"
TS_MEM_LIMIT="${TS_MEM_LIMIT:-3g}"
TS_MEM_RESERVATION="${TS_MEM_RESERVATION:-512m}"
TS_CPUS="${TS_CPUS:-2.0}"
TS_CACHE_MB="${TS_CACHE_MB:-384}"           # RAM stream cache (CacheSize); never more than half of TS_MEM_LIMIT
TS_IDLE_SECONDS="${TS_IDLE_SECONDS:-120}"   # TorrentDisconnectTimeout: idle seconds before a torrent is closed
TS_HTTP_PORT="${TS_HTTP_PORT:-80}"          # host port for the ACME challenge + redirect (80 for real use, other only for tests)
TS_WG_IF="${TS_WG_IF:-wg0}"
SYSTEMD_DIR="${TS_SYSTEMD_DIR:-/etc/systemd/system}"
WG_DIR="${TS_WG_DIR:-/etc/wireguard}"
F2B_DIR="${TS_F2B_DIR:-/etc/fail2ban}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ACTION=install      # install | uninstall | status | add-device | remove-device
MODE_REQ=""         # "" = keep what .env says (fresh install: public) | public | local | vpn
DEVICE=""
PURGE=0
ROTATE=0
NO_START=0
DOMAIN_ARG=""       # "" = not given, "-" = clear, else a host name
ACME_EMAIL="${ACME_EMAIL:-}"
DOMAIN_ENV="${DOMAIN:-}"
PUBLIC_IP_ENV="${PUBLIC_IP:-}"

log() { echo "[$(date +%H:%M:%S)] $*"; }
note() { echo "[$(date +%H:%M:%S)] $*" >&2; }
warn() { echo "WARN: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: sudo ./install.sh [mode] [options]

Installs TorrServer ${TS_VERSION} in Docker under ${TS_DIR} to STREAM torrents (RAM cache, nothing kept on disk).
A login is always required (random password in ${TS_DIR}/credentials, mode 0600, root only).

Modes (rerun without a mode keeps the current one):
  (default)  public   HTTPS + login on a RANDOM high TCP port, e.g. https://1-2-3-4.sslip.io:43817
                      (free sslip.io name made from the server IP, or your own --domain). Caddy gets the
                      certificate from Let's Encrypt; TCP 80 is opened for that challenge only.
  --local             127.0.0.1 only, reach it with an SSH tunnel. No Caddy, closes the ports it opened.
  --vpn               OPTIONAL WireGuard VPN on a random UDP port; TorrServer answers only on the VPN address
                      (and on localhost). Manage devices with --add-device / --remove-device.

Options:
  --domain NAME          use this host name instead of <ip>.sslip.io (A record must point here; or env DOMAIN)
  --no-domain            forget a stored domain, go back to <ip>.sslip.io
  --acme-email ADDR      optional e-mail for expiry notices from Let's Encrypt (or env ACME_EMAIL)
  --add-device NAME      --vpn mode: create a device, print its WireGuard config and a QR code
  --remove-device NAME   --vpn mode: revoke a device
  --status               print mode, URL, port, devices
  --rotate-password      generate a new password, restart TorrServer, print it once
  --no-start             write files and units but do not start containers
  --uninstall            stop and remove everything this script opened; keep data
  --purge                with --uninstall: also delete ${TS_DIR} (data, credentials, VPN keys) and Caddy volumes
  --public / --private   old names of the default mode and of --local
  -h, --help             this text

Environment: PUBLIC_IP (skip auto-detection; PUBLIC_IP=auto forgets an earlier value), DOMAIN, ACME_EMAIL,
TS_PUBLIC_PORT, TS_VPN_PORT, TS_VPN_ADDR, TS_VERSION, TS_IMAGE_DIGEST, TS_HOST_PORT, TS_DIR, TS_MEM_LIMIT,
TS_CPUS, TS_CACHE_MB, TS_IDLE_SECONDS. Details: README.md.
USAGE
}

need_arg() { [[ $# -ge 2 && -n "$2" ]] || die "$1 needs a value"; }
set_mode_req() { [[ -z "$MODE_REQ" || "$MODE_REQ" == "$1" ]] || die "choose one mode only (got $MODE_REQ and $1)"; MODE_REQ="$1"; }
set_action() { [[ "$ACTION" == install || "$ACTION" == "$1" ]] || die "choose one action only"; ACTION="$1"; }

while (($#)); do
  case "$1" in
    --public) set_mode_req public ;;
    --local|--private) set_mode_req local ;;
    --vpn) set_mode_req vpn ;;
    --domain) need_arg "$@"; DOMAIN_ARG="$2"; shift ;;
    --no-domain) DOMAIN_ARG="-" ;;
    --acme-email) need_arg "$@"; ACME_EMAIL="$2"; shift ;;
    --add-device) need_arg "$@"; set_action add-device; DEVICE="$2"; shift ;;
    --remove-device) need_arg "$@"; set_action remove-device; DEVICE="$2"; shift ;;
    --status) set_action status ;;
    --rotate-password) ROTATE=1 ;;
    --no-start) NO_START=1 ;;
    --uninstall) set_action uninstall ;;
    --purge) PURGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "run as root (sudo ./install.sh)"
[[ "$TS_HOST_PORT" =~ ^[0-9]+$ && "$TS_HOST_PORT" -ge 1 && "$TS_HOST_PORT" -le 65535 ]] || die "TS_HOST_PORT must be a port number"
[[ "$TS_HTTP_PORT" =~ ^[0-9]+$ && "$TS_HTTP_PORT" -ge 1 && "$TS_HTTP_PORT" -le 65535 ]] || die "TS_HTTP_PORT must be a port number"
[[ "$TS_DIR" == /* && "$TS_DIR" != "/" ]] || die "TS_DIR must be an absolute path other than /"
[[ "$TS_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || die "TS_VERSION has unexpected characters"
[[ "$TS_WG_IF" =~ ^[A-Za-z][A-Za-z0-9_-]{0,14}$ ]] || die "TS_WG_IF is not a valid interface name"
[[ -z "$TS_IMAGE_DIGEST" || "$TS_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die "TS_IMAGE_DIGEST must look like sha256:<64 hex>"
[[ "$TS_CACHE_MB" =~ ^[0-9]+$ && "$TS_IDLE_SECONDS" =~ ^[0-9]+$ ]] || die "TS_CACHE_MB and TS_IDLE_SECONDS must be numbers"
(( PURGE == 0 )) || [[ "$ACTION" == uninstall ]] || die "--purge only goes with --uninstall"

CREDS="${TS_DIR}/credentials"
ENVF="${TS_DIR}/.env"
DATA="${TS_DIR}/data"
FWSTATE="${TS_DIR}/.firewall-added"
CADDY_AUTH="${TS_DIR}/caddy-auth.caddy"
CADDY_TLS="${TS_DIR}/tls.caddy"
LOGS="${TS_DIR}/logs"
VPN_DIR="${TS_DIR}/vpn"
WG_CONF="${WG_DIR}/${TS_WG_IF}.conf"
WG_UNIT="wg-quick@${TS_WG_IF}"
WG_DROPIN="${SYSTEMD_DIR}/${WG_UNIT}.service.d/torrserver.conf"
F2B_FILTER="${F2B_DIR}/filter.d/torrserver-caddy.conf"
F2B_JAIL="${F2B_DIR}/jail.d/torrserver-caddy.conf"
F2B_DROPIN="${SYSTEMD_DIR}/fail2ban.service.d/torrserver.conf"
WG_MARK="# managed by torrserver install.sh"
COMPOSE=()

# ---------- helpers ----------

env_get() { [[ -r "$ENVF" ]] && { grep -E "^$1=" "$ENVF" | tail -n1 | cut -d= -f2- || true; } || true; }

pkg_install() {
  if command -v dnf >/dev/null 2>&1; then dnf -y -q install "$@"
  elif command -v apt-get >/dev/null 2>&1; then apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q "$@"
  elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive -q install "$@"
  else die "no supported package manager (dnf, apt-get, zypper); install: $*"; fi
}

ensure_tools() {
  local t
  for t in curl jq openssl; do
    command -v "$t" >/dev/null 2>&1 || { log "installing $t"; pkg_install "$t"; }
  done
}

check_docker() {
  command -v docker >/dev/null 2>&1 || die "docker is not installed. Install Docker Engine first (https://docs.docker.com/engine/install/), then rerun."
  docker compose version >/dev/null 2>&1 || die "the docker compose plugin is missing (package docker-compose-plugin / docker-compose-v2). Install it, then rerun."
  docker info >/dev/null 2>&1 || die "the Docker daemon is not running or not reachable (systemctl enable --now docker)"
}

# Write a key=value pair into .env (replace or append), keeping every other line.
set_env() {
  local k="$1" v="$2"
  if grep -qE "^${k}=" "$ENVF" 2>/dev/null; then
    local tmp; tmp=$(mktemp "${ENVF}.XXXXXX")
    awk -v k="$k" -v v="$v" 'BEGIN{FS=OFS="="} $1==k{print k "=" v; next} {print}' "$ENVF" > "$tmp"
    chmod 600 "$tmp"; mv "$tmp" "$ENVF"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENVF"
  fi
}

gen_password() {
  local p=""
  while ((${#p} < 32)); do p+=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9'); done
  printf '%s' "${p:0:32}"
}

# Write file content atomically with mode/owner, only if it differs. Returns 0 when it changed.
install_file() { # src dest mode
  if [[ -f "$2" ]] && cmp -s "$1" "$2"; then chmod "$3" "$2"; return 1; fi
  install -m "$3" -o root -g root "$1" "$2"
}

# Same, for content given on stdin.
install_stdin() { # dest mode
  local t rc=0; t=$(mktemp); cat > "$t"
  install_file "$t" "$1" "$2" || rc=$?
  rm -f "$t"; return "$rc"
}

# Memory string as Docker takes it (3g, 512m, 1024k, bytes) to MiB.
mem_mb() {
  local v="${1,,}" n u
  [[ "$v" =~ ^([0-9]+)([kmg]?)b?$ ]] || return 1
  n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[2]}"
  case "$u" in g) echo $((n * 1024)) ;; m) echo "$n" ;; k) echo $((n / 1024)) ;; *) echo $((n / 1048576)) ;; esac
}

# ---------- network: public IP, ports ----------

# IPv4, four plain decimal octets, not in a private, loopback, link-local, CGNAT, documentation, benchmark or reserved range.
is_public_ipv4() {
  local ip="$1" a b c d
  [[ "$ip" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]] || return 1
  a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; c="${BASH_REMATCH[3]}"; d="${BASH_REMATCH[4]}"
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
  (( a == 0 || a == 10 || a == 127 || a >= 224 )) && return 1
  (( a == 100 && b >= 64 && b <= 127 )) && return 1
  (( a == 169 && b == 254 )) && return 1
  (( a == 172 && b >= 16 && b <= 31 )) && return 1
  (( a == 192 && b == 168 )) && return 1
  (( a == 192 && b == 0 && (c == 0 || c == 2) )) && return 1
  (( a == 198 && (b == 18 || b == 19) )) && return 1
  (( a == 198 && b == 51 && c == 100 )) && return 1
  (( a == 203 && b == 0 && c == 113 )) && return 1
  return 0
}

# Prints the public IPv4 of this server (logs go to stderr). Order: Hetzner metadata (from the host, 3 s),
# source address of the default route if it is public, api.ipify.org (5 s).
detect_public_ip() {
  local ip
  ip=$(curl -fsS -m 3 "${TS_METADATA_URL:-http://169.254.169.254/hetzner/v1/metadata/public-ipv4}" 2>/dev/null | tr -d '[:space:]' || true)
  if is_public_ipv4 "$ip"; then note "public IP ${ip} (Hetzner metadata)"; echo "$ip"; return 0; fi
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true)
  if is_public_ipv4 "$ip"; then note "public IP ${ip} (default route source)"; echo "$ip"; return 0; fi
  ip=$(curl -fsS -m 5 "${TS_IPIFY_URL:-https://api.ipify.org}" 2>/dev/null | tr -d '[:space:]' || true)
  if is_public_ipv4 "$ip"; then note "public IP ${ip} (api.ipify.org)"; echo "$ip"; return 0; fi
  return 1
}

# Ports in use by sshd, one per line (never picked, never touched).
ssh_ports() {
  {
    if command -v sshd >/dev/null 2>&1; then sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }' || true; fi
    awk 'tolower($1) == "port" { print $2 }' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
    ss -H -ltnp 2>/dev/null | awk '/"sshd"/ { n = split($4, a, ":"); print a[n] }' || true
    echo 22
  } | sort -u
}

port_busy() { # tcp|udp port
  command -v ss >/dev/null 2>&1 || return 1
  local f=-ltn; [[ "$1" == udp ]] && f=-lun
  [[ -n "$(ss -H "$f" "sport = :$2" 2>/dev/null)" ]]
}

# Pick or reuse a port. choose_port ENVKEY proto OVERRIDE owned(0|1) [excluded ports...]
# Reuses the value stored in .env while it is usable; picks a random free port in 20000-60000 otherwise.
choose_port() {
  local key="$1" proto="$2" override="$3" owned="$4" cur p; shift 4
  local -a bad=("$@")
  mapfile -t -O "${#bad[@]}" bad < <(ssh_ports)
  bad+=("$TS_HOST_PORT" "$TS_HTTP_PORT")
  port_usable() { # port
    local x
    for x in "${bad[@]}"; do [[ "$x" == "$1" ]] && return 1; done
    if port_busy "$proto" "$1" && (( ! owned )); then return 1; fi
    return 0
  }
  if [[ -n "$override" ]]; then
    [[ "$override" =~ ^[0-9]+$ && "$override" -ge 1024 && "$override" -le 65535 ]] || die "${key} must be a port from 1024 to 65535"
    port_usable "$override" || die "port ${override} is the SSH port, reserved or already in use"
    echo "$override"; return 0
  fi
  cur=$(env_get "$key")
  if [[ "$cur" =~ ^[0-9]+$ && "$cur" -ge 1024 && "$cur" -le 65535 ]] && port_usable "$cur"; then echo "$cur"; return 0; fi
  for _ in $(seq 1 200); do
    p=$(shuf -i 20000-60000 -n 1)
    if port_usable "$p"; then echo "$p"; return 0; fi
  done
  die "could not find a free port for ${key}"
}

# ---------- firewall (additive; SSH rules are never read for change or touched) ----------
# State file lines: "<kind> <zone|-> <port/proto>". Only entries this script added are ever removed.

fw_record() { printf '%s\n' "$1" >> "$FWSTATE"; chmod 600 "$FWSTATE"; }
fw_backend() {
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then echo firewalld
  elif command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null || true)" == *"Status: active"* ]]; then echo ufw
  else echo none; fi
}

fw_open_one() { # port/proto
  local port="$1" zone
  case "$(fw_backend)" in
    firewalld)
      zone=$(firewall-cmd --get-default-zone)
      if firewall-cmd --permanent --zone="$zone" --query-port="$port" >/dev/null 2>&1; then
        log "firewalld: ${port} already open in zone ${zone} (left as it is)"
      else
        # Runtime and permanent, no --reload: nothing else in the running config is touched.
        firewall-cmd -q --zone="$zone" --add-port="$port"
        firewall-cmd -q --permanent --zone="$zone" --add-port="$port"
        fw_record "firewalld ${zone} ${port}"
        log "firewalld: opened ${port} in zone ${zone}"
      fi ;;
    ufw)
      if grep -qE "^${port}[[:space:]]+ALLOW" <<<"$(ufw status 2>/dev/null || true)"; then
        log "ufw: ${port} already allowed (left as it is)"
      else
        ufw allow "$port" comment 'torrserver' >/dev/null
        fw_record "ufw - ${port}"
        log "ufw: allowed ${port}"
      fi ;;
    *) log "no active firewalld or ufw: nothing to open on the host for ${port}. Check the Hetzner Cloud Firewall." ;;
  esac
}

fw_close_one() { # kind zone port/proto
  case "$1" in
    firewalld)
      command -v firewall-cmd >/dev/null 2>&1 || return 0
      firewall-cmd -q --zone="$2" --remove-port="$3" 2>/dev/null || true
      firewall-cmd -q --permanent --zone="$2" --remove-port="$3" 2>/dev/null || true
      log "firewalld: closed ${3} in zone ${2} (opened by this script)" ;;
    ufw)
      command -v ufw >/dev/null 2>&1 || return 0
      ufw delete allow "$3" >/dev/null 2>&1 || true
      log "ufw: removed allow ${3} (added by this script)" ;;
  esac
}

# Make the set of ports this script has opened equal to the wanted list (port/proto arguments):
# close what it opened before and is no longer wanted, open what is missing.
fw_reconcile() {
  local kind zone port want w keep
  if [[ -f "$FWSTATE" ]]; then
    keep=$(mktemp)
    while read -r kind zone port; do
      [[ -n "$kind" ]] || continue
      want=0
      for w in "$@"; do [[ "$w" == "$port" ]] && want=1; done
      if (( want )); then printf '%s %s %s\n' "$kind" "$zone" "$port" >> "$keep"; else fw_close_one "$kind" "$zone" "$port"; fi
    done < "$FWSTATE"
    if [[ -s "$keep" ]]; then install -m 600 -o root -g root "$keep" "$FWSTATE"; else rm -f "$FWSTATE"; fi
    rm -f "$keep"
  fi
  for w in "$@"; do
    if [[ -f "$FWSTATE" ]] && awk -v p="$w" '$3 == p { f = 1 } END { exit !f }' "$FWSTATE"; then continue; fi
    fw_open_one "$w"
  done
}

# ---------- settings via the API ----------

CURL_CFG=""
api_init() { # reads credentials into a 0600 curl config inside a private tmp dir
  local t u p
  t=$(mktemp -d); chmod 700 "$t"
  u=$(grep -E '^TS_USER=' "$CREDS" | head -n1 | cut -d= -f2-)
  p=$(grep -E '^TS_PASS=' "$CREDS" | head -n1 | cut -d= -f2-)
  (umask 077; printf 'user = "%s:%s"\nheader = "Content-Type: application/json"\n' "$u" "$p" > "${t}/curl.conf")
  CURL_CFG="${t}/curl.conf"
}
api_cleanup() { if [[ -n "$CURL_CFG" ]]; then rm -rf "$(dirname "$CURL_CFG")"; fi; CURL_CFG=""; }
trap api_cleanup EXIT
api() { curl -fsS -m 30 -K "$CURL_CFG" -X POST --data-binary "$1" "http://127.0.0.1:${TS_HOST_PORT}$2"; }

wait_echo() {
  for _ in $(seq 1 60); do
    curl -fsS -m 3 -o /dev/null "http://127.0.0.1:${TS_HOST_PORT}/echo" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

# CacheSize in MiB: TS_CACHE_MB, but at most half of the container memory limit (the rest is for the Go heap,
# peer buffers and the kernel), and at least 32.
effective_cache_mb() {
  local lim cap eff="$TS_CACHE_MB"
  lim=$(mem_mb "$TS_MEM_LIMIT") || die "TS_MEM_LIMIT '${TS_MEM_LIMIT}' is not a size like 3g or 512m"
  cap=$((lim / 2))
  if (( eff > cap )); then note "TS_CACHE_MB=${TS_CACHE_MB} is more than half of TS_MEM_LIMIT=${TS_MEM_LIMIT}; using ${cap} MB"; eff=$cap; fi
  (( eff >= 32 )) || eff=32
  echo "$eff"
}

# Settings overrides, streaming only. Names are fields of settings.BTSets (server/settings/btsets.go).
#   UseDisk=false              pieces live in RAM (CacheSize); nothing is written to the disk
#   TorrentsSavePath=""        no disk cache location (the loader forces UseDisk=false without one)
#   PreloadCache=10            % of CacheSize fetched before playback starts (~38 MB at 384 MB: quick start)
#   ReaderReadAHead=90         % of the cache kept ahead of the playback position (default 95), 10% behind for seeking
#   ResponsiveMode=true        serve a piece as soon as it arrives instead of waiting for the whole piece set
wanted_settings() {
  jq -n --argjson cache "$(( $(effective_cache_mb) * 1024 * 1024 ))" --argjson idle "$TS_IDLE_SECONDS" '{
    DisableUpload: true,
    UseDisk: false,
    TorrentsSavePath: "",
    RemoveCacheOnDrop: true,
    CacheSize: $cache,
    PreloadCache: 10,
    ReaderReadAHead: 90,
    ResponsiveMode: true,
    TorrentDisconnectTimeout: $idle,
    DisableUPNP: true,
    EnableLPD: false,
    EnableDLNA: false,
    EnableBonjour: false,
    EnableDebug: false
  }'
}

apply_settings() {
  local cur want merged now
  want=$(wanted_settings)
  api_init
  cur=$(api '{"action":"get"}' /settings) || die "cannot read settings from the API (wrong credentials? see: docker logs torrserver)"
  jq -e 'type=="object"' <<<"$cur" >/dev/null || die "unexpected /settings reply"
  # "set" replaces the whole object, so send the current settings with our keys changed.
  merged=$(jq -c --argjson w "$want" '. + $w' <<<"$cur")
  if [[ "$(jq -cS . <<<"$cur")" == "$(jq -cS . <<<"$merged")" ]]; then
    log "settings already as wanted"
    api_cleanup
    return 0
  fi
  api "$(jq -c '{action:"set", sets:.}' <<<"$merged")" /settings >/dev/null || die "could not set settings"
  now=$(api '{"action":"get"}' /settings)
  jq -e --argjson w "$want" '. as $n | $w | to_entries | all(.key as $k | $n[$k] == .value)' <<<"$now" >/dev/null \
    || die "settings were not applied as requested; check: docker logs torrserver"
  api_cleanup
  log "settings applied: streaming only (RAM cache $(jq -r '.CacheSize / 1048576 | floor' <<<"$want") MB, no disk, no upload), DLNA/UPnP/LPD/Bonjour off"
}

# ---------- credentials ----------

# The container user (uid ${TS_UID}) owns data/ and can replace data/config, downloads or torrents with a symlink. Root
# (install -d chowns, mktemp and mv write) must never follow one: refuse when any of them is not a plain directory
# inside data/ itself.
check_data_tree() {
  local d real base
  [[ -e "$DATA" || -L "$DATA" ]] || return 0
  [[ ! -L "$DATA" ]] || die "${DATA} is a symlink; refusing to continue (remove it after checking where it points)"
  base=$(realpath -e -- "$DATA") && [[ "$base" == "$(realpath -m -- "$TS_DIR")/data" ]] || die "${DATA} resolves outside ${TS_DIR}/data; refusing to continue"
  for d in config downloads torrents; do
    [[ -e "${DATA}/${d}" || -L "${DATA}/${d}" ]] || continue
    [[ ! -L "${DATA}/${d}" ]] || die "${DATA}/${d} is a symlink (the container user can create one); refusing to continue as root. Check where it points, remove it, rerun"
    real=$(realpath -e -- "${DATA}/${d}")
    [[ "$real" == "${base}/${d}" ]] || die "${DATA}/${d} resolves outside ${DATA} (${real}); refusing to continue"
  done
}

write_accs() { # accs.db: {"user":"password"}, readable by the container user only
  local user pass tmp
  user=$(grep -E '^TS_USER=' "$CREDS" | head -n1 | cut -d= -f2-)
  pass=$(grep -E '^TS_PASS=' "$CREDS" | head -n1 | cut -d= -f2-)
  check_data_tree
  # Staged in the root-owned install dir, moved into config/ only after the check above.
  tmp=$(mktemp "${TS_DIR}/.accs.XXXXXX")
  # Through the environment, not argv: /proc/<pid>/cmdline is world readable, environ is not.
  TS_U="$user" TS_P="$pass" jq -nc '{(env.TS_U): env.TS_P}' > "$tmp"
  chown "${TS_UID}:${TS_GID}" "$tmp"; chmod 600 "$tmp"
  if [[ -f "${DATA}/config/accs.db" ]] && cmp -s "$tmp" "${DATA}/config/accs.db"; then rm -f "$tmp"; return 1; fi
  mv -T "$tmp" "${DATA}/config/accs.db"
}

# Caddy login in front of TorrServer (public mode). TorrServer leaves /play, /subs, /playlist, /stream
# and /swagger outside its own auth, so Caddy asks for the same login on every path except /echo.
# Only a bcrypt hash is stored (0600, root). The password goes to caddy hash-password on stdin.
write_caddy_auth() { # returns 0 when the file was (re)written
  local user pass hash tmp
  user=$(grep -E '^TS_USER=' "$CREDS" | head -n1 | cut -d= -f2-)
  pass=$(grep -E '^TS_PASS=' "$CREDS" | head -n1 | cut -d= -f2-)
  hash=$(printf '%s\n' "$pass" | docker run --rm -i --network none --read-only "$CADDY_IMAGE" caddy hash-password) \
    || die "could not hash the password with the caddy image"
  [[ "$hash" =~ ^\$2[aby]\$[0-9]{2}\$[A-Za-z0-9./]{53}$ ]] || die "caddy hash-password returned an unexpected value"
  tmp=$(mktemp "${CADDY_AUTH}.XXXXXX")
  chmod 600 "$tmp"
  printf 'basic_auth {\n\t%s %s\n}\n' "$user" "$hash" > "$tmp"
  mv "$tmp" "$CADDY_AUTH"
}

# TLS snippet imported by the Caddyfile. acme = Let's Encrypt over HTTP-01 on port 80 (TLS-ALPN-01 needs 443,
# which is not published, so it is off). internal = Caddy's own CA, for tests only (TS_TLS=internal).
# Returns 0 when the file changed (a running Caddy reads it only at start).
write_tls_snippet() { # tls_mode email
  if [[ "$1" == internal ]]; then
    printf 'tls internal\n' | install_stdin "$CADDY_TLS" 0644
  else
    {
      printf 'tls {\n\tissuer acme {\n'
      if [[ -n "$2" ]]; then printf '\t\temail %s\n' "$2"; fi
      printf '\t\tdisable_tlsalpn_challenge\n\t}\n}\n'
    } | install_stdin "$CADDY_TLS" 0644
  fi
}

# ---------- fail2ban for the Caddy access log (Caddy 2.10 has no rate_limit module) ----------

f2b_setup() { # tcp-port
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    log "installing fail2ban (bans clients that keep failing the login). On Debian/Ubuntu the package also turns on its default sshd jail."
    pkg_install fail2ban >/dev/null 2>&1 || { warn "fail2ban could not be installed (on EL it is in EPEL). Without it there is no rate limit on login attempts; the 32-character password is what protects the server."; return 0; }
  fi
  install -d -m 0755 "${F2B_DIR}/filter.d" "${F2B_DIR}/jail.d" "$(dirname "$F2B_DROPIN")"
  local ch=0
  # Caddy JSON access log: "remote_ip" comes before "status" in every line.
  install_stdin "$F2B_FILTER" 0644 <<'EOF' && ch=1
# Managed by torrserver install.sh
[Definition]
datepattern = "ts":{EPOCH}
failregex = ^.*"remote_ip":"<ADDR>".*"status":401[,}]
ignoreregex =
EOF
  # Docker publishes the port through NAT, so the ban must be in DOCKER-USER (the INPUT chain never sees that traffic).
  install_stdin "$F2B_JAIL" 0644 <<EOF && ch=1
# Managed by torrserver install.sh
[torrserver-caddy]
enabled   = true
filter    = torrserver-caddy
logpath   = ${LOGS}/access.log
backend   = auto
port      = $1
protocol  = tcp
chain     = DOCKER-USER
banaction = iptables-multiport
maxretry  = 8
findtime  = 10m
bantime   = 1h
EOF
  # The jail needs the DOCKER-USER chain, which exists once Docker is up.
  install_stdin "$F2B_DROPIN" 0644 <<'EOF' && ch=1
# Managed by torrserver install.sh
[Unit]
After=docker.service
EOF
  if command -v systemctl >/dev/null 2>&1; then
    (( ch )) && systemctl daemon-reload || true
    if systemctl is-active --quiet fail2ban; then
      (( ch )) && { systemctl restart fail2ban || warn "fail2ban restart failed (journalctl -u fail2ban)"; }
    else
      systemctl enable --now fail2ban >/dev/null 2>&1 || warn "fail2ban could not be started (journalctl -u fail2ban)"
    fi
  fi
  log "fail2ban: jail torrserver-caddy on tcp/$1 (8 failed logins in 10 min -> 1 h ban)"
}

f2b_remove() {
  local f ch=0
  for f in "$F2B_FILTER" "$F2B_JAIL" "$F2B_DROPIN"; do
    if [[ -e "$f" ]]; then rm -f "$f"; ch=1; fi
  done
  if (( ch )) && command -v systemctl >/dev/null 2>&1; then
    rmdir "$(dirname "$F2B_DROPIN")" 2>/dev/null || true
    systemctl daemon-reload || true
    if systemctl is-active --quiet fail2ban; then systemctl restart fail2ban || true; fi
    log "fail2ban: jail torrserver-caddy removed"
  fi
}

# ---------- WireGuard (optional --vpn mode) ----------

vpn_devices_file() { echo "${VPN_DIR}/devices"; }

# wg0.conf from the key and the devices list. Holds the server private key and the pre-shared keys: 0600.
wg_write_conf() { # udp-port server-addr
  local tmp name ip pub psk
  install -d -m 0700 -o root -g root "$WG_DIR"
  tmp=$(mktemp "${WG_CONF}.XXXXXX")
  {
    printf '%s - do not edit, use install.sh --add-device / --remove-device\n' "$WG_MARK"
    printf '[Interface]\nAddress = %s/24\nListenPort = %s\nPrivateKey = %s\n' "$2" "$1" "$(cat "${VPN_DIR}/server.key")"
    if [[ -s "$(vpn_devices_file)" ]]; then
      while read -r name ip pub psk; do
        [[ -n "$name" ]] || continue
        printf '\n# device: %s\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' "$name" "$pub" "$psk" "$ip"
      done < "$(vpn_devices_file)"
    fi
  } > "$tmp"
  chmod 600 "$tmp"; chown root:root "$tmp"
  mv "$tmp" "$WG_CONF"
}

# Bring the running interface in line with the file without dropping other peers; start it if it is down.
wg_apply() {
  if systemctl is-active --quiet "$WG_UNIT" 2>/dev/null; then
    wg syncconf "$TS_WG_IF" <(wg-quick strip "$WG_CONF") || die "wg syncconf failed"
  else
    systemctl enable --now "$WG_UNIT" >/dev/null 2>&1 || die "could not start ${WG_UNIT} (is the wireguard kernel module available? journalctl -u ${WG_UNIT})"
  fi
}

vpn_install_tools() {
  local missing=()
  command -v wg >/dev/null 2>&1 || missing+=(wireguard-tools)
  command -v qrencode >/dev/null 2>&1 || missing+=(qrencode)
  if ((${#missing[@]})); then
    log "installing ${missing[*]}"
    pkg_install "${missing[@]}" || die "could not install ${missing[*]} (on EL, wireguard-tools and qrencode come from EPEL)"
  fi
  command -v wg >/dev/null 2>&1 || die "wg not found after install"
}

vpn_setup() { # udp-port server-addr
  local own
  if [[ -e "$WG_CONF" ]] && ! grep -qF "$WG_MARK" "$WG_CONF"; then
    die "${WG_CONF} exists and was not written by this script. Use another interface name (TS_WG_IF=wg1) or move that file."
  fi
  vpn_install_tools
  install -d -m 0700 -o root -g root "$VPN_DIR"
  if [[ ! -s "${VPN_DIR}/server.key" ]]; then
    (umask 077; wg genkey > "${VPN_DIR}/server.key")
    log "wireguard: server key created (${VPN_DIR}/server.key, 0600)"
  fi
  chmod 600 "${VPN_DIR}/server.key"
  wg pubkey < "${VPN_DIR}/server.key" > "${VPN_DIR}/server.pub"
  [[ -f "$(vpn_devices_file)" ]] || { (umask 077; : > "$(vpn_devices_file)"); }
  chmod 600 "$(vpn_devices_file)"
  # Not already used by another interface.
  own=$(ip -4 -o addr show 2>/dev/null | awk -v a="${2%.*}." -v w="$TS_WG_IF" '$2 != w && index($4, a) == 1 { print $2; exit }' || true)
  [[ -z "$own" ]] || die "the VPN network ${2%.*}.0/24 is already used by interface ${own}. Set TS_VPN_ADDR to a free private address ending in .1 (for example 10.77.77.1)."
  wg_write_conf "$1" "$2"
  # TorrServer binds to the VPN address, so the interface must exist before Docker starts containers at boot.
  install -d -m 0755 "$(dirname "$WG_DROPIN")"
  printf '# Managed by torrserver install.sh\n[Unit]\nBefore=docker.service\n' | install_stdin "$WG_DROPIN" 0644 || true
  systemctl daemon-reload
}

vpn_teardown() {
  if [[ -e "$WG_CONF" ]] && grep -qF "$WG_MARK" "$WG_CONF" 2>/dev/null; then
    if command -v systemctl >/dev/null 2>&1; then systemctl disable --now "$WG_UNIT" >/dev/null 2>&1 || true; fi
    rm -f "$WG_CONF"
    log "wireguard: ${TS_WG_IF} stopped and its config removed (keys and device list kept in ${VPN_DIR})"
  fi
  if [[ -e "$WG_DROPIN" ]]; then
    rm -f "$WG_DROPIN"; rmdir "$(dirname "$WG_DROPIN")" 2>/dev/null || true
    if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload || true; fi
  fi
}

require_vpn_mode() {
  [[ -f "$ENVF" ]] || die "TorrServer is not installed here (no ${ENVF}). Run: sudo ./install.sh --vpn"
  [[ "$(env_get TS_MODE)" == vpn ]] || die "the VPN is not enabled (mode is '$(env_get TS_MODE)'). Run: sudo ./install.sh --vpn"
}

add_device() {
  local name="$DEVICE" n ip priv pub psk spub port ep addr used
  [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "device name: 1-32 letters, digits, - or _"
  require_vpn_mode
  command -v qrencode >/dev/null 2>&1 || vpn_install_tools
  addr=$(env_get TS_VPN_ADDR); port=$(env_get TS_VPN_PORT)
  grep -qE "^${name} " "$(vpn_devices_file)" 2>/dev/null && die "device '${name}' already exists (remove it first: --remove-device ${name})"
  used=" $(awk '{ print $2 }' "$(vpn_devices_file)" | tr '\n' ' ')"
  ip=""
  for n in $(seq 2 254); do
    if [[ "$used" != *" ${addr%.*}.${n} "* ]]; then ip="${addr%.*}.${n}"; break; fi
  done
  [[ -n "$ip" ]] || die "no free VPN address left"
  priv=$(wg genkey); pub=$(printf '%s' "$priv" | wg pubkey); psk=$(wg genpsk)
  spub=$(cat "${VPN_DIR}/server.pub")
  ep="$(env_get DOMAIN)"; [[ -n "$ep" ]] || ep="$(env_get PUBLIC_IP)"
  [[ -n "$ep" ]] || die "no public IP stored; rerun: sudo PUBLIC_IP=1.2.3.4 ./install.sh --vpn"
  printf '%s %s %s %s\n' "$name" "$ip" "$pub" "$psk" >> "$(vpn_devices_file)"
  wg_write_conf "$port" "$addr"
  wg_apply
  local conf
  conf=$(printf '[Interface]\nPrivateKey = %s\nAddress = %s/32\n\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nEndpoint = %s:%s\nAllowedIPs = %s/32\nPersistentKeepalive = 25\n' \
    "$priv" "$ip" "$spub" "$psk" "$ep" "$port" "$addr")
  unset priv psk
  echo "Device '${name}' added (${ip}). Shown once, the private key is not stored on the server."
  echo "Import this in the WireGuard app (only the TorrServer address goes through the VPN):"
  echo
  echo "$conf"
  echo
  if command -v qrencode >/dev/null 2>&1; then
    echo "QR code (WireGuard app -> Add tunnel -> Scan from QR code):"
    qrencode -t ansiutf8 <<<"$conf"
  else
    warn "qrencode not available: copy the config above by hand"
  fi
  echo
  echo "Then open: http://${addr}:${TS_HOST_PORT}/  (login: sudo cat ${CREDS})"
}

remove_device() {
  local name="$DEVICE" addr port tmp
  [[ "$name" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || die "device name: 1-32 letters, digits, - or _"
  require_vpn_mode
  grep -qE "^${name} " "$(vpn_devices_file)" 2>/dev/null || die "no device named '${name}' (see: --status)"
  addr=$(env_get TS_VPN_ADDR); port=$(env_get TS_VPN_PORT)
  tmp=$(mktemp "$(vpn_devices_file).XXXXXX")
  grep -vE "^${name} " "$(vpn_devices_file)" > "$tmp" || true
  chmod 600 "$tmp"; mv "$tmp" "$(vpn_devices_file)"
  wg_write_conf "$port" "$addr"
  wg_apply
  log "device '${name}' removed; its keys no longer work"
}

# ---------- install ----------

# Print the compose project label of a container; empty if there is no such container.
container_project() { docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$1" 2>/dev/null || true; }
container_exists() { docker inspect "$1" >/dev/null 2>&1; }
container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]; }

set_compose() { # mode
  COMPOSE=(docker compose --project-directory "$TS_DIR" -f "${TS_DIR}/docker-compose.yml")
  if [[ "$1" == vpn ]]; then COMPOSE+=(-f "${TS_DIR}/docker-compose.vpn.yml"); fi
}

resolve_mode() {
  local m="$MODE_REQ"
  [[ -n "$m" ]] || m=$(env_get TS_MODE)
  if [[ -z "$m" && -f "$ENVF" ]]; then
    # An install from before the modes existed keeps what it had.
    case "$(env_get TS_PUBLIC)" in 1) m=public ;; 0) m=local ;; esac
  fi
  echo "${m:-public}"
}

do_install() {
  local mode domain email new_creds=0 changed_creds=0 recreate=0 caddy_changed=0 c
  local ip_new="" ip_old="" ip_pin="" host="" pub_port="" vpn_port="" vpn_addr="" tls_mode=""
  ensure_tools
  check_docker
  mem_mb "$TS_MEM_LIMIT" >/dev/null || die "TS_MEM_LIMIT '${TS_MEM_LIMIT}' is not a size like 3g or 512m"

  mode=$(resolve_mode)
  case "$mode" in public|local|vpn) ;; *) die "unknown mode '${mode}' in ${ENVF}" ;; esac

  # Domain: --domain beats env DOMAIN beats what an earlier run stored.
  case "$DOMAIN_ARG" in
    "") domain="${DOMAIN_ENV:-$(env_get DOMAIN)}" ;;
    -) domain="" ;;
    *) domain="$DOMAIN_ARG" ;;
  esac
  email="${ACME_EMAIL:-$(env_get ACME_EMAIL)}"
  tls_mode="${TS_TLS:-$(env_get TS_TLS)}"; tls_mode="${tls_mode:-acme}"
  [[ "$tls_mode" == acme || "$tls_mode" == internal ]] || die "TS_TLS must be acme or internal"
  [[ -z "$domain" || ( "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$domain" == *.* ) ]] || die "DOMAIN '${domain}' is not a valid host name"
  [[ -z "$email" || "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "ACME_EMAIL '${email}' is not a valid address"

  # Containers named like ours but started from somewhere else (for example a hand-written compose file).
  for c in torrserver torrserver-caddy; do
    if container_exists "$c" && [[ "$(container_project "$c")" != torrserver ]]; then
      die "a container named '${c}' already exists and was not created by this script. Stop and remove it (docker rm -f ${c}), then rerun."
    fi
  done

  # Public IP: needed for the public name and for the VPN endpoint. Re-detected on every run.
  ip_old=$(env_get PUBLIC_IP)
  ip_pin=$(env_get PUBLIC_IP_PINNED)
  case "$PUBLIC_IP_ENV" in
    auto) ip_pin="" ;;
    "") ;;
    *) ip_pin="$PUBLIC_IP_ENV" ;;
  esac
  if [[ -n "$ip_pin" ]]; then is_public_ipv4 "$ip_pin" || die "PUBLIC_IP '${ip_pin}' is not a public IPv4 address"; fi
  if [[ "$mode" != local ]]; then
    if [[ -n "$ip_pin" ]]; then
      ip_new="$ip_pin"
    elif ! ip_new=$(detect_public_ip); then
      if [[ -n "$domain" && "$mode" == public ]]; then
        warn "could not detect the public IP; continuing with the domain ${domain}"
        ip_new="$ip_old"
      else
        die "could not detect the public IP of this server (tried Hetzner metadata, the default route, api.ipify.org). Set it yourself: sudo PUBLIC_IP=1.2.3.4 ./install.sh"
      fi
    fi
    if [[ -n "$ip_old" && -n "$ip_new" && "$ip_old" != "$ip_new" ]]; then
      warn "the public IP changed: ${ip_old} -> ${ip_new}. The hostname and the certificate follow it$([[ "$mode" == vpn ]] && echo "; WireGuard devices need their endpoint changed to the new IP")."
    fi
  fi

  log "installing TorrServer ${TS_VERSION} into ${TS_DIR} (mode: ${mode})"
  install -d -m 0755 -o root -g root "$TS_DIR"
  check_data_tree
  install -d -m 0750 -o "$TS_UID" -g "$TS_GID" "$DATA" "${DATA}/config" "${DATA}/downloads" "${DATA}/torrents"
  [[ -f "$ENVF" ]] || { (umask 077; : > "$ENVF"); }
  chmod 600 "$ENVF"

  # Ports and hostname for the chosen mode.
  if [[ "$mode" == public ]]; then
    local owned=0
    container_running torrserver-caddy && owned=1
    pub_port=$(choose_port TS_PUBLIC_PORT tcp "${TS_PUBLIC_PORT:-}" "$owned")
    if port_busy tcp "$TS_HTTP_PORT" && (( ! owned )); then
      die "TCP ${TS_HTTP_PORT} is already in use by another service. Let's Encrypt needs port 80 for the certificate. Stop that service, or use --local / --vpn."
    fi
    host="${domain:-${ip_new//./-}.sslip.io}"
    [[ -n "$domain" || -n "$ip_new" ]] || die "no public IP and no domain"
    check_dns "$host" "$ip_new"
  elif [[ "$mode" == vpn ]]; then
    local wg_owned=0
    ip link show "$TS_WG_IF" >/dev/null 2>&1 && wg_owned=1
    vpn_port=$(choose_port TS_VPN_PORT udp "${TS_VPN_PORT:-}" "$wg_owned" "$(env_get TS_PUBLIC_PORT)")
    vpn_addr="${TS_VPN_ADDR:-$(env_get TS_VPN_ADDR)}"; vpn_addr="${vpn_addr:-10.66.66.1}"
    [[ "$vpn_addr" =~ ^(10\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]{1,3}\.1$ ]] || die "TS_VPN_ADDR must be a private IPv4 address ending in .1 (default 10.66.66.1)"
  fi

  install_file "${SRC}/docker-compose.yml" "${TS_DIR}/docker-compose.yml" 0644 || true
  install_file "${SRC}/docker-compose.vpn.yml" "${TS_DIR}/docker-compose.vpn.yml" 0644 || true
  # Single-file bind mounts: Caddy keeps the old inode and reads its config only at start, so a change needs a restart.
  install_file "${SRC}/Caddyfile" "${TS_DIR}/Caddyfile" 0644 && caddy_changed=1
  install_file "${SRC}/cleanup.sh" "${TS_DIR}/cleanup.sh" 0750 || true

  # .env: managed keys are rewritten on every run, there are no secrets in it.
  set_env TS_IMAGE "${TS_IMAGE_REPO}:${TS_VERSION}${TS_IMAGE_DIGEST:+@${TS_IMAGE_DIGEST}}"
  set_env TS_VERSION "$TS_VERSION"
  set_env TS_MODE "$mode"
  set_env TS_BIND 127.0.0.1
  set_env TS_HOST_PORT "$TS_HOST_PORT"
  set_env TS_HTTP_PORT "$TS_HTTP_PORT"
  set_env TS_UID "$TS_UID"
  set_env TS_GID "$TS_GID"
  set_env TS_MEM_LIMIT "$TS_MEM_LIMIT"
  set_env TS_MEM_RESERVATION "$TS_MEM_RESERVATION"
  set_env TS_CPUS "$TS_CPUS"
  set_env CADDY_IMAGE "$CADDY_IMAGE"
  set_env DOMAIN "$domain"
  set_env ACME_EMAIL "$email"
  set_env TS_TLS "$tls_mode"
  set_env PUBLIC_IP_PINNED "$ip_pin"
  [[ "$mode" == local ]] || set_env PUBLIC_IP "$ip_new"
  [[ "$mode" != public ]] || { set_env TS_PUBLIC_PORT "$pub_port"; set_env TS_HOSTNAME "$host"; }
  [[ "$mode" != vpn ]] || { set_env TS_VPN_PORT "$vpn_port"; set_env TS_VPN_ADDR "$vpn_addr"; }
  set_env COMPOSE_PROFILES "$([[ "$mode" == public ]] && echo public || echo "")"
  set_env COMPOSE_FILE "docker-compose.yml$([[ "$mode" == vpn ]] && echo ":docker-compose.vpn.yml")"
  # The old yes/no flag of earlier versions is replaced by TS_MODE.
  sed -i '/^TS_PUBLIC=/d' "$ENVF"
  set_compose "$mode"

  # Credentials: created once, rotated only on request. accs.db is rewritten whenever it differs.
  if [[ ! -f "$CREDS" ]]; then new_creds=1; fi
  if (( new_creds || ROTATE )); then
    local pass
    pass=$(gen_password)
    (umask 077; printf 'TS_USER=torrserver\nTS_PASS=%s\n' "$pass" > "${CREDS}.new")
    chown root:root "${CREDS}.new"; chmod 600 "${CREDS}.new"
    mv "${CREDS}.new" "$CREDS"
    changed_creds=1
    unset pass
  fi
  chown root:root "$CREDS"; chmod 600 "$CREDS"
  write_accs && changed_creds=1

  # accs.db is read only at start: if it changed under a container that already exists, recreate it.
  if (( changed_creds )) && container_exists torrserver; then recreate=1; fi

  # Mode specific files that must exist before the containers start.
  if [[ "$mode" == public ]]; then
    install -d -m 0750 -o root -g root "$LOGS"
    write_tls_snippet "$tls_mode" "$email" && caddy_changed=1
  elif [[ "$mode" == vpn ]]; then
    vpn_setup "$vpn_port" "$vpn_addr"
  fi

  if (( NO_START )); then
    log "--no-start: files written, containers not started"
  else
    if ! "${COMPOSE[@]}" config -q; then die "docker compose config failed"; fi
    "${COMPOSE[@]}" pull -q >/dev/null 2>&1 || warn "image pull failed; using a local copy if present"
    if [[ "$mode" == public ]]; then
      # New hash when the password changed or the file is gone (bcrypt salts differ, so it cannot be compared).
      if (( changed_creds )) || [[ ! -s "$CADDY_AUTH" ]]; then
        write_caddy_auth && recreate=1
      fi
    else
      # A profile that is no longer active is not an orphan, so remove Caddy explicitly.
      "${COMPOSE[@]}" --profile public rm -sf caddy >/dev/null 2>&1 || true
      rm -f "$CADDY_AUTH" "$CADDY_TLS"
    fi
    [[ "$mode" != vpn ]] || wg_apply
    if (( recreate )); then "${COMPOSE[@]}" up -d --remove-orphans --force-recreate; else "${COMPOSE[@]}" up -d --remove-orphans; fi
    # Caddyfile or TLS snippet changed under a Caddy that already ran: restart only Caddy so it loads them.
    if [[ "$mode" == public ]] && (( caddy_changed && ! recreate )) && container_exists torrserver-caddy; then
      "${COMPOSE[@]}" up -d --force-recreate --no-deps caddy
    fi
    wait_echo || die "TorrServer did not answer on 127.0.0.1:${TS_HOST_PORT} within 60 s (docker logs torrserver)"
    apply_settings
  fi

  # Whatever the other modes opened goes away now that the containers are on the new mode.
  [[ "$mode" == vpn ]] || vpn_teardown
  [[ "$mode" == public ]] || f2b_remove
  case "$mode" in
    public) fw_reconcile "${TS_HTTP_PORT}/tcp" "${pub_port}/tcp"; f2b_setup "$pub_port" ;;
    vpn) fw_reconcile "${vpn_port}/udp" ;;
    local) fw_reconcile ;;
  esac

  install_cleanup_timer

  summary "$new_creds" "$changed_creds" "$mode" "$host" "$pub_port" "$vpn_port" "$vpn_addr"
}

# Warn (never fail) if the name does not point at this server yet; Let's Encrypt would fail then.
check_dns() { # host ip
  local got
  got=$(getent ahostsv4 "$1" 2>/dev/null | awk '{ print $1 }' | sort -u | tr '\n' ' ' || true)
  if [[ -z "$got" ]]; then
    warn "cannot resolve ${1} from this server right now (offline resolver?). The certificate needs it to resolve to ${2:-the IP of this server}."
  elif [[ -n "$2" && " ${got}" != *" ${2} "* ]]; then
    warn "${1} resolves to ${got}, not to ${2}. Fix the A record, or Let's Encrypt will fail."
  else
    log "DNS: ${1} -> ${got}"
  fi
}

install_cleanup_timer() {
  command -v systemctl >/dev/null 2>&1 || { warn "systemctl not found: cleanup timer not installed (run ${TS_DIR}/cleanup.sh yourself)"; return 0; }
  local d=0 f tmp
  for f in torrserver-cleanup.service torrserver-cleanup.timer; do
    tmp=$(mktemp); sed "s|@DIR@|${TS_DIR}|g" "${SRC}/${f}" > "$tmp"
    install_file "$tmp" "${SYSTEMD_DIR}/${f}" 0644 && d=1
    rm -f "$tmp"
  done
  if (( d )); then systemctl daemon-reload; fi
  systemctl enable --now torrserver-cleanup.timer >/dev/null
  log "timer torrserver-cleanup.timer enabled (next: $(systemctl list-timers torrserver-cleanup.timer --no-legend 2>/dev/null | awk '{print $1, $2}' | head -n1))"
}

summary() {
  local new="$1" changed="$2" mode="$3" host="$4" pport="$5" vport="$6" vaddr="$7"
  echo
  echo "TorrServer ${TS_VERSION} is installed (streaming only, mode: ${mode})."
  case "$mode" in
    public)
      echo "  URL:      https://${host}:${pport}/"
      echo "            HTTPS with a login. Certificate from Let's Encrypt for ${host} (first request can take a few seconds)."
      echo "            Open in the firewall: TCP ${pport} (the service) and TCP ${TS_HTTP_PORT} (certificate challenge + redirect only)."
      echo "            Hetzner Cloud Firewall: allow the same two TCP ports." ;;
    local)
      echo "  Listens:  127.0.0.1:${TS_HOST_PORT} only. From your laptop:"
      echo "            ssh -L ${TS_HOST_PORT}:127.0.0.1:${TS_HOST_PORT} USER@SERVER   then open http://127.0.0.1:${TS_HOST_PORT}/" ;;
    vpn)
      echo "  URL:      http://${vaddr}:${TS_HOST_PORT}/   (only through the VPN, and on localhost)"
      echo "  VPN:      WireGuard ${TS_WG_IF}, UDP ${vport}. Add a phone or laptop: sudo ./install.sh --add-device NAME"
      echo "            Hetzner Cloud Firewall: allow UDP ${vport}." ;;
  esac
  if [[ "$new" == 1 || ( "$ROTATE" == 1 && "$changed" == 1 ) || ! -e "${TS_DIR}/.login-shown" ]]; then
    echo
    echo "  Login (shown once; stored only in ${CREDS}, root 0600):"
    echo "    user:     $(grep -E '^TS_USER=' "$CREDS" | cut -d= -f2-)"
    echo "    password: $(grep -E '^TS_PASS=' "$CREDS" | cut -d= -f2-)"
    : > "${TS_DIR}/.login-shown"
  else
    echo "  Login:    unchanged, read it with: sudo cat ${CREDS}"
  fi
  echo "  Status:   sudo ./install.sh --status"
  echo "  Cleanup:  safety net every 3 days (systemctl list-timers torrserver-cleanup.timer), dry run: ${TS_DIR}/cleanup.sh --dry-run"
  echo "  Uninstall: ./install.sh --uninstall   (add --purge to delete data)"
}

# ---------- status ----------

do_status() {
  [[ -f "$ENVF" ]] || { echo "TorrServer is not installed here (no ${ENVF})."; return 0; }
  local mode state vaddr n
  mode=$(env_get TS_MODE)
  if [[ -z "$mode" ]]; then mode=$([[ "$(env_get TS_PUBLIC)" == 1 ]] && echo public || echo local); fi
  state="not found"
  if command -v docker >/dev/null 2>&1 && container_exists torrserver; then
    state=$(docker inspect -f '{{.State.Status}}{{with .State.Health}} ({{.Status}}){{end}}' torrserver 2>/dev/null || echo unknown)
  fi
  echo "Mode:        ${mode}"
  case "$mode" in
    public)
      echo "URL:         https://$(env_get TS_HOSTNAME):$(env_get TS_PUBLIC_PORT)/"
      echo "Port:        TCP $(env_get TS_PUBLIC_PORT) (HTTPS), TCP $(env_get TS_HTTP_PORT) (certificate challenge + redirect)"
      echo "Public IP:   $(env_get PUBLIC_IP)" ;;
    vpn)
      vaddr=$(env_get TS_VPN_ADDR)
      echo "URL:         http://${vaddr}:$(env_get TS_HOST_PORT)/  (through the VPN)"
      echo "Port:        UDP $(env_get TS_VPN_PORT) (WireGuard ${TS_WG_IF}), endpoint $(env_get PUBLIC_IP)"
      echo "Devices:"
      if [[ -s "$(vpn_devices_file)" ]]; then awk '{ printf "  %-20s %s\n", $1, $2 }' "$(vpn_devices_file)"; else echo "  (none yet: sudo ./install.sh --add-device NAME)"; fi ;;
    *)
      echo "URL:         http://127.0.0.1:$(env_get TS_HOST_PORT)/  (SSH tunnel: ssh -L $(env_get TS_HOST_PORT):127.0.0.1:$(env_get TS_HOST_PORT) USER@SERVER)" ;;
  esac
  echo "Container:   ${state}"
  echo "Streaming:   RAM cache up to $(effective_cache_mb) MB, disk off, upload off"
  echo "Login:       sudo cat ${CREDS}"
  if [[ -s "$FWSTATE" ]]; then
    n=$(wc -l < "$FWSTATE")
    echo "Firewall:    ${n} rule(s) opened by this script: $(awk '{ printf "%s ", $3 }' "$FWSTATE")"
  fi
}

# ---------- uninstall ----------

# Refuse to purge anything that is not this script's own directory.
check_purge_target() {
  local d="${TS_DIR%/}"
  case "$d" in
    ""|/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/mnt|/media|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/*|/var|/var/lib|/var/log)
      die "refusing to purge '${TS_DIR}': it is a system path" ;;
  esac
  [[ -d "$d" && ! -L "$d" ]] || die "refusing to purge '${TS_DIR}': not a plain directory"
  grep -qE '^name: torrserver[[:space:]]*$' "${d}/docker-compose.yml" 2>/dev/null \
    || die "refusing to purge '${TS_DIR}': no docker-compose.yml with 'name: torrserver' (not installed by this script). Delete it by hand if you are sure."
}

do_uninstall() {
  local c
  if (( PURGE )); then check_purge_target; fi
  log "uninstalling TorrServer (data kept unless --purge)"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now torrserver-cleanup.timer >/dev/null 2>&1 || true
    systemctl stop torrserver-cleanup.service >/dev/null 2>&1 || true
  fi
  rm -f "${SYSTEMD_DIR}/torrserver-cleanup.service" "${SYSTEMD_DIR}/torrserver-cleanup.timer"
  if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload || true; fi

  if command -v docker >/dev/null 2>&1; then
    if [[ -f "${TS_DIR}/docker-compose.yml" ]]; then
      set_compose vpn   # includes the VPN overlay: harmless for `down`
      [[ -f "${TS_DIR}/docker-compose.vpn.yml" ]] || set_compose local
      # --profile "*" so the Caddy container is removed too, whatever mode was active.
      if (( PURGE )); then
        "${COMPOSE[@]}" --profile '*' down --remove-orphans --volumes || warn "compose down failed"
      else
        "${COMPOSE[@]}" --profile '*' down --remove-orphans || warn "compose down failed"
      fi
    fi
    # Leftovers only if they belong to this compose project; a container someone started by hand stays.
    for c in torrserver torrserver-caddy; do
      if container_exists "$c" && [[ "$(container_project "$c")" == torrserver ]]; then docker rm -f "$c" >/dev/null 2>&1 || true; fi
    done
  else
    warn "docker not found: containers not touched"
  fi

  vpn_teardown
  f2b_remove
  fw_reconcile

  if (( PURGE )); then
    rm -rf --one-file-system -- "${TS_DIR%/}"
    log "removed ${TS_DIR} (data, credentials, VPN keys, config)"
  else
    rm -f "${TS_DIR}/cleanup.sh" "${TS_DIR}/.firewall-added" "$CADDY_AUTH" "$CADDY_TLS"
    log "kept ${TS_DIR} (data/, credentials, .env, vpn/). Delete it with: ./install.sh --uninstall --purge"
  fi
  log "uninstalled"
}

case "$ACTION" in
  install) do_install ;;
  uninstall) do_uninstall ;;
  status) do_status ;;
  add-device) add_device ;;
  remove-device) remove_device ;;
esac
