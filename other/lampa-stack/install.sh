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

MODE_PUBLIC=0
ENABLE_QBT_PORT=0
ACTION=install
TARGET_USER=""
PURGE=0
NO_START=0
NO_FIREWALL=0
NO_SYSTEMD="${LAMPA_STACK_NO_SYSTEMD:-0}"
ADMIN_USER="${ADMIN_USER:-admin}"
NEW_CREDS=()   # lines printed once at the end

log() { printf '\033[1;34m[lampa]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[lampa] WARN:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[lampa] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: $0 [options]

Installs or updates the Lampa stack in ${DIR} (override with LAMPA_STACK_DIR).
Default is local mode: one HTTPS port on 127.0.0.1 (reach it with an SSH tunnel), nothing public.

Modes
  (no option)          install or update, local/tunnel mode
  --public             public HTTPS: needs DOMAIN and ACME_EMAIL in the environment; opens 80/443
                       (additively, SSH rules are never touched). DNS for DOMAIN, ts.DOMAIN, qbt.DOMAIN
                       and auth.DOMAIN must point at this server.
  --enable-qbt-port    publish qBittorrent's peer port on 0.0.0.0 (tcp+udp) and open it in the host firewall.
                       Without it qBittorrent downloads but is not connectable (slower, fewer peers).
Users (each gets a login for the web UIs and a Lampac token for the TV; shown once)
  --add-user NAME      add a user
  --remove-user NAME   remove a user (login and token)
Maintenance
  --rotate-secrets     new session secret, TorrServer / qBittorrent / Lampac root passwords and all Lampac
                       tokens (everyone is logged out; new credentials are printed once). The Authelia
                       storage key is kept (it encrypts TOTP seeds); see README.
  --export-ca          local mode: write Caddy's local CA certificate to ${DIR}/caddy-local-root.crt (import it
                       into your browser/OS to remove the certificate warning)
  --status             show containers, published ports and settings checks
  --uninstall          stop the stack, remove the cleanup timer; KEEPS ${DIR}/data and secrets
  --purge              with --uninstall: also delete ${DIR} (data, secrets) and Docker volumes
Other
  --no-start           write all files but do not start containers
  --no-firewall        do not touch the host firewall
  -h, --help           this help

Environment: DOMAIN, ACME_EMAIL (public mode), ADMIN_USER (first user, default admin), TZ,
             LAMPA_STACK_DIR, LAMPA_STACK_NO_SYSTEMD=1 (skip the cleanup timer),
             LAMPA_STACK_SKIP_PULL=1 (use images already on the host; for testing).
Settings live in ${DIR}/.env (see .env.example); rerun this script after editing it.
USAGE
}

# ---------------------------------------------------------------- argument parsing
while (( $# )); do
  case "$1" in
    --public) MODE_PUBLIC=1 ;;
    --enable-qbt-port) ENABLE_QBT_PORT=1 ;;
    --add-user) ACTION=add-user; TARGET_USER="${2:-}"; [[ -n "$TARGET_USER" ]] || die "--add-user needs a name"; shift ;;
    --remove-user) ACTION=remove-user; TARGET_USER="${2:-}"; [[ -n "$TARGET_USER" ]] || die "--remove-user needs a name"; shift ;;
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

