#!/usr/bin/env bash
# Install TorrServer in Docker, hardened: HTTP login with a random password, localhost-only port,
# no seeding, downloads cleaned every 3 days. Idempotent: rerun it to apply changes.
# Needs Docker Engine with the compose plugin already installed. Run as root.
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
TS_HOST_PORT="${TS_HOST_PORT:-8090}"
TS_UID="${TS_UID:-10001}"
TS_GID="${TS_GID:-10001}"
TS_MEM_LIMIT="${TS_MEM_LIMIT:-3g}"
TS_MEM_RESERVATION="${TS_MEM_RESERVATION:-512m}"
TS_CPUS="${TS_CPUS:-2.0}"
TS_CACHE_MB="${TS_CACHE_MB:-2048}"          # disk cache budget per TorrServer (CacheSize)
TS_IDLE_SECONDS="${TS_IDLE_SECONDS:-120}"   # TorrentDisconnectTimeout: idle seconds before a torrent is closed
SYSTEMD_DIR="${TS_SYSTEMD_DIR:-/etc/systemd/system}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE=install        # install | uninstall
PURGE=0
ROTATE=0
PUBLIC=""           # "" = keep what .env says, 1 = --public, 0 = --private
NO_START=0
DOMAIN="${DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"

log() { echo "[$(date +%H:%M:%S)] $*"; }
warn() { echo "WARN: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  cat <<USAGE
Usage: sudo ./install.sh [options]

Installs TorrServer ${TS_VERSION} in Docker under ${TS_DIR}:
  - HTTP login (random password, kept in ${TS_DIR}/credentials, mode 0600, root only)
  - listens on 127.0.0.1:${TS_HOST_PORT} only (use an SSH tunnel)
  - no seeding (upload disabled), cache removed when a torrent is dropped
  - systemd timer: every 3 days drop torrents and delete downloads older than 3 days

Options:
  --public               also run a Caddy HTTPS reverse proxy on 80/443 (needs --domain and --acme-email)
  --private              go back to localhost only (removes Caddy and the firewall rules this script added)
  --domain NAME          public host name, A/AAAA record must point to this server (or env DOMAIN)
  --acme-email ADDR      e-mail for the certificate authority (or env ACME_EMAIL)
  --rotate-password      generate a new password, restart TorrServer, print it once
  --no-start             write files and units but do not start containers
  --uninstall            stop and remove the container, timer, firewall rules; keep data
  --purge                with --uninstall: also delete ${TS_DIR} (data, credentials) and Caddy volumes
  -h, --help             this text

Environment: TS_VERSION, TS_IMAGE_DIGEST, TS_HOST_PORT, TS_DIR, TS_MEM_LIMIT, TS_CPUS, TS_CACHE_MB,
TS_IDLE_SECONDS, DOMAIN, ACME_EMAIL. Details: README.md.
USAGE
}

while (($#)); do
  case "$1" in
    --public) PUBLIC=1 ;;
    --private) PUBLIC=0 ;;
    --domain) shift; DOMAIN="${1:-}" ;;
    --acme-email) shift; ACME_EMAIL="${1:-}" ;;
    --rotate-password) ROTATE=1 ;;
    --no-start) NO_START=1 ;;
    --uninstall) MODE=uninstall ;;
    --purge) PURGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "run as root (sudo ./install.sh)"
