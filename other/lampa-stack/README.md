# Lampa stack

Everything to watch and download from your own server. **Nothing is anonymous**: every web path needs a login
(browsers, Authelia) or a per-device key (the Lampa app on a TV or phone).

| Part | What it does | Image (pinned in `.env`) |
|---|---|---|
| **Lampa** | The TV / set-top-box interface. There is no usable standalone Lampa image (see [Why no Lampa container](#why-there-is-no-separate-lampa-container)); Lampac serves it. | part of Lampac |
| **Lampac** | Backend: online sources (`/online.js`), optional 18+ section (`/sisi.js`), serves the Lampa web app. | `ghcr.io/lampac-nextgen/lampac` |
| **TorrServer** | **Streams** torrents to Lampa: RAM cache, no seeding, nothing kept on disk. | `ghcr.io/yourok/torrserver` |
| **qBittorrent** | Full torrent client for **downloads** (download and seed). | `lscr.io/linuxserver/qbittorrent` |
| **Authelia** | Login portal (password, optional TOTP) in front of the browser UIs; locks out guessers. | `authelia/authelia` |
| **Caddy** | The only entry point: TLS, routing, the key / token checks. | `caddy` |
| **WireGuard** (optional) | `--vpn` mode: the stack is reachable only through a VPN. | host package |

Use only sources and content you have the right to access. Online sources and torrent search may be unlicensed
or illegal in your country; you, the operator, are responsible. The 18+ section is for adults only and is off
unless you switch it on.

## Quick start

Docker with the compose plugin must be installed (the script does not install it). On a fresh server:

```bash
git clone <this repo> && cd server-init-config/other/lampa-stack
sudo ./install.sh
```

That is the default **public** mode. It detects the server's public IPv4, picks one random free TCP port, gets a
Let's Encrypt certificate for `<ip-with-dashes>.sslip.io` and prints everything once:

```
Mode: public   Port: 43817   Modules: Online on, SISI 18+ off
Lampa / Lampac : https://1-2-3-4.sslip.io:43817   (needs a device key)
Login (Authelia): https://auth.1-2-3-4.sslip.io:43817
TorrServer UI  : https://ts.1-2-3-4.sslip.io:43817   qBittorrent UI: https://qbt.1-2-3-4.sslip.io:43817   (after the login)
Open in the CLOUD firewall (Hetzner): TCP 43817 and TCP 80 ...

Credentials (shown ONCE ...):
  user admin: web login password ...
  qBittorrent (behind the Authelia login): user admin  password ...
Access for the Lampa app:
  user 'admin'
    Open Lampa (once; ...): https://1-2-3-4.sslip.io:43817/?token=<key>
    Lampa > Settings > Extensions > add plugin: https://1-2-3-4.sslip.io:43817/on/js/<key>
    Lampa > Settings > TorrServer > URL: https://ts.1-2-3-4.sslip.io:43817/t/<token>
```

Before it works from outside, open **TCP 80 and the printed port** in the cloud firewall (Hetzner: Firewalls). The
installer opens them in `ufw` / `firewalld` itself when one is active (additively; SSH rules are never touched).
Rerunning the script is safe; it keeps `.env`, secrets and the port. It lives in `/opt/lampa-stack` (override
with `LAMPA_STACK_DIR`).

## Access modes

| Mode | Command | Reachable | TLS | What is opened |
|---|---|---|---|---|
| **public** (default) | `./install.sh` | the whole internet, one HTTPS port | Let's Encrypt (HTTP-01) for `<ip>.sslip.io` or your `DOMAIN` | random TCP port (20000-60000) + TCP 80 for the certificate check |
| **local** | `./install.sh --local` | `127.0.0.1:8443` only, over an SSH tunnel | Caddy's local CA (`--export-ca`) | nothing |
| **vpn** | `./install.sh --vpn` | only on the WireGuard address `10.88.77.1` and on localhost | Caddy's local CA (`--export-ca`) | random UDP port for WireGuard |

The choice is remembered in `.env` (`ACCESS_MODE`). **Switching cleans up**: the firewall rules the old mode
opened are closed (a rule you had before is never touched), Caddy is recreated with the new published ports, and
leaving `--vpn` removes `wg0`, its unit and its `/etc/wireguard` file (the server key and the peer list stay in
`secrets/`, so `--vpn` again brings the same devices back). The authorization below is the same in all three modes.

`./install.sh --status` prints the mode, URLs, port, users and devices, enabled modules, containers, published
ports and a few checks.

### Public IP and host names

* The IP is detected on **every run**, in this order, each answer validated as a public IPv4 (not private,
  loopback, link-local, CGNAT or reserved): the Hetzner metadata service
  (`http://169.254.169.254/hetzner/v1/metadata/public-ipv4`), the source address of `ip -4 route get 1.1.1.1`
  (only when that is itself public), then `https://api.ipify.org` (5 s timeout).
* `PUBLIC_IP=a.b.c.d ./install.sh` skips detection (and is validated). `DOMAIN=example.org ./install.sh` uses your
  own domain instead of sslip.io (`example.org`, `auth.`, `ts.` and `qbt.` must resolve to the server); it is
  remembered as `DOMAIN_CUSTOM`.
* If the IP changed since the last run you get a warning: the sslip.io name, the certificate and every URL / Lampa
  setting change with it. If detection fails on a later run the stored IP is kept (with a warning).
* [sslip.io](https://sslip.io) is a free wildcard DNS service: `anything.1-2-3-4.sslip.io` resolves to `1.2.3.4`.
  The script checks after the start that the four names resolve to this server and warns if they do not.
  Let's Encrypt applies rate limits per registered domain; if issuing fails (see [Troubleshooting](#troubleshooting))
  use your own `DOMAIN` or wait. Both points are **not verified** here (see Verification status).

### Port 80

Public mode publishes TCP 80 next to the random port. Let's Encrypt validates the certificate with an HTTP request
to port 80 (HTTP-01; the TLS-ALPN check would need port 443, so it is switched off). Caddy answers nothing there
except the validation requests and a redirect to the https URL; no page, no login and no password is ever served
over plain HTTP. Port 80 must be free on the host (the installer stops with a message otherwise) and open in the
cloud firewall. DNS-01 (no port 80 needed) is not implemented.

### Local mode

```bash
sudo ./install.sh --local
ssh -N -L 8443:127.0.0.1:8443 you@server        # on your laptop, then open https://lampa.localhost:8443
```

Browsers resolve `*.localhost` themselves. Caddy signs with its own CA, so the browser warns once; either click
through or `sudo ./install.sh --export-ca` and trust `/opt/lampa-stack/caddy-local-root.crt`. A TV cannot use an
SSH tunnel: use public mode or the VPN.

### VPN mode (optional)

```bash
sudo ./install.sh --vpn                 # installs wireguard-tools / qrencode if missing; wg0 on a random UDP port
sudo ./install.sh --add-device phone    # prints the WireGuard client config and a QR code, once
```

* Interface `wg0`, network `10.88.77.0/24` (`WG_NET` in `.env`), the server is `.1`; keys are `0600`
  (`/etc/wireguard/wg0.conf`, `secrets/wg_server.key`). Each device gets its own key pair and pre-shared key; the
  client private key is shown once and never stored.
* The client config is a **split tunnel** (`AllowedIPs = 10.88.77.1/32`): only the stack goes through the VPN.
* Caddy publishes only on `10.88.77.1` and `127.0.0.1`. Names are `<10-88-77-1>.sslip.io` (public DNS answers
  `10.88.77.1`; a router that blocks private DNS answers needs a hosts entry), with Caddy's local CA certificate:
  `--export-ca`, trust it on the device. Open the UDP port in the cloud firewall.
* `--add-device NAME` also issues the Lampac key and the TorrServer token (below); `--remove-device NAME` revokes
  the key, the token and the WireGuard peer. On systemd hosts a drop-in makes Docker start after `wg-quick@wg0`, so
  the containers can bind the wg address at boot.
* `--vpn` on a stack that already has devices gives each device without a peer one and prints its client config once.
  `--remove-device` drops the peer in every mode, so switching away from `--vpn` and back cannot revive it.
* "Only on the wg address" rests on routing, not on a filter: Docker publishes on `10.88.77.1`, and a host on the same
  layer-2 segment that routes that address to the server's public interface could reach the listener without being a
  peer. Not an issue on a cloud network that does not forward it; to enforce it anyway add
  `iptables -I DOCKER-USER -d 10.88.77.1 ! -i wg0 -j DROP` (adjust `WG_NET`).
* A TV usually cannot run WireGuard; the VPN is for phones, laptops and routers.

## Who gets in where (authorization)

| Host / path | Needs | Notes |
|---|---|---|
| `auth.HOST` | nothing (it is the login page) | Authelia **regulation**: 3 failed logins within 5 minutes ban the user name *and* the client address for 30 minutes. Second-factor and reset endpoints are rate limited. |
| `ts.HOST/t/<token>/...` | the **per-device TorrServer token** in the path | The token is removed before TorrServer sees the request; Caddy adds TorrServer's own Basic credential, so TorrServer authenticates it again. Players, `<video>` tags and CORS preflights work because the token is part of the URL. A token opens only what Lampa and players use (`/echo`, `/torrents`, `/stream`, `/play`, `/cache`, `/viewed`, `/playlist`, `/ffp`, `/subs`, `/download`) and a **read-only** `/settings`: Lampa calls `POST /settings {"action":"get"}` before every torrent, so Caddy rewrites the body of a token's `POST /settings` to `{"action":"get"}`; the player endpoints (`/torrents` add/list/rem/drop ...) work as usual. `/shutdown` and the rest are refused (403), so a leaked token cannot switch TorrServer to disk, change its save path or stop it. `/download` is Lampa's speed test. |
| every other path on `ts.HOST` (`/stream`, `/play/*`, `/subs/*`, `/playlist*`, `/settings`, `OPTIONS` ... without a token) | an **Authelia session** | no session: redirect to the login. Never anonymous. A wrong or unknown token, a Basic header, a token in a query string all fall here and are refused. |
| `qbt.HOST` | Authelia session, then qBittorrent's own login | two independent logins |
| `HOST` (Lampa app, `/online.js`, `/sisi.js`, `/lite/*`, `/lampainit.js`, `/version` ...) | a **Lampa key**: `?token=` / `account_email` / `uid` / `box_mac` query value, the `lampa_key` cookie Caddy sets, or the loader paths `/on/js/<key>`, `/online/js/<key>`, `/sisi/js/<key>`; **or** an Authelia session | Caddy checks the key against the list; Lampac checks it again (`accsdb`). With a session Caddy adds that user's own key, so a person who logs in at the portal can use Lampa in the browser without typing a key. |
| `HOST/proxy*`, `/proxyimg*` | nothing by default (`LAMPAC_PROXY_ANON=1`): **the one anonymous exception**; `LAMPAC_PROXY_ANON=0` requires a key like everything else | These are Lampac's own media links: AES-encrypted or hashed by Lampac, they carry the upstream URL and cannot be forged, but anyone who holds a link can replay it until it expires, and video players cannot add a key to them. With `1` Caddy lets through only the shape Lampac generates (`/proxy/<payload>[.ext]`, `/proxyimg:W:H/<payload>`), never a path with `.` / `..` segments. The default `1` keeps playback working in Lampa's player and in external players; set `0` in `.env` and rerun `install.sh` if you prefer no anonymous path at all (proxied videos and images may then stop playing). |
| `HOST/startpage.js` (only with SISI enabled) | nothing | A static plugin script that Lampac lists in the SISI loader without a key; Lampa on a TV loads plugins cross-origin, where the key cookie is not sent. It holds no data, but it is an anonymous path and shows that the 18+ module is on. **Like `LAMPAC_PROXY_ANON`, this is an exception you accept by enabling SISI (`--enable-sisi`, off by default).** |
| `HOST/admin*`, `/adminpanel*`, `/stats*`, `/weblog*`, `/ts*`, `/dlna*`, `/extensions*`, `/api/headers` | blocked (404) even with a key | Lampac control surfaces; `/extensions` is the third-party plugin store. Edit `init.conf` on the host instead. |
| the session cookie, request headers `lcrqpasswd`, `x-client-ip`, `xhost`, `xscheme` | stripped by Caddy | `lcrqpasswd` is Lampac's local-admin bypass; the Authelia and key cookies are not passed to Lampac |
| cross-site `POST`/`PUT`/... with a session | refused (403, `Sec-Fetch-Site`) on `ts.`, `qbt.` and the session branch of the Lampa host | a plugin on one host cannot ride on your session |

* **Keys and tokens** are 128-bit random hex, one pair per user or device, in `secrets/users.tsv` (root, `0600`).
  The key list reaches Caddy as a Docker secret (not in `docker inspect`, `docker compose config` or any
  environment variable) and Lampac as `lampac/users.json` (`root:1000 0640`). Caddy keeps no access log (keys travel
  in URLs).
* **Rate limiting.** Passwords: Authelia regulation (above). Keys cannot be guessed (2^128) and a wrong one costs
  Caddy a map lookup. Lampac has per-key limits on distinct IPs and requests too, but it sees only the proxy's
  address (it takes the client IP from the connection, and Caddy strips the headers that would carry another), so
  those limits do not tell devices apart behind Caddy.
* **Revocation** is immediate for Caddy (`--remove-device` / `--remove-user` reloads it); Lampac forgets a removed
  key when it restarts, which the command does.
* Headers on every host: `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`; in
  public mode also `Strict-Transport-Security: max-age=31536000; includeSubDomains`.
* Authelia gives the browser a signed **session cookie** (server side session), not a bearer JWT. It uses JWTs for
  its identity-verification and password-reset links. Optional TOTP: `AUTHELIA_POLICY=two_factor` in `.env`.
* Not published, reachable only inside the internal compose network: Lampac `:9118`, Authelia `:9091`, TorrServer
  `:8090`, qBittorrent WebUI.

## Users and devices

```bash
sudo ./install.sh --add-device tv         # a TV / phone: Lampac key + TorrServer token (+ WireGuard peer in --vpn)
sudo ./install.sh --add-user alice        # a person: web login (Authelia) + their own key
sudo ./install.sh --show tv               # print the URLs of a device / user again (never a password)
sudo ./install.sh --remove-device tv      # revoke everything of that device
sudo ./install.sh --remove-user alice
sudo ./install.sh --rotate-secrets        # new session secret, passwords, every key and token (re-pair all devices)
```

The first user (`admin`, or `ADMIN_USER=...`) is created on the first run. Passwords are shown once and kept only
as argon2id hashes. The last user cannot be removed.

## Connect Lampa on the TV, step by step

1. Run `sudo ./install.sh --add-device tv` (or use the admin's lines from the first install). It prints the
   URLs below with your key and token filled in; `--show tv` prints them again.
2. On the TV open the Lampa web app in its browser (or the Lampa TV app that lets you set a server address) at
   `https://HOST:PORT/?token=<key>`. Caddy checks the key and remembers it in a cookie (`lampa_key`, `Secure`,
   `HttpOnly`) so the page's own files load; for requests that carry only the cookie, Caddy adds the key to the
   query for Lampac, which identifies a device only by the query, so Lampa does not ask for a password. Without a key
   you are sent to the login page.
3. **Online sources**: *Settings > Extensions > Add plugin* and enter
   `https://HOST:PORT/online/js/<key>`. That is `/online.js` with your key built into it (the bare `/online.js`
   is refused). Or add `https://HOST:PORT/on/js/<key>` once: it loads every enabled section.
4. **18+** (only if you enabled it, see [Modules](#modules)): add `https://HOST:PORT/sisi/js/<key>` the same way.
5. **Streaming**: *Settings > TorrServer*, URL `https://ts.HOST:PORT/t/<token>`, and leave the login / password
   switch **off**. The token in the URL is the credential; it works for the API, the player and preload alike.
6. Torrent search needs a parser: *Settings > Parser*, enable *Use parser* and enter your own Jackett /
   Prowlarr-compatible URL and key (Lampac's JacRed is not loaded; see below).
7. Samsung / LG TVs: Lampac also serves packages at `/samsung.wgt` and `/lg.ipk`; they sit behind the same key check
   (open them as `.../samsung.wgt?token=<key>`).

TorrServer `/playlist` files list stream links without the token path; use Lampa's own player, or add the token
segment to the links yourself.

## Modules

| Module | Default | Switch | What it is |
|---|---|---|---|
| Online sources | **on** | `LAMPAC_ONLINE=1` in `.env` | Lampac's online sources, loaded as `/online.js` |
| SISI (18+) | **off** | `./install.sh --enable-sisi` / `--disable-sisi` (`LAMPAC_SISI`) | Lampac's adult section, loaded as `/sisi.js`. **Adults only**; check the law where you live. |

Both set the real Lampac switches: `BaseModule.SkipModules` (folder names `Online*`, or `SISI`, `Adult` and `NextHUB`, an 18+ hub that compiles on its own) so the
modules are not even compiled, and `LampaWeb.initPlugins.online` / `.sisi` so `lampainit.js` and `/on/js/<key>`
list them. Lampac recompiles its modules on start, so a switch restarts it (a minute or two).

Always skipped, because they are open relays, anonymous bind helpers or point at third parties: the embedded
TorrServer, admin / stats / log pages, DLNA, `CubProxy`, `TmdbProxy`, `CorsMedia`, `Corseu`, `JacRed`, `Kit`,
`Sync`, `TimeCode`, `ExternalBind`, `WatchTogether`, `TelegramAuth*`, `ForkPlayerXML`, `MsxNative`, `Catalog`,
`Tracks`, `Transcoding`. `LampaWeb.initPlugins` is set **explicitly for all 17 keys**: `pirate_store` (a store of
third-party, unpinned plugins), `jacred`, `tmdbProxy`, `cubProxy`, `torrserver`, `timecode` and the rest are
`false`, so Lampa is never told to load a plugin whose backend is not running or that comes from an external,
unpinned source. Lampa talks to cub.red and TMDB directly (Lampa's own behavior) and keeps its own parser setting.
The Lampac online sources reach their providers from the server (`egress` network).

## Streaming vs downloading

* **Streaming (Lampa, TorrServer)**: pieces are fetched on demand into a **RAM cache** and played; nothing is
  written to disk, nothing is uploaded. `install.sh` sets it through TorrServer's `/settings` API (the Go field
  names of `BTSets`, read back afterwards): `UseDisk=false`, `CacheSize` = `TS_CACHE_MB` (default **384 MB**),
  `PreloadCache` = `TS_PRELOAD_PCT` (20 %, how much is fetched before play starts), `ReaderReadAHead` =
  `TS_READAHEAD_PCT` (90 %), `RemoveCacheOnDrop=true`, `DisableUpload=true`, `TorrentDisconnectTimeout` =
  `TS_IDLE_SECONDS` (120 s: a torrent with no reader is dropped, and its cache with it), `EnableDLNA`,
  `EnableBonjour`, Rutor and Torznab search off. Lampa does not save streamed torrents in TorrServer's database
  (its "save to DB" is off by default).
* **Downloading (qBittorrent)**: the full client, for files you keep and seed. Web UI at `qbt.HOST` after the login.
* **Safety net**: `lampa-stack-cleanup.timer` runs on days 1, 4, 7 ... of the month (about every 3 days). It removes
  every torrent from TorrServer's list through its API and empties `data/torrserver/cache` and
  `data/torrserver/torrents`. Those are the two scratch places the cleanup owns (the container's root is read-only;
  `config` and `/tmp` are writable too, and `config` is never cleaned), and the installer pins `TorrentsSavePath` to the cache one, so the cleanup covers a disk cache even if
  someone switches `UseDisk` on in the TorrServer UI (it says so if the settings point elsewhere). It never touches
  `data/torrserver/config`, credentials or other services' data. Preview: `sudo /opt/lampa-stack/scripts/cleanup.sh --dry-run`.
* Memory: the cache is part of TorrServer's heap, so `TORRSERVER_MEM` (768 MB) must hold `TS_CACHE_MB` + about
  160 MB; the installer refuses a combination that does not fit and sets `GOMEMLIMIT` just under the limit.

## qBittorrent

* Web UI at `qbt.HOST` after the Authelia login, user `admin`. The password is generated; the temporary first-run
  password never exists because the config is pre-seeded with a PBKDF2 hash (the installer then checks that
  `adminadmin` is refused).
* Seeding limits (paused, never deleted): ratio `QBT_MAX_RATIO` (default 2.0) **or** `QBT_MAX_SEED_MINUTES`
  (default 10080 = 7 days). Change them in `.env` and rerun `install.sh`.
* Downloads land in `/opt/lampa-stack/data/qbt/downloads`. Nothing is deleted automatically. Optional:
  `QBT_DELETE_COMPLETED_DAYS=30` makes the cleanup timer delete **files** older than 30 days there.
* **Peer port.** By default it is bound to `127.0.0.1` (downloads work, but you are not connectable and seeding is
  poor). `sudo ./install.sh --enable-qbt-port` replaces the 6881 default with a **random** port in 20000-60000
  (kept in `QBT_PORT`, never the SSH or HTTPS port), publishes it on `0.0.0.0` for TCP and UDP and opens it in
  ufw / firewalld. Open it in the cloud firewall too. UPnP is off.

## Settings (`/opt/lampa-stack/.env`)

Edit, then run `sudo ./install.sh` again. Existing values are kept when a new version adds keys.

| Key | Default | Meaning |
|---|---|---|
| `*_IMAGE` | pinned tag + digest | image of each service; change to update |
| `ACCESS_MODE` | `public` | set by `--public` / `--local` / `--vpn` |
| `DOMAIN_CUSTOM`, `ACME_EMAIL` | empty | your own domain (instead of sslip.io); optional Let's Encrypt contact |
| `PUBLIC_IP`, `BASE_HOST`, `SITE_PORT` | detected | written by the installer; do not edit (`BASE_HOST`, `SITE_PORT`) |
| `HTTPS_PORT`, `WG_PORT` | random, chosen once | the HTTPS port (public / vpn) and the WireGuard UDP port |
| `LOCAL_PORT`, `WG_NET` | 8443, `10.88.77` | local-mode port, VPN network |
| `AUTHELIA_POLICY` | `one_factor` | `two_factor` adds TOTP (register a device on first login) |
| `LAMPAC_ONLINE`, `LAMPAC_SISI`, `LAMPAC_PROXY_ANON` | 1, 0, 1 | [modules](#modules) and the signed-media-link exception |
| `LAMPA_AUTOUPDATE`, `LAMPA_TREE` | true, pinned commit | LampaWeb downloads that Lampa commit from GitHub on the first start, once |
| `TS_CACHE_MB`, `TS_PRELOAD_PCT`, `TS_READAHEAD_PCT`, `TS_IDLE_SECONDS` | 384, 20, 90, 120 | TorrServer streaming |
| `QBT_USER`, `QBT_WEBUI_PORT`, `QBT_PORT`, `QBT_PEER_BIND` | admin, 8085, 6881, 127.0.0.1 | qBittorrent (`QBT_PORT` is randomized by `--enable-qbt-port`) |
| `QBT_MAX_RATIO`, `QBT_MAX_SEED_MINUTES`, `QBT_DELETE_COMPLETED_DAYS` | 2.0, 10080, 0 | seeding limits, optional old-download cleanup |
| `*_MEM`, `LAMPAC_SHM` | see below | container memory limits |
| `LAMPAC_READ_ONLY` | `false` | unsupported: LampaWeb unpacks Lampa into the root filesystem on the first start |
| `STACK_UID` | 10000 | uid of TorrServer / qBittorrent and of their data |

Secrets are never in `.env` or the compose file: they live in `/opt/lampa-stack/secrets/` (root, `0600`) and are
handed to Authelia and Caddy as Docker secret files. `--rotate-secrets` replaces the session secret, the
TorrServer / qBittorrent / Lampac root passwords, every user's password and every key and token (all sessions end).
The Authelia storage key is kept because it encrypts TOTP seeds; to change it use Authelia's
`storage encryption change-key`.

## Hardening and memory budget

All containers: `no-new-privileges`, `cap_drop: ALL` (adds back only `NET_BIND_SERVICE` for Caddy and
`CHOWN SETUID SETGID DAC_OVERRIDE FOWNER` for the linuxserver image's s6 init), `pids_limit`, `mem_limit` and `cpus`,
json-file log rotation (10 MB x 3), healthchecks, SELinux `:z` labels on bind mounts. Read-only root filesystems:
Caddy, TorrServer. Not read-only: qBittorrent (s6 needs `/run` and `/config`), Authelia (4.39.28 exited at its
startup checks with `read_only`, cause not logged) and Lampac (not verified). Networks: `backend` is
`internal: true` (no route out); only Lampac (sources), TorrServer and qBittorrent (peers / trackers) and Caddy
(ACME) are also on `egress`. Caddy's published ports are in `compose.ports.yml`, written per mode.

| Service | Limit | Typical (estimate, not measured) |
|---|---|---|
| Lampac (+ Chromium for some sources; more with SISI loaded) | 1024m | ~400m |
| TorrServer | 768m | `TS_CACHE_MB` (384) + ~100m |
| qBittorrent | 512m | 150-300m |
| Authelia | 256m | ~60m (argon2id uses 32 MiB per login) |
| Caddy | 96m | ~30m |
| **Sum of limits** | **2.6 GB** | leaves about 1.4 GB for the OS, page cache and Docker on a 4 GB host |

On a 4 GB host that also streams, keep `TS_CACHE_MB` at 384 or lower and do not run large qBittorrent jobs and
a SISI-enabled Lampac at once.

## Day-two

* **Status**: `sudo ./install.sh --status`. After install, `sudo tests/smoke.sh` runs about 90 checks from the
  server: nothing is anonymous on any host, keys / tokens open exactly their own door, ports, headers, process
  lists free of the TorrServer credential. `SMOKE_USER=.. SMOKE_PASS=.. tests/smoke.sh` adds the login checks.
* **Update**: edit the `*_IMAGE` lines in `.env` (tag and digest; get the digest from the registry's
  `Docker-Content-Digest`), then `sudo ./install.sh`. Pull a newer copy of this directory first to get new defaults.
* **Backup**: stop writes (`docker compose -p lampa-stack stop`) and archive `/opt/lampa-stack/data`,
  `/opt/lampa-stack/secrets`, `/opt/lampa-stack/.env`, `/opt/lampa-stack/authelia/users.yml` and the
  `lampa-stack_caddy_data` volume (certificates). Downloads in `data/qbt/downloads` can be large.
* **Uninstall**: `sudo ./install.sh --uninstall` stops everything, removes the timer, the firewall rules it added
  and WireGuard, and keeps data. `--uninstall --purge` deletes `/opt/lampa-stack` and the volumes.

## Troubleshooting

| Symptom | Check |
|---|---|
| No certificate / browser says the connection is not private (public mode) | `docker logs lampa-stack-caddy-1`. The four names must resolve to the server (the installer prints a DNS check), TCP 80 must reach the server from the internet (cloud firewall!), and Let's Encrypt has rate limits per registered domain (failed validations and certificates per week); with sslip.io many people share the domain, so use your own `DOMAIN=` if it is rejected |
| Browser certificate warning in local / vpn mode | expected (local CA); `--export-ca` and trust it |
| Login loop on `ts.` / `qbt.` | open the UIs by the exact names printed by the installer; the session cookie is scoped to the base host |
| `502` from Caddy | `docker compose -p lampa-stack ps`; `docker logs lampa-stack-authelia-1` (Authelia restarts if its 256m is exceeded) |
| `400` on every page after an IP / mode change | Authelia has not restarted; `docker restart lampa-stack-authelia-1` (the installer does it when the config changes) |
| Locked out of the login | 3 wrong passwords ban the user and your IP for 30 minutes (Authelia regulation); wait, or `docker stop lampa-stack-authelia-1`, delete `data/authelia/db.sqlite3` (this also drops TOTP registrations), start it again |
| Lampac unhealthy for a minute or two after start | normal on the first start: it downloads Lampa from GitHub (start period 180 s). If it stays unhealthy, `docker logs lampa-stack-lampac-1`: the host needs outbound access to `github.com` and `raw.githubusercontent.com` |
| Lampa shows "access denied" / asks for a key | the key is wrong or the device was removed; `--show NAME` or `--add-device` |
| Streaming works in the browser UI but not in Lampa | the TorrServer URL in Lampa must be `https://ts.HOST:PORT/t/<token>` with the auth switch off |
| qBittorrent shows "Unauthorized" | use the password from the install output, or `--rotate-secrets` |
| TOTP registration mail | Authelia has no mail server; the link is appended to `/opt/lampa-stack/data/authelia/notification.txt` |
| No peers for qBittorrent | peer port not published: `--enable-qbt-port` and open it in the cloud firewall |
| `--vpn` fails to start wg0 | the host needs the `wireguard` kernel module (`modprobe wireguard`); `journalctl -u wg-quick@wg0` |

## Why Authelia (the auth choice)

Candidates for "session login in front of every web UI" on a 4 GB host:

* **Authelia** (chosen). One ~40 MB Go binary, about 30-100 MB RAM, SQLite storage, no database server.
  Forward-auth works with Caddy out of the box, passwords are argon2id, optional TOTP, brute-force regulation,
  secrets can be read from files (`*_FILE`). Official image, no custom build.
* caddy-security / authcrunch: also light and JWT-native, but it needs a custom Caddy build (xcaddy) that you
  would have to rebuild and re-pin on every Caddy update.
* oauth2-proxy: needs an external identity provider; nothing to log in with on a single server.

Caddy has no built-in rate limiter without a custom build, which is why password guessing is handled by Authelia's
regulation and key guessing is simply infeasible (128-bit keys).

## Why there is no separate Lampa container

`yumata/lampa` publishes no image and no stable release (tags stop at v1.4.1 while the app is 3.x); its only
Docker support is a Dockerfile on an end-of-life `httpd:alpine3.15` that bakes in a domain. Lampac NextGen's
LampaWeb module serves Lampa itself (plus `lampainit.js`, TV packages and the key check), so one maintained
image provides the frontend and the backend. The image does **not** ship Lampa: on the first start LampaWeb downloads
the commit pinned in `LAMPA_TREE` from GitHub into `data/lampac/lampa-main` (outbound access needed), then does nothing
more. That is why the Lampac healthcheck requests `/`: it fails while the frontend is missing.

## Verification status

Tested on Ubuntu 24.04 with Docker 29 and compose 5:

* `shellcheck -S warning`, `bash -n`, `docker compose config`, `caddy validate` (public and internal-TLS variants),
  `authelia validate-config`, `systemd-analyze verify` on the timer and service.
* Live stacks with the pinned **Caddy** and **Authelia** images, **qBittorrent 5.3.0**, a locally built TorrServer
  `MatriX.147.2` (not pulled from ghcr) and a **stub in place of Lampac**, in `--local`, `--public` and `--vpn`
  mode, with switches between them. `tests/smoke.sh` passes (87 checks in local mode, 76 in vpn mode, run
  against the stub with `SMOKE_SKIP_LAMPAC=1`): no TorrServer path is reachable without a token or session
  (`/stream`, `/play`, `/subs`, `/playlist`, `OPTIONS`, wrong / short / query-string tokens, the Lampa key as a
  token), the device token reaches only the player endpoints of TorrServer and a read-only `/settings` (a `set` is rewritten to a `get`; not `/shutdown`), dot segments are refused, every Lampa-host path is refused without a key
  and served with a key by query, `account_email`, `uid`, loader path and cookie, a revoked device stops working at
  once, an Authelia session reaches `ts.`, `qbt.` and the Lampa host (the user's key is added), Authelia bans after
  repeated failures, only the expected ports are published, and TorrServer itself refuses an unauthenticated request.
  TorrServer's settings (`UseDisk=false`, 384 MB `CacheSize`, preload, read-ahead, idle timeout, `RemoveCacheOnDrop`,
  `DisableUpload`, `TorrentsSavePath`) were applied and read back on the real image.
* The TorrServer credential: the process lists (host and containers) were sampled every 100 ms during
  `--rotate-secrets`; neither the password nor the Basic header ever appeared (the curl is `curl ... -K -`, the
  credential goes in on stdin).
* Public IP detection and validation with fake metadata / ipify endpoints and a fake `ip route`; firewall
  reconcile on mode switches with a fake `ufw`; the random HTTPS, WireGuard and qBittorrent peer ports; `--add-device`
  / `--remove-device` with a fake `wg-quick` (the real `wg genkey` / `pubkey` / `genpsk` and `qrencode` ran); the
  cleanup script's dry run and real run keep `config/`.
* Read in the Lampac **1.28.4 source**: `Accsdb` identifies users only by `token` / `account_email` / `uid` /
  `box_mac` query values; `/online/js/{token}` and `/sisi/js/{token}` bake the token into the plugin; `SkipModules`
  matches module / group folder names; `LampaWeb.initPlugins` keys and defaults. In the **Lampa 3 source**
  (`app.min.js`) the TorrServer URL is used as typed and `/torrents`, `/stream/...` are appended to it.

**Not verified** (the sandbox could not pull `ghcr.io` blobs, has no internet for Let's Encrypt, no DNS for
sslip.io and no WireGuard kernel module): the real Lampac image starting, its `accsdb` accepting a key from
`users.json`, and the module switches compiling (`tests/smoke.sh` without `SMOKE_SKIP_LAMPAC` checks these on a real
stack, run it once after install); an actual Let's Encrypt certificate for an sslip.io name, sslip.io resolving
`auth.` / `ts.` / `qbt.` subdomains, and the Let's Encrypt rate limits for sslip.io; a real `wg0` carrying traffic;
the Hetzner metadata URL (only a fake server was used); the `firewalld` branch; how Lampa on a particular TV
handles the path-token TorrServer URL and the `?token=` first load; that every module left loaded is enough for the
Lampa features you use; and the pinned `lscr.io` / `ghcr.io` digests themselves.
