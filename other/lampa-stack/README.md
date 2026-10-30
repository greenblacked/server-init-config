# Lampa stack

Everything to watch and download from your own server, behind one login:

| Part | What it does | Image (pinned in `.env`) |
|---|---|---|
| **Lampa** | The TV / set-top-box interface. There is no usable standalone Lampa image (see [Why no Lampa container](#why-there-is-no-separate-lampa-container)); Lampac serves it. | part of Lampac |
| **Lampac** | Backend that aggregates online sources and parsers, and serves the Lampa web app. | `ghcr.io/lampac-nextgen/lampac` |
| **TorrServer** | Streams torrents to Lampa. **No seeding.** | `ghcr.io/yourok/torrserver` |
| **qBittorrent** | Full torrent client: download **and** seed. | `lscr.io/linuxserver/qbittorrent` |
| **Authelia** | Login portal (password, optional TOTP) in front of every browser UI. | `authelia/authelia` |
| **Caddy** | The only entry point: TLS, routing, forward auth. | `caddy` |

Use only sources and content you have the right to access. Some online sources and parsers may not be
licensed in your country. You, the operator, are responsible.

## Quick start

Local / tunnel mode (nothing public; fits a 4 GB Hetzner server). Docker with the compose plugin must be installed.

```bash
git clone <this repo> && cd server-init-config/other/lampa-stack
sudo ./install.sh                         # generates secrets, starts the stack, prints credentials ONCE
ssh -N -L 8443:127.0.0.1:8443 you@server  # on your laptop; then open https://lampa.localhost:8443
```

Your browser warns once per host name because Caddy signs with its own local CA (Authelia refuses plain
HTTP). Either click through, or trust the CA: `sudo ./install.sh --export-ca`, copy
`/opt/lampa-stack/caddy-local-root.crt` to your laptop and import it as a trusted root.
Browsers resolve `*.localhost` to 127.0.0.1 by themselves, so `ts.lampa.localhost`, `qbt.lampa.localhost` and
`auth.lampa.localhost` work through the same tunnel port.

A TV cannot use an SSH tunnel. For the TV use **public mode**:

```bash
# DNS first: DOMAIN, ts.DOMAIN, qbt.DOMAIN and auth.DOMAIN -> this server
sudo DOMAIN=lampa.example.org ACME_EMAIL=you@example.org ./install.sh --public
```

Public mode publishes 80/443 on 0.0.0.0 (Let's Encrypt certificates), opens them in ufw/firewalld additively
(SSH rules are never touched; a firewalld zone without SSH is left alone) and keeps everything else private.
With a cloud firewall (Hetzner) also allow 80/443 there.
Optional: `--enable-qbt-port` publishes qBittorrent's peer port (see below).

The installer lives in `/opt/lampa-stack` (override with `LAMPA_STACK_DIR`). Rerunning it is safe.

## Why Authelia (the auth choice)

Candidates for "JWT/session login in front of every web UI" on a 4 GB host:

* **Authelia** (chosen). One ~40 MB Go binary, about 30-100 MB RAM, SQLite storage, no database server.
  Forward-auth works with Caddy out of the box, passwords are argon2id, optional TOTP, brute-force regulation,
  secrets can be read from files (`*_FILE`). Official image, no custom build.
* caddy-security / authcrunch: also light and JWT-native, but it needs a custom Caddy build (xcaddy) that you
  would have to rebuild and re-pin on every Caddy update.
* oauth2-proxy: needs an external identity provider; nothing to log in with on a single server.

Honest note on "JWT": Authelia gives the browser a signed **session cookie** (server-side session), not a bearer
JWT. It uses JWTs for its identity-verification and password-reset links (`jwt_secret`). If you need real JWT
bearer tokens or OIDC for third-party apps, Authelia can also act as an OIDC provider; this stack does not enable it.

## Which path is protected how

| Host / path | Protection | Why |
|---|---|---|
| `auth.DOMAIN` | the login page itself (public by nature; 5 failed logins ban for 10 min) | Authelia portal |
| `ts.DOMAIN` (TorrServer UI + API), browser | Authelia session; Caddy then adds TorrServer's own credential | one login, not two |
| `ts.DOMAIN`, request with `Authorization: Basic` (Lampa on the TV) | TorrServer's own HTTP Basic auth (`TS_HTTPAUTH`, checked on every API route). `/swagger` is blocked, `/echo` (version) is public. | the TV sends Basic from Lampa's settings and cannot follow a login redirect |
| `qbt.DOMAIN` | Authelia session, then qBittorrent's own login (generated password) | two independent logins |
| `DOMAIN/` (Lampa app) and the Lampac client API (`/online*`, `/lite*`, `/lampainit.js`, `/on/*`, `/sisi*`, `/extensions`, `/testaccsdb`, `/proxy*` ...) | Lampac `accsdb`: a valid per-user token is required, otherwise Lampac answers with a deny. Caddy does not check the token. The page shell is static and exposes no controls. | the Lampa client must work without a browser login |
| `DOMAIN/admin*`, `/adminpanel*`, `/stats*`, `/weblog*`, `/ts*`, `/dlna*` | blocked by Caddy (404) in every mode, case-insensitive | Lampac control surfaces; edit `init.conf` on the host instead |
| request headers `lcrqpasswd`, `x-client-ip` | stripped by Caddy on every host | `lcrqpasswd` is Lampac's local-admin bypass |
| Lampac `:9118`, Authelia `:9091`, TorrServer `:8090`, qBittorrent WebUI | not published; only reachable inside the internal compose network | |

Lampac sees Caddy's address for every client (it only honours `X-Forwarded-For` behind Cloudflare), so its
per-IP limits (`accsdb.maxip_hour`) count the proxy as one client. Leave them at their defaults.

What was and was not tested is listed in [Verification status](#verification-status).

## Connect Lampa on the TV

Print or reset credentials with `sudo ./install.sh --add-user NAME` (shown once) or `--rotate-secrets`.

1. In the TV's browser / the Lampa app, open `https://DOMAIN/`. When Lampac asks for access, enter your **Lampa
   token** (the long hex string printed for your user). You can also add the plugin
   `https://DOMAIN/on/js/<token>` in Lampa under *Settings > Extensions*. (Exact TV flow: see Verification status.)
2. *Settings > TorrServer*: URL `https://ts.DOMAIN`, login `lampa`, password = the TorrServer password from the
   install output. Lampa sends it as HTTP Basic.
3. For Samsung / LG TVs Lampac also serves packages at `https://DOMAIN/samsung.wgt` and `/lg.ipk`; they sit under
   the same token check.

Local mode is for the browser UIs only (TorrServer and qBittorrent pages, Lampa in your laptop browser).

## qBittorrent

* Web UI at `qbt.DOMAIN` after the Authelia login, user `admin`. The password is generated; the temporary
  first-run password never exists because the config is pre-seeded with a PBKDF2 hash (the installer then checks
  that `adminadmin` is refused).
* Seeding limits (paused, never deleted): ratio `QBT_MAX_RATIO` (default 2.0) **or** `QBT_MAX_SEED_MINUTES`
  (default 10080 = 7 days). Change them in `.env` and rerun `install.sh`.
* Downloads land in `/opt/lampa-stack/data/qbt/downloads`. Nothing is deleted automatically. Optional:
  `QBT_DELETE_COMPLETED_DAYS=30` makes the cleanup timer delete **files** older than 30 days there (this also
  stops seeding them; leave it at 0 if you want to seed).
* **Peer port** (`QBT_PORT`, default 6881, TCP+UDP) is the only port besides 80/443 that can be public. By default
  it is bound to 127.0.0.1, so peers cannot connect in: downloads still work, but you are not connectable and
  seeding is poor. `sudo ./install.sh --enable-qbt-port` binds it to 0.0.0.0 and opens it additively in
  ufw/firewalld. Open it in the Hetzner firewall too. UPnP is off.

## TorrServer (no seeding)

`install.sh` sets these through TorrServer's own `/settings` API (keys are the Go field names in
`server/settings/btsets.go`): `DisableUpload=true`, `RemoveCacheOnDrop=true`, `UseDisk=false` (RAM cache of
`TS_CACHE_MB`, default 192), `EnableDLNA=false`, and checks them again afterwards (`--status` re-checks).
Every 3 days `lampa-stack-cleanup.timer` empties `data/torrserver/cache` and `data/torrserver/torrents`; it never
touches `data/torrserver/config` (settings, `accs.db`, viewed history), secrets or any other service's data.
Preview: `sudo /opt/lampa-stack/scripts/cleanup.sh --dry-run`.

## Settings (`/opt/lampa-stack/.env`)

Edit, then run `sudo ./install.sh` again. Existing values are kept when a new version adds keys.

| Key | Default | Meaning |
|---|---|---|
| `*_IMAGE` | pinned tag + digest | image of each service; change to update |
| `DOMAIN`, `ACME_EMAIL` | `lampa.localhost` | set by `--public` |
| `AUTHELIA_POLICY` | `one_factor` | `two_factor` adds TOTP (register a device on first login) |
| `LAMPA_AUTOUPDATE` | `false` | let Lampac's LampaWeb pull Lampa from GitHub every 90 min (a runtime download; off keeps the stack reproducible) |
| `TS_CACHE_MB` | 192 | TorrServer RAM cache |
| `QBT_USER`, `QBT_WEBUI_PORT`, `QBT_PORT` | admin, 8085, 6881 | qBittorrent |
| `QBT_PEER_BIND` | `127.0.0.1` | `0.0.0.0` only via `--enable-qbt-port` |
| `QBT_MAX_RATIO`, `QBT_MAX_SEED_MINUTES` | 2.0, 10080 | seeding limits |
| `QBT_DELETE_COMPLETED_DAYS` | 0 | optional old-download cleanup |
| `*_MEM`, `LAMPAC_SHM` | see below | container memory limits |
| `LAMPAC_READ_ONLY` | `false` | try a read-only Lampac root filesystem |
| `STACK_UID` | 10000 | uid of TorrServer / qBittorrent and of their data |

Secrets are never in `.env` or the compose file: they live in `/opt/lampa-stack/secrets/` (root, 0600) and are
handed to Authelia as Docker secrets (`*_FILE`). Users: `--add-user NAME`, `--remove-user NAME` (login and token).
`--rotate-secrets` replaces the session secret, TorrServer/qBittorrent/Lampac passwords, every user's password and
Lampa token (all sessions end; new credentials are printed once). The Authelia storage key is kept because it
encrypts TOTP seeds; to change it use Authelia's `storage encryption change-key`.

## Hardening and memory budget

All containers: `no-new-privileges`, `cap_drop: ALL` (adds back only `NET_BIND_SERVICE` for Caddy and
`CHOWN SETUID SETGID DAC_OVERRIDE FOWNER` for the linuxserver image's s6 init), `pids_limit`, `mem_limit` and `cpus`
(service-level keys that compose v2 applies), json-file log rotation (10 MB x 3), healthchecks, SELinux `:z`
labels on bind mounts. Read-only root filesystems: Caddy, TorrServer. Not read-only: qBittorrent (s6 needs
`/run` and `/config`), Authelia (4.39.28 exited at its startup checks with `read_only`, cause not logged) and
Lampac (not verified). Networks: `backend` is `internal: true` (no route out); only Lampac (sources),
TorrServer and qBittorrent (peers/trackers) and Caddy (ACME) are also on `egress`.

| Service | Limit | Typical (estimate, not measured) |
|---|---|---|
| Lampac (+ Chromium for some sources) | 1024m | ~400m |
| qBittorrent | 512m | 150-300m |
| TorrServer | 512m | RAM cache + ~100m |
| Authelia | 256m | ~60m (argon2id uses 32 MiB per login) |
| Caddy | 96m | ~30m |
| **Sum of limits** | **2.4 GB** | leaves about 1.6 GB for the OS, page cache and Docker on a 4 GB host |

## Day-two

* **Status**: `sudo ./install.sh --status` (containers, published ports, TorrServer and qBittorrent checks).
  After install, `sudo tests/smoke.sh` (local mode) checks that every UI rejects anonymous access.
* **Update**: edit the `*_IMAGE` lines in `.env` (tag and digest; get the digest from the registry's
  `Docker-Content-Digest`), then `sudo ./install.sh`. Pull a newer copy of this directory first to get new defaults.
* **Backup**: stop writes (`docker compose -p lampa-stack stop`) and archive `/opt/lampa-stack/data`,
  `/opt/lampa-stack/secrets`, `/opt/lampa-stack/.env`, `/opt/lampa-stack/authelia/users.yml` and the
  `lampa-stack_caddy_data` volume (certificates). Downloads in `data/qbt/downloads` can be large.
* **Uninstall**: `sudo ./install.sh --uninstall` stops everything, removes the timer and firewall rules it added
  and keeps data. `--uninstall --purge` deletes `/opt/lampa-stack` and the volumes.

## Troubleshooting

| Symptom | Check |
|---|---|
| Browser certificate warning in local mode | expected (local CA); `--export-ca` and trust it |
| Login loop on `ts.` / `qbt.` | open the UIs by the exact `*.lampa.localhost:8443` names; the session cookie is scoped to `DOMAIN` |
| `502` from Caddy | `docker compose -p lampa-stack ps`; `docker logs lampa-stack-authelia-1` (Authelia restarts if its 256m is exceeded) |
| Lampac unhealthy for a minute after start | normal: start period is 90 s |
| TV says access denied | the Lampa token is wrong or the user was removed; `--add-user` again |
| qBittorrent shows "Unauthorized" | use the password from the install output, or `--rotate-secrets` |
| TOTP registration mail | Authelia has no mail server; the link is appended to `/opt/lampa-stack/data/authelia/notification.txt` |
| No peers for qBittorrent | peer port not published: `--enable-qbt-port` and open it in the cloud firewall |

## Why there is no separate Lampa container

`yumata/lampa` publishes no image and no stable release (tags stop at v1.4.1 while the app is 3.x); its only
Docker support is a Dockerfile on an end-of-life `httpd:alpine3.15` that bakes in a domain. Lampac NextGen's
LampaWeb module serves Lampa itself (plus `lampainit.js`, TV packages and the token check), so one maintained
image provides the frontend and the backend. LampaWeb auto-update is off by default (`LAMPA_AUTOUPDATE=false`).

## Verification status

Tested on Ubuntu 24.04 with Docker 29 and compose 5:

* `shellcheck -S warning`, `bash -n`, `docker compose config` (limits present; no `0.0.0.0` port in default mode),
  `systemd-analyze verify` on the timer and service.
* A live stack in local mode with the pinned **Caddy** and **Authelia** images and **qBittorrent 5.3.0**
  (linuxserver, Docker Hub copy of the pinned tag), a locally built TorrServer `MatriX.147.2` image already on the host (not pulled from ghcr), and a **stub in place of
  Lampac**. Verified: anonymous requests to `ts.` and `qbt.` are redirected to the login; Authelia login works and
  a wrong password is refused; the Authelia session reaches TorrServer and qBittorrent; TorrServer Basic works and a
  wrong Basic is refused; admin paths return 404 and `lcrqpasswd` is stripped; no backend port is published or
  reachable from the host; TorrServer `DisableUpload` / `RemoveCacheOnDrop` / `UseDisk=false` applied and read back;
  qBittorrent accepts only the generated password, seeding limits applied; add-user, remove-user,
  rotate-secrets, uninstall; cleanup dry-run and real run keep `config/`.

**Not verified** (the sandbox could not pull `ghcr.io` and `lscr.io` blobs): the real Lampac image starting
(healthcheck `curl /version?type=hash`, writable paths, `LAMPAC_READ_ONLY=true`, whether `wwwroot` already contains
Lampa or is downloaded on first start); that Lampac's `accsdb` denies anonymous API calls and accepts the token
from `users.json` exactly as read from its source; how a TV widget carries the token; and the pinned
`lscr.io` / `ghcr.io` digests themselves (read from the registries, never pulled).