# ---------------------------------------------------------------- helpers
# Credentials are printed once. If a later step fails, still show the ones already created.
print_pending() {
  if (( ${#NEW_CREDS[@]} )); then
    echo "Credentials created before the failure (shown once):" >&2
    printf '  %s\n' "${NEW_CREDS[@]}" >&2
  fi
}
trap print_pending EXIT
[[ $EUID -eq 0 ]] || die "run as root (sudo $0 ...)"

dc() { docker compose --project-directory "$DIR" -p "$PROJECT" -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" "$@"; }

env_get() { [[ -f "$DIR/.env" ]] && grep -m1 "^$1=" "$DIR/.env" | cut -d= -f2- || true; }
env_set() { # KEY VALUE (value must not contain newline or '|')
  local k="$1" v="$2"
  if grep -q "^${k}=" "$DIR/.env"; then
    sed -i "s|^${k}=.*|${k}=${v}|" "$DIR/.env"
  else
    printf '%s=%s\n' "$k" "$v" >> "$DIR/.env"
  fi
}

rand_hex() { openssl rand -hex "$1"; }
rand_pw() { # 24 URL-safe alphanumerics from the CSPRNG
  local out=""
  while (( ${#out} < 24 )); do out+=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9'); done
  printf '%s' "${out:0:24}"
}

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
  [[ -n "${TZ:-}" ]] && env_set TZ "$TZ"
  if (( MODE_PUBLIC )); then
    [[ -n "${DOMAIN:-}" && -n "${ACME_EMAIL:-}" ]] || die "--public needs DOMAIN and ACME_EMAIL in the environment"
    [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$DOMAIN" == *.* ]] || die "invalid DOMAIN: ${DOMAIN}"
    [[ "$ACME_EMAIL" =~ ^[^[:space:]@|]+@[^[:space:]@|]+$ ]] || die "invalid ACME_EMAIL"
    env_set DOMAIN "$DOMAIN"; env_set ACME_EMAIL "$ACME_EMAIL"
    env_set SITE_PREFIX ""; env_set SITE_SUFFIX ""; env_set TLS_LINE ""
    env_set AUTH_URL_SCHEME https; env_set AUTH_URL_PORT ""
    env_set PUBLISH_HTTP "0.0.0.0:80:80"; env_set PUBLISH_HTTPS "0.0.0.0:443:443"
  elif [[ "$(env_get PUBLISH_HTTP)" == 0.0.0.0:* ]]; then
    log "keeping public mode from the previous run (DOMAIN=$(env_get DOMAIN)); to go back to local mode edit .env"
  fi
  if (( ENABLE_QBT_PORT )); then env_set QBT_PEER_BIND 0.0.0.0; fi
  local k v
  for k in STACK_UID QBT_WEBUI_PORT QBT_PORT TS_CACHE_MB; do
    v=$(env_get "$k"); [[ "$v" =~ ^[1-9][0-9]*$ ]] || die "invalid ${k} in .env: '${v}'"
  done
  [[ "$(env_get AUTHELIA_POLICY)" =~ ^(one_factor|two_factor)$ ]] || die "AUTHELIA_POLICY must be one_factor or two_factor"
  [[ "$(env_get QBT_MAX_RATIO)" =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "invalid QBT_MAX_RATIO"
  [[ "$(env_get QBT_MAX_SEED_MINUTES)" =~ ^[0-9]+$ ]] || die "invalid QBT_MAX_SEED_MINUTES"
  [[ "$(env_get QBT_DELETE_COMPLETED_DAYS)" =~ ^[0-9]+$ ]] || die "invalid QBT_DELETE_COMPLETED_DAYS"
  [[ "$(env_get QBT_USER)" =~ ^[A-Za-z][A-Za-z0-9_]{1,31}$ ]] || die "invalid QBT_USER"
  [[ "$(env_get LAMPA_AUTOUPDATE)" =~ ^(true|false)$ ]] || die "LAMPA_AUTOUPDATE must be true or false"
  [[ "$(env_get LAMPA_TREE)" =~ ^[0-9a-f]{40}$ ]] || die "LAMPA_TREE must be a 40-character git commit id"
  # The peer port is opened in the host firewall: never a system port, never the SSH port.
  v=$(env_get QBT_PORT)
  (( v >= 1024 && v <= 65535 )) || die "QBT_PORT must be 1024-65535 (got ${v})"
  local sp
  for sp in 22 $(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}') $(ss -Hltnp 2>/dev/null | awk '/sshd/ {n=split($4,a,":"); print a[n]}'); do
    [[ "$v" != "$sp" ]] || die "QBT_PORT ${v} is the SSH port"
  done
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

# secrets/users.tsv: name <TAB> lampac token <TAB> argon2id hash   (0600)
users_file() { printf '%s' "$DIR/secrets/users.tsv"; }
valid_name() { [[ "$1" =~ ^[a-z][a-z0-9_-]{1,31}$ ]]; }

argon2_pair() { # prints "<password> <hash>" for a fresh random password (password never in argv)
  local out pw hash
  out=$(docker run --rm --network none "$(env_get AUTHELIA_IMAGE)" authelia crypto hash generate argon2 --memory 32768 \
    --random --random.length 24 --random.charset alphanumeric 2>/dev/null) || die "could not generate argon2id hash (is the Authelia image pulled?)"
  pw=$(sed -n 's/^Random Password: //p' <<<"$out")
  hash=$(sed -n 's/^Digest: //p' <<<"$out")
  [[ -n "$pw" && "$hash" == '$argon2id$'* ]] || die "unexpected authelia hash output"
  printf '%s %s' "$pw" "$hash"
}

add_user_record() { # name ; appends to users.tsv, prints credentials once
  local name="$1" pw hash token pair
  valid_name "$name" || die "user name must be 2-32 chars of a-z 0-9 _ - (starting with a letter)"
  touch "$(users_file)"; chmod 0600 "$(users_file)"
  if cut -f1 "$(users_file)" | grep -qx "$name"; then die "user ${name} already exists"; fi
  pair=$(argon2_pair); pw="${pair%% *}"; hash="${pair#* }"
  token=$(rand_hex 16)
  printf '%s\t%s\t%s\n' "$name" "$token" "$hash" >> "$(users_file)"
  NEW_CREDS+=("user ${name}: password ${pw}   Lampa token ${token}")
}

render_users() {
  local f name token hash first=1
  f="$(users_file)"
  [[ -f "$f" ]] || return 0
  { echo "# Rendered by install.sh from secrets/users.tsv. Do not edit; use --add-user / --remove-user."
    echo "users:"
    while IFS=$'\t' read -r name token hash; do
      [[ -n "$name" ]] || continue
      printf "  %s:\n    disabled: false\n    displayname: '%s'\n    password: '%s'\n    email: '%s@lampa.invalid'\n    groups: []\n" "$name" "$name" "$hash" "$name"
    done < "$f"
  } > "$DIR/authelia/users.yml.new"
  chmod 0600 "$DIR/authelia/users.yml.new"
  # Authelia watches the file; replace atomically.
  mv -f "$DIR/authelia/users.yml.new" "$DIR/authelia/users.yml"
  # Lampac accsdb users (hot-reloaded). Written in place so the single-file bind mount keeps its inode.
  { echo "["
    while IFS=$'\t' read -r name token hash; do
      [[ -n "$name" ]] || continue
      (( first )) || echo ","
      first=0
      printf '  {"id": "%s", "expires": "2099-12-31T00:00:00", "comment": "%s"}' "$token" "$name"
    done < "$f"
    echo
    echo "]"
  } > "$DIR/lampac/users.json.new"
  cat "$DIR/lampac/users.json.new" > "$DIR/lampac/users.json"; rm -f "$DIR/lampac/users.json.new"
  # The tokens are the only credential on the public Lampac API: root and the Lampac uid (group) only.
  chown root:1000 "$DIR/lampac/users.json"; chmod 0640 "$DIR/lampac/users.json"
}

render_authelia() {
  local domain port scheme
  domain=$(env_get DOMAIN); scheme=$(env_get AUTH_URL_SCHEME); port=$(env_get AUTH_URL_PORT)
  sed -e "s|@@DOMAIN@@|${domain}|g" \
      -e "s|@@POLICY@@|$(env_get AUTHELIA_POLICY)|g" \
      -e "s|@@AUTH_URL@@|${scheme}://auth.${domain}${port}|g" \
      -e "s|@@MAIN_URL@@|${scheme}://${domain}${port}|g" \
      "$DIR/authelia/configuration.yml.tmpl" > "$DIR/authelia/configuration.yml"
  chmod 0644 "$DIR/authelia/configuration.yml"
}

render_lampac() {
  local f="$DIR/lampac/init.conf"
  # Lampac accsdb on; users from users.json (one token per person). The embedded TorrServer, WebLog, DLNA and
  # other modules are skipped (we run a separate TorrServer). Modules whose endpoints are anonymous by design
  # (relays to cub.red / TMDB, media proxies, device binding, Telegram login, Kit, WatchTogether, ForkPlayer,
  # MSX) are skipped too: this host is open to the internet without a login portal in front of it.
  # scheme is "https" because Caddy always terminates TLS and Lampac sees plain HTTP from it; it builds every
  # link it hands out (lampainit.js, online/lite, plugin URLs carrying the token) from this value.
  cat > "$f" <<CONF
{
  "listen": { "ip": "0.0.0.0", "port": 9118, "scheme": "https", "localhost": "127.0.0.1", "version": true },
  "lowMemoryMode": true,
  "BaseModule": {
    "NotCheckLocalIp": true,
    "SkipModules": ["AdminPanel", "Catalog", "CorsMedia", "Corseu", "CubProxy", "DLNA", "ExternalBind", "ForkPlayerXML", "JacRed", "Kit", "MsxNative", "Sync", "TelegramAuth", "TelegramAuthBot", "TimeCode", "TmdbProxy", "TorrServer", "Tracks", "Transcoding", "WatchTogether", "WebLog"]
  },
  "accsdb": {
    "enable": true,
    "authMesage": "Personal access only. Ask the owner for your link.",
    "denyMesage": "Access denied."
  },
  "LampaWeb": { "autoupdate": $(env_get LAMPA_AUTOUPDATE), "tree": "$(env_get LAMPA_TREE)" },
  "chromium": { "enable": true, "executablePath": "/usr/bin/chromium" },
  "openstat": { "enable": false },
  "online": { "name": "Lampac", "version": true }
}
CONF
  chown root:1000 "$f"; chmod 0640 "$f"
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
    NEW_CREDS+=("TorrServer (Lampa TV, Settings > TorrServer): login ${user}  password $(cat "$f")")
  fi
  # TorrServer reads accs.db as JSON {"user":"password"} from its config dir.
  ( umask 077; printf '{"%s":"%s"}\n' "$user" "$(cat "$f")" > "$DIR/data/torrserver/config/accs.db" )
  chown "$uid:$uid" "$DIR/data/torrserver/config/accs.db"; chmod 0600 "$DIR/data/torrserver/config/accs.db"
  # base64(user:password): Caddy compares the TV's Authorization header with it and injects it for browsers
  # that passed Authelia. Mounted as a Docker secret file (no trailing newline), never an environment variable.
  ( umask 077; printf '%s:%s' "$user" "$(cat "$f")" | base64 -w0 > "$DIR/secrets/ts_basic" )
  rm -f "$DIR/secrets/caddy.env"   # older versions kept the credential here, as an environment file
}

# qBittorrent.conf pre-seed: PBKDF2-HMAC-SHA512, 100000 iterations, 16-byte salt, 64-byte key
# (format of WebUI\Password_PBKDF2 = "@ByteArray(<b64 salt>:<b64 key>)"; qBittorrent source: src/base/utils/password.cpp).
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
# Keys are the Go field names of BTSets (server/settings/btsets.go has no json tags). The credential goes to
# the container on stdin, not on a command line.
ts_post() { # json body -> stdout
  ts_basic | dc exec -T torrserver sh -c 'H=$(cat); wget -qO- --header "Authorization: $H" --header "Content-Type: application/json" --post-data "$1" http://127.0.0.1:8090/settings' sh "$1"
}

apply_torrserver() {
  local cur new cache_bytes k v want
  cache_bytes=$(( $(env_get TS_CACHE_MB) * 1024 * 1024 ))
  cur=$(ts_post '{"action":"get"}') || { warn "TorrServer settings: API not reachable"; return 1; }
  [[ "$cur" == \{* ]] || { warn "TorrServer settings: unexpected reply"; return 1; }
  new="$cur"
  want="DisableUpload=true RemoveCacheOnDrop=true UseDisk=false EnableDLNA=false CacheSize=${cache_bytes}"
  for kv in $want; do
    k="${kv%%=*}"; v="${kv#*=}"
    grep -qE "\"${k}\":(true|false|-?[0-9]+)" <<<"$new" || { warn "TorrServer settings: key ${k} not in reply (version changed?)"; return 1; }
    new=$(sed -E "s/\"${k}\":(true|false|-?[0-9]+)/\"${k}\":${v}/" <<<"$new")
  done
  ts_post "{\"action\":\"set\",\"sets\":${new}}" >/dev/null || { warn "TorrServer settings: set failed"; return 1; }
  cur=$(ts_post '{"action":"get"}')
  for kv in $want; do
    k="${kv%%=*}"; v="${kv#*=}"
    grep -q "\"${k}\":${v}" <<<"$cur" || { warn "TorrServer setting ${k} did not stick"; return 1; }
  done
  log "TorrServer: upload disabled, cache removed on drop, RAM cache $(env_get TS_CACHE_MB) MB"
}

qbt_exec() { dc exec -T qbittorrent "$@"; }

qbt_login_code() { # user password -> prints the HTTP status of /auth/login (5.3.0: 204 = logged in, 401 = refused)
  printf 'username=%s&password=%s' "$1" "$2" | qbt_exec curl -sS -o /dev/null -w '%{http_code}' --max-time 10 -c /tmp/lampa.cj -d @- "http://127.0.0.1:$(env_get QBT_WEBUI_PORT)/api/v2/auth/login"
}

apply_qbt() {
  local port pw json
  port=$(env_get QBT_WEBUI_PORT); pw=$(cat "$DIR/secrets/qbt_password")
  [[ "$(qbt_login_code "$(env_get QBT_USER)" "$pw")" == 204 ]] || { warn "qBittorrent: login with the generated password failed"; return 1; }
  json=$(printf '{"max_ratio_enabled":true,"max_ratio":%s,"max_seeding_time_enabled":true,"max_seeding_time":%s,"max_ratio_act":0,"listen_port":%s,"upnp":false,"save_path":"/downloads","web_ui_clickjacking_protection_enabled":true,"web_ui_csrf_protection_enabled":true,"web_ui_host_header_validation_enabled":false,"web_ui_reverse_proxy_enabled":true,"web_ui_reverse_proxies_list":"%s","web_ui_domain_list":"%s"}' \
    "$(env_get QBT_MAX_RATIO)" "$(env_get QBT_MAX_SEED_MINUTES)" "$(env_get QBT_PORT)" "$QBT_TRUSTED_PROXIES" "qbt.$(env_get DOMAIN);qbt.$(env_get DOMAIN)$(env_get AUTH_URL_PORT);localhost;127.0.0.1")
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
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    # Record only the rules this script adds: --uninstall must not remove a rule the operator already had.
    for p in "$@"; do
      if ufw status 2>/dev/null | grep -Eq "^${p}[[:space:]]+ALLOW"; then
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

# ---------------------------------------------------------------- summary
urls() {
  local d p s; d=$(env_get DOMAIN); p=$(env_get AUTH_URL_PORT); s=$(env_get AUTH_URL_SCHEME)
  MAIN_URL="${s}://${d}${p}"; TS_URL="${s}://ts.${d}${p}"; QBT_URL="${s}://qbt.${d}${p}"; AUTH_URL="${s}://auth.${d}${p}"
}

print_summary() {
  urls
  local pub=0; [[ "$(env_get PUBLISH_HTTP)" == 0.0.0.0:* ]] && pub=1
  echo
  echo "================ Lampa stack ================"
  if (( pub )); then
    echo "Public mode. Lampa / Lampac: ${MAIN_URL}   TorrServer: ${TS_URL}   qBittorrent: ${QBT_URL}   Login: ${AUTH_URL}"
  else
    echo "Local mode (nothing public). On your laptop:"
    echo "  ssh -N -L 8443:127.0.0.1:8443 <you>@<this-server>"
    echo "then open ${MAIN_URL}  (TorrServer ${TS_URL}, qBittorrent ${QBT_URL}, login ${AUTH_URL})."
    echo "Browsers map *.localhost to 127.0.0.1 by themselves; a TV cannot use a tunnel: use --public for it."
  fi
  if (( ${#NEW_CREDS[@]} )); then
    echo
    echo "Credentials (shown ONCE; stored only as hashes / in ${DIR}/secrets, root 0600):"
    local c; for c in "${NEW_CREDS[@]}"; do echo "  $c"; done
    NEW_CREDS=()
    echo
    echo "Lampa on the TV: open ${MAIN_URL}/ and enter the Lampa token when asked, or add the plugin ${MAIN_URL}/on/js/<Lampa token> (README: Connect Lampa)"
  fi
  echo "Status: $0 --status      Docs: ${DIR}/README.md"
  echo "============================================="
}

# ---------------------------------------------------------------- actions
do_install() {
  check_os; check_docker; selinux_note
  install_files
  ensure_env
  install_files   # again: STACK_UID may have been read from a pre-existing .env
  gen_secret authelia_jwt 32 || true
  gen_secret authelia_session 32 || true
  gen_secret authelia_storage 32 || true
  if [[ ! -s "$(users_file)" ]]; then add_user_record "$ADMIN_USER"; fi
  render_users; render_authelia; render_lampac
  render_torrserver_auth
  seed_qbt
  dc config -q || die "docker compose config failed"
  if (( NO_START )); then log "--no-start: files written, containers not started"; print_summary; return 0; fi
  if [[ "${LAMPA_STACK_SKIP_PULL:-0}" != 1 ]]; then
    log "pulling images (pinned tags + digests)"
    dc pull --quiet || die "image pull failed"
  fi
  dc up -d --remove-orphans
  wait_healthy || die "services did not become healthy; see: docker compose -p ${PROJECT} logs"
  apply_torrserver || warn "TorrServer settings not applied; rerun $0 once the container is up"
  apply_qbt || warn "qBittorrent settings not applied"
  local ports=()
  if [[ "$(env_get PUBLISH_HTTP)" == 0.0.0.0:* ]]; then ports+=(80/tcp 443/tcp); fi
  if [[ "$(env_get QBT_PEER_BIND)" == 0.0.0.0 ]]; then ports+=("$(env_get QBT_PORT)/tcp" "$(env_get QBT_PORT)/udp"); fi
  (( ${#ports[@]} )) && fw_open "${ports[@]}"
  install_timer
  print_summary
}

do_add_user() {
  check_docker; [[ -f "$DIR/.env" ]] || die "not installed; run $0 first"
  add_user_record "$TARGET_USER"; render_users; print_summary
}

do_remove_user() {
  [[ -s "$(users_file)" ]] || die "no users"
  cut -f1 "$(users_file)" | grep -qx "$TARGET_USER" || die "no such user: ${TARGET_USER}"
  [[ $(wc -l < "$(users_file)") -gt 1 ]] || die "refusing to remove the last user"
  awk -F'\t' -v n="$TARGET_USER" '$1 != n' "$(users_file)" > "$(users_file).new"
  chmod 0600 "$(users_file).new"; mv -f "$(users_file).new" "$(users_file)"
  render_users
  # Lampac only ever adds users from users.json while running; it forgets a removed one on restart.
  dc restart authelia lampac >/dev/null 2>&1 || warn "could not restart authelia/lampac: the removed token works until Lampac restarts"
  log "removed ${TARGET_USER}: login and Lampa token no longer valid (authelia and lampac were restarted, so existing sessions ended)"
}

do_rotate() {
  check_docker; [[ -f "$DIR/.env" ]] || die "not installed; run $0 first"
  local f name token hash pair pw tmp
  ( umask 077; rand_hex 32 > "$DIR/secrets/authelia_session"; rand_hex 32 > "$DIR/secrets/authelia_jwt"
    rand_pw > "$DIR/secrets/ts_password"; rand_pw > "$DIR/secrets/qbt_password" )
  NEW_CREDS+=("TorrServer: login lampa  password $(cat "$DIR/secrets/ts_password")")
  rm -f "$DIR/lampac/passwd"; ( umask 077; rand_pw > "$DIR/lampac/passwd" ); chown 1000:1000 "$DIR/lampac/passwd"; chmod 0400 "$DIR/lampac/passwd"
  f="$(users_file)"; tmp="${f}.new"; : > "$tmp"; chmod 0600 "$tmp"
  while IFS=$'\t' read -r name token hash; do
    [[ -n "$name" ]] || continue
    pair=$(argon2_pair); pw="${pair%% *}"; hash="${pair#* }"; token=$(rand_hex 16)
    printf '%s\t%s\t%s\n' "$name" "$token" "$hash" >> "$tmp"
    NEW_CREDS+=("user ${name}: password ${pw}   Lampa token ${token}")
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
  check_docker; [[ -f "$DIR/.env" ]] || die "not installed; run $0 first"
  dc cp caddy:/data/caddy/pki/authorities/local/root.crt "$DIR/caddy-local-root.crt" || die "no local CA yet (public mode, or Caddy has not issued a certificate)"
  log "wrote ${DIR}/caddy-local-root.crt; copy it to your laptop and trust it for https://*.$(env_get DOMAIN)"
}

do_status() {
  check_docker; [[ -f "$DIR/.env" ]] || die "not installed; run $0 first"
  dc ps
  echo
  echo "Published host ports (expected: only Caddy; qBittorrent peer port on 127.0.0.1 unless enabled):"
  docker ps --filter "label=com.docker.compose.project=${PROJECT}" --format '  {{.Names}}  {{.Ports}}'
  echo
  if docker ps --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Ports}}' | grep -o '0\.0\.0\.0:[0-9]*' | sort -u | grep -qv ':\(80\|443\|'"$(env_get QBT_PORT)"'\)$'; then
    warn "unexpected public port(s) above"
  fi
  [[ -f "$DIR/secrets/ts_password" ]] && { apply_torrserver_check || true; }
  [[ -f "$DIR/secrets/qbt_password" ]] && { qbt_check || true; }
  systemctl list-timers lampa-stack-cleanup.timer --no-pager 2>/dev/null | head -3 || true
}
apply_torrserver_check() {
  local cur; cur=$(ts_post '{"action":"get"}' 2>/dev/null) || { echo "TorrServer: API not reachable"; return 1; }
  for k in DisableUpload RemoveCacheOnDrop; do grep -q "\"${k}\":true" <<<"$cur" && echo "TorrServer ${k}: true" || echo "TorrServer ${k}: NOT set"; done
}
qbt_check() {
  [[ "$(qbt_login_code "$(env_get QBT_USER)" "$(cat "$DIR/secrets/qbt_password")" 2>/dev/null)" == 204 ]] && echo "qBittorrent: generated password works" || echo "qBittorrent: login FAILED"
  [[ "$(qbt_login_code "$(env_get QBT_USER)" adminadmin 2>/dev/null)" == 204 ]] && echo "qBittorrent: DEFAULT PASSWORD ACCEPTED" || echo "qBittorrent: default password rejected"
}

do_uninstall() {
  check_docker
  if [[ -f "$DIR/docker-compose.yml" && -f "$DIR/.env" ]]; then
    if (( PURGE )); then dc down -v --remove-orphans || true; else dc down --remove-orphans || true; fi
  fi
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl disable --now lampa-stack-cleanup.timer >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/lampa-stack-cleanup.service" "$UNIT_DIR/lampa-stack-cleanup.timer"
    systemctl daemon-reload || true
  fi
  fw_close_recorded
  if (( PURGE )); then
    [[ "$DIR" != / && "$DIR" == /* && -d "$DIR" ]] || die "refusing to delete '${DIR}'"
    rm -rf --one-file-system "$DIR"
    log "purged ${DIR}"
  else
    log "stack stopped. Data and secrets kept in ${DIR}; use --uninstall --purge to delete them"
  fi
}

case "$ACTION" in
  install) do_install ;;
  add-user) do_add_user ;;
  remove-user) do_remove_user ;;
  rotate) do_rotate ;;
  status) do_status ;;
  export-ca) do_export_ca ;;
  uninstall) do_uninstall ;;
esac