[[ "$TS_HOST_PORT" =~ ^[0-9]+$ && "$TS_HOST_PORT" -ge 1 && "$TS_HOST_PORT" -le 65535 ]] || die "TS_HOST_PORT must be a port number"
[[ "$TS_DIR" == /* && "$TS_DIR" != "/" ]] || die "TS_DIR must be an absolute path other than /"
[[ "$TS_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || die "TS_VERSION has unexpected characters"
[[ -z "$TS_IMAGE_DIGEST" || "$TS_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die "TS_IMAGE_DIGEST must look like sha256:<64 hex>"
[[ "$TS_CACHE_MB" =~ ^[0-9]+$ && "$TS_IDLE_SECONDS" =~ ^[0-9]+$ ]] || die "TS_CACHE_MB and TS_IDLE_SECONDS must be numbers"
(( PURGE == 0 )) || [[ "$MODE" == uninstall ]] || die "--purge only goes with --uninstall"

CREDS="${TS_DIR}/credentials"
ENVF="${TS_DIR}/.env"
DATA="${TS_DIR}/data"
FWSTATE="${TS_DIR}/.firewall-added"
COMPOSE=(docker compose --project-directory "$TS_DIR" -f "${TS_DIR}/docker-compose.yml")

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

# ---------- firewall (additive; SSH rules are never read for change or touched) ----------

fw_record() { printf '%s\n' "$1" >> "$FWSTATE"; chmod 600 "$FWSTATE"; }

fw_open() {
  local port
  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
    local zone; zone=$(firewall-cmd --get-default-zone)
    for port in 80/tcp 443/tcp; do
      if firewall-cmd --permanent --zone="$zone" --query-port="$port" >/dev/null 2>&1; then
        log "firewalld: ${port} already open in zone ${zone} (left as it is)"
      else
        # Runtime and permanent, no --reload: nothing else in the running config is touched.
        firewall-cmd -q --zone="$zone" --add-port="$port"
        firewall-cmd -q --permanent --zone="$zone" --add-port="$port"
        fw_record "firewalld ${zone} ${port}"
        log "firewalld: opened ${port} in zone ${zone}"
      fi
    done
  elif command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    for port in 80/tcp 443/tcp; do
      if ufw status | grep -qE "^${port}[[:space:]]+ALLOW"; then
        log "ufw: ${port} already allowed (left as it is)"
      else
        ufw allow "$port" comment 'torrserver caddy' >/dev/null
        fw_record "ufw - ${port}"
        log "ufw: allowed ${port}"
      fi
    done
  else
    log "no active firewalld or ufw found: nothing to open on the host. Check the Hetzner Cloud Firewall (TCP 80, 443)."
  fi
}

fw_close() {
  [[ -f "$FWSTATE" ]] || return 0
  local kind zone port
  while read -r kind zone port; do
    [[ -n "$kind" ]] || continue
    case "$kind" in
      firewalld)
        command -v firewall-cmd >/dev/null 2>&1 || continue
        firewall-cmd -q --zone="$zone" --remove-port="$port" 2>/dev/null || true
        firewall-cmd -q --permanent --zone="$zone" --remove-port="$port" 2>/dev/null || true
        log "firewalld: closed ${port} in zone ${zone} (opened by this script)" ;;
      ufw)
        command -v ufw >/dev/null 2>&1 || continue
        ufw delete allow "$port" >/dev/null 2>&1 || true
        log "ufw: removed allow ${port} (added by this script)" ;;
    esac
  done < "$FWSTATE"
  rm -f "$FWSTATE"
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

# Settings overrides. Names are fields of settings.BTSets (server/settings/btsets.go).
wanted_settings() {
  jq -n --argjson cache "$((TS_CACHE_MB * 1024 * 1024))" --argjson idle "$TS_IDLE_SECONDS" '{
    DisableUpload: true,
    UseDisk: true,
    TorrentsSavePath: "/opt/ts/downloads",
    RemoveCacheOnDrop: true,
    CacheSize: $cache,
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
  log "settings applied: no upload, disk cache with removal on drop, DLNA/UPnP/LPD/Bonjour off"
}

# ---------- install ----------

write_accs() { # accs.db: {"user":"password"}, readable by the container user only
  local user pass tmp
  user=$(grep -E '^TS_USER=' "$CREDS" | head -n1 | cut -d= -f2-)
  pass=$(grep -E '^TS_PASS=' "$CREDS" | head -n1 | cut -d= -f2-)
  tmp=$(mktemp "${DATA}/config/.accs.XXXXXX")
  jq -nc --arg u "$user" --arg p "$pass" '{($u):$p}' > "$tmp"
  chown "${TS_UID}:${TS_GID}" "$tmp"; chmod 600 "$tmp"
  if [[ -f "${DATA}/config/accs.db" ]] && cmp -s "$tmp" "${DATA}/config/accs.db"; then rm -f "$tmp"; return 1; fi
  mv "$tmp" "${DATA}/config/accs.db"
}

do_install() {
  local public_now domain_now email_now new_creds=0 changed_creds=0
  ensure_tools
  check_docker

  # Resolve public/private from flags, falling back to what an earlier run stored.
  if [[ -z "$PUBLIC" ]]; then PUBLIC=$([[ "$(env_get TS_PUBLIC)" == 1 ]] && echo 1 || echo 0); fi
  domain_now="${DOMAIN:-$(env_get DOMAIN)}"
  email_now="${ACME_EMAIL:-$(env_get ACME_EMAIL)}"
  public_now="$PUBLIC"
  if [[ "$public_now" == 1 ]]; then
    [[ -n "$domain_now" ]] || die "--public needs a domain: --domain host.example.com (or DOMAIN=...). Without TLS the login would cross the network in clear text."
    [[ -n "$email_now" ]] || die "--public needs --acme-email you@example.com (or ACME_EMAIL=...)"
    [[ "$domain_now" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$domain_now" == *.* ]] || die "DOMAIN '${domain_now}' is not a valid host name"
    [[ "$email_now" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "ACME_EMAIL '${email_now}' is not a valid address"
  fi

  log "installing TorrServer ${TS_VERSION} into ${TS_DIR}"
  install -d -m 0755 -o root -g root "$TS_DIR"
  install -d -m 0750 -o "$TS_UID" -g "$TS_GID" "$DATA" "${DATA}/config" "${DATA}/downloads" "${DATA}/torrents"

  install_file "${SRC}/docker-compose.yml" "${TS_DIR}/docker-compose.yml" 0644 || true
  install_file "${SRC}/Caddyfile" "${TS_DIR}/Caddyfile" 0644 || true
  install_file "${SRC}/cleanup.sh" "${TS_DIR}/cleanup.sh" 0750 || true

  # .env: managed keys are rewritten on every run, there are no secrets in it.
  [[ -f "$ENVF" ]] || { (umask 077; : > "$ENVF"); }
  chmod 600 "$ENVF"
  set_env TS_IMAGE "${TS_IMAGE_REPO}:${TS_VERSION}${TS_IMAGE_DIGEST:+@${TS_IMAGE_DIGEST}}"
  set_env TS_VERSION "$TS_VERSION"
  set_env TS_BIND 127.0.0.1
  set_env TS_HOST_PORT "$TS_HOST_PORT"
  set_env TS_UID "$TS_UID"
  set_env TS_GID "$TS_GID"
  set_env TS_MEM_LIMIT "$TS_MEM_LIMIT"
  set_env TS_MEM_RESERVATION "$TS_MEM_RESERVATION"
  set_env TS_CPUS "$TS_CPUS"
  set_env CADDY_IMAGE "$CADDY_IMAGE"
  set_env TS_PUBLIC "$public_now"
  set_env DOMAIN "$domain_now"
  set_env ACME_EMAIL "$email_now"
  set_env COMPOSE_PROFILES "$([[ "$public_now" == 1 ]] && echo public || echo "")"

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

  if (( NO_START )); then
    log "--no-start: files written, containers not started"
  else
    if ! "${COMPOSE[@]}" config -q; then die "docker compose config failed"; fi
    "${COMPOSE[@]}" pull -q >/dev/null 2>&1 || warn "image pull failed; using a local copy if present"
    # Going private: a profile that is no longer active is not an orphan, so remove Caddy explicitly.
    if [[ "$public_now" != 1 ]]; then "${COMPOSE[@]}" --profile public rm -sf caddy >/dev/null 2>&1 || true; fi
    # Credentials changed on a running container: it reads accs.db only at start.
    if (( changed_creds && ! new_creds )); then "${COMPOSE[@]}" up -d --remove-orphans --force-recreate; else "${COMPOSE[@]}" up -d --remove-orphans; fi
    wait_echo || die "TorrServer did not answer on 127.0.0.1:${TS_HOST_PORT} within 60 s (docker logs torrserver)"
    apply_settings
  fi

  # Firewall: open 80/443 for --public, close what we opened when going private again.
  if [[ "$public_now" == 1 ]]; then fw_open; else fw_close; fi

  install_cleanup_timer

  summary "$new_creds" "$changed_creds" "$public_now" "$domain_now"
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
  local new="$1" changed="$2" public="$3" domain="$4"
  echo
  echo "TorrServer ${TS_VERSION} is installed."
  if [[ "$public" == 1 ]]; then
    echo "  URL:      https://${domain}/   (Caddy, automatic certificate; needs DNS and ports 80/443 open)"
  else
    echo "  Listens:  127.0.0.1:${TS_HOST_PORT} only. From your laptop:"
    echo "            ssh -L ${TS_HOST_PORT}:127.0.0.1:${TS_HOST_PORT} USER@SERVER   then open http://127.0.0.1:${TS_HOST_PORT}/"
  fi
  if [[ "$new" == 1 || ( "$ROTATE" == 1 && "$changed" == 1 ) ]]; then
    echo
    echo "  Login (shown once; stored only in ${CREDS}, root 0600):"
    echo "    user:     $(grep -E '^TS_USER=' "$CREDS" | cut -d= -f2-)"
    echo "    password: $(grep -E '^TS_PASS=' "$CREDS" | cut -d= -f2-)"
  else
    echo "  Login:    unchanged, read it with: sudo cat ${CREDS}"
  fi
  echo "  Cleanup:  every 3 days (systemctl list-timers torrserver-cleanup.timer), dry run: ${TS_DIR}/cleanup.sh --dry-run"
  echo "  Uninstall: ./install.sh --uninstall   (add --purge to delete data)"
}

# ---------- uninstall ----------

do_uninstall() {
  log "uninstalling TorrServer (data kept unless --purge)"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now torrserver-cleanup.timer >/dev/null 2>&1 || true
    systemctl stop torrserver-cleanup.service >/dev/null 2>&1 || true
  fi
  rm -f "${SYSTEMD_DIR}/torrserver-cleanup.service" "${SYSTEMD_DIR}/torrserver-cleanup.timer"
  if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload || true; fi

  if command -v docker >/dev/null 2>&1; then
    if [[ -f "${TS_DIR}/docker-compose.yml" ]]; then
      # --profile "*" so the Caddy container is removed too, whatever mode was active.
      if (( PURGE )); then
        "${COMPOSE[@]}" --profile '*' down --remove-orphans --volumes || warn "compose down failed"
      else
        "${COMPOSE[@]}" --profile '*' down --remove-orphans || warn "compose down failed"
      fi
    fi
    docker rm -f torrserver torrserver-caddy >/dev/null 2>&1 || true
  else
    warn "docker not found: containers not touched"
  fi

  fw_close

  if (( PURGE )); then
    [[ "$TS_DIR" != "/" && -d "$TS_DIR" ]] && rm -rf --one-file-system -- "$TS_DIR"
    log "removed ${TS_DIR} (data, credentials, config)"
  else
    rm -f "${TS_DIR}/cleanup.sh" "${TS_DIR}/.firewall-added"
    log "kept ${TS_DIR} (data/, credentials, .env). Delete it with: ./install.sh --uninstall --purge"
  fi
  log "uninstalled"
}

case "$MODE" in
  install) do_install ;;
  uninstall) do_uninstall ;;
esac
