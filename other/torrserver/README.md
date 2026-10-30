# TorrServer in Docker (streaming, hardened)

Installs [TorrServer](https://github.com/YouROK/TorrServer) (image `ghcr.io/yourok/torrserver`) to **stream** torrents to Lampa and other players: pieces live in a RAM cache and are dropped when playback stops, nothing is kept on disk and nothing is uploaded. A login is always required. Only stream content you have the right to.

Works on Rocky/Alma/CentOS Stream 10, Fedora 44, Debian 13, Ubuntu 26.04 and openSUSE 16. Docker Engine with the compose plugin must already be installed (the script stops with a clear message if not). It installs `curl`, `jq` and `openssl` if they are missing.

```bash
sudo ./install.sh              # public HTTPS with a login on a random port; prints the URL and the password once
sudo ./install.sh --status     # mode, URL, port, devices
sudo ./install.sh --help
```

## Modes

| Mode | Command | Reachable at | What is opened | Needs |
|---|---|---|---|---|
| **public** (default) | `sudo ./install.sh` | `https://1-2-3-4.sslip.io:43817` (your server IP and a random port) | TCP 43817 (the service) and TCP 80 (certificate challenge and redirect only) | public IPv4; port 80 free |
| **local** | `sudo ./install.sh --local` | `127.0.0.1:8090` through an SSH tunnel | nothing (closes what an earlier mode opened) | nothing |
| **vpn** (optional) | `sudo ./install.sh --vpn` | `http://10.66.66.1:8090` inside a WireGuard tunnel, and on localhost | UDP port (random) for WireGuard | public IPv4; WireGuard kernel support |

- A rerun without a mode keeps the current one. Switching modes removes what the previous mode opened (firewall rules, Caddy, the WireGuard interface, the fail2ban jail). Installs from before the modes existed keep what they had (`--private` is now `--local`).
- The login (user `torrserver`, random 32-character password, in `/opt/torrserver/credentials`, root 0600) is mandatory in every mode and printed once. `sudo ./install.sh --rotate-password` makes a new one.

### Public mode (default)

```
TorrServer MatriX.147.2 is installed (streaming only, mode: public).
  URL:      https://1-2-3-4.sslip.io:43817/
```

1. **Random port.** One TCP port in 20000-60000, free, never the SSH port, chosen on the first run, stored in `/opt/torrserver/.env` and reused on every rerun. Override with `TS_PUBLIC_PORT=...`.
2. **Name without a domain.** [sslip.io](https://sslip.io) is a free DNS service: `1-2-3-4.sslip.io` resolves to `1.2.3.4`. The script builds the name from the server's public IP and Caddy gets a real Let's Encrypt certificate for it, so clients see valid HTTPS. With your own domain: `sudo ./install.sh --domain ts.example.com` (the A record must point at the server). `--no-domain` goes back to sslip.io. `--acme-email you@example.com` adds an address for expiry notices (optional).
3. **Public IP is found automatically**, on every run: Hetzner metadata (`http://169.254.169.254/hetzner/v1/metadata/public-ipv4`, 3 s), else the source address of `ip -4 route get 1.1.1.1` if it is a public address, else `https://api.ipify.org` (5 s). The result must be a public IPv4 address (private, CGNAT, link-local and documentation ranges are refused). If the IP changed since the last run, the script warns and updates the hostname (Caddy then gets a new certificate). Set `PUBLIC_IP=1.2.3.4` to skip detection (it is remembered; `PUBLIC_IP=auto` forgets it).
4. **Port 80, why.** Let's Encrypt validates the name with the HTTP-01 challenge on port 80. Caddy listens there only to answer that challenge and to redirect `http://` to the https URL; it never serves TorrServer or accepts the login on port 80. The script opens 80 in firewalld or ufw (additively, see below) and refuses to continue if something else already uses it. The TLS-ALPN challenge (port 443) is switched off because 443 is not used.
5. **Never plain HTTP.** The password is only accepted on the HTTPS port. A request to the bare IP (no matching name) gets no certificate and no answer.
6. **Brute-force protection.** The pinned Caddy has no rate-limit module, so a fail2ban jail `torrserver-caddy` reads Caddy's JSON access log (`/opt/torrserver/logs/access.log`, root 0600, `Authorization` is redacted by Caddy) and bans an address for 1 hour after 8 failed logins (HTTP 401) in 10 minutes. The ban is placed in iptables' `DOCKER-USER` chain because Docker's published ports never pass the `INPUT` chain. fail2ban is installed if missing (on EL it comes from EPEL; if it cannot be installed the script warns and goes on, and the random 32-character password is what protects you). Removed again when you leave public mode.
7. **Headers.** HSTS, `X-Content-Type-Options`, `X-Frame-Options: SAMEORIGIN`, `Referrer-Policy: no-referrer`, `Permissions-Policy`; the `Server` header is removed.

Also allow **TCP 80 and the random port** in the Hetzner Cloud Firewall (the summary prints both numbers).

Let's Encrypt limits certificates per registered domain; sslip.io is shared by many users, so very busy periods or many reinstalls can hit a limit. If that happens, wait or use your own `--domain`.

### Connect Lampa and other clients

In Lampa open Settings, TorrServer, and enter the URL from the summary (`https://1-2-3-4.sslip.io:43817`). Turn on the authorization option and enter the login `torrserver` and the password from `sudo cat /opt/torrserver/credentials`. Any client that takes a TorrServer URL plus login works the same; a browser shows a login prompt. Use the full `https://` URL with the port, since there is nothing on 443.

### VPN mode (optional)

`sudo ./install.sh --vpn` installs `wireguard-tools` and `qrencode` if missing, creates a server key (`/opt/torrserver/vpn/server.key`, root 0600), writes `/etc/wireguard/wg0.conf` (0600) with `wg-quick@wg0` enabled, and listens on a random UDP port (override `TS_VPN_PORT`; subnet `10.66.66.0/24`, override the server address with `TS_VPN_ADDR=10.77.77.1`). TorrServer is published on the VPN address and on 127.0.0.1 only; the firewall opens just the UDP port. A systemd drop-in starts WireGuard before Docker so the address exists when the container starts.

```bash
sudo ./install.sh --add-device phone      # prints the client config and a QR code (shown once, the private key is not stored)
sudo ./install.sh --remove-device phone   # revokes it immediately
sudo ./install.sh --status                # lists devices
```

Devices only route the TorrServer address through the VPN (`AllowedIPs = 10.66.66.1/32`, no NAT, no forwarding). The VPN peers are trusted: inside the tunnel TorrServer is plain HTTP with its own login and without the Caddy login on the routes TorrServer leaves open (see below).

### Local mode

`sudo ./install.sh --local` publishes `127.0.0.1:8090` only. From your laptop:

```bash
ssh -L 8090:127.0.0.1:8090 ops@SERVER     # then open http://127.0.0.1:8090/
```

## Streaming only, nothing downloaded

TorrServer has no switch for streaming-only, so the settings are set through its API (`POST /settings`, from the host to 127.0.0.1 with the generated login). `install.sh` reads the current settings, changes only the keys below and sends them back; a rerun changes nothing if they already match, and an existing install that used the disk cache is migrated on the next run. Key names are the fields of `BTSets` in `server/settings/btsets.go`.

| Key | Value | Effect |
|---|---|---|
| `UseDisk` | `false` | pieces are held in RAM only; nothing is written to disk |
| `TorrentsSavePath` | `""` | no disk location at all (TorrServer forces `UseDisk=false` without one) |
| `CacheSize` | 384 MB (`TS_CACHE_MB`), at most half of `TS_MEM_LIMIT` | RAM stream cache. The container limit is 3 GB, so the cap is 1.5 GB; the script lowers it with a note if you ask for more |
| `PreloadCache` | `10` | percent of the cache fetched before playback starts (about 38 MB: quick start) |
| `ReaderReadAHead` | `90` | percent of the cache kept ahead of the playback position (the rest stays behind for seeking) |
| `ResponsiveMode` | `true` | hand a piece to the player as soon as it arrives |
| `RemoveCacheOnDrop` | `true` | pieces are deleted when a torrent is dropped |
| `TorrentDisconnectTimeout` | 120 s (`TS_IDLE_SECONDS`) | a torrent nobody reads for this long is closed and its peers are disconnected |
| `DisableUpload` | `true` | maps to the torrent client's `NoUpload`: no data is sent to peers, so nothing is seeded |
| `DisableUPNP` | `true` | do not ask the router to open ports |
| `EnableLPD`, `EnableDLNA`, `EnableBonjour` | `false` | no local-network announcements or media server |
| `EnableDebug` | `false` | no debug logging |

DHT and PEX stay on so torrents can find peers. With upload disabled, peers may rank the server lower, so starting a stream can take a little longer.

**Safety net.** `torrserver-cleanup.timer` still runs `cleanup.sh` every 3 days (output: `journalctl -u torrserver-cleanup`): it drops loaded torrents, removes torrent entries older than 3 days and deletes leftover files in `data/downloads` older than 3 days (from before the migration, or if someone turns the disk cache back on). It never touches `data/config`, the log, `credentials` or `.env`. Try it first: `sudo /opt/torrserver/cleanup.sh --dry-run`. `CLEAN_DAYS` or `--days N` change the age.

## What you get

| Part | Detail |
|---|---|
| Image | `ghcr.io/yourok/torrserver:MatriX.147.2@sha256:056e0cf1...` (tag and digest, never `:latest`). Change `TS_VERSION` / `TS_IMAGE_DIGEST` to update |
| Proxy | `caddy:2.10.0@sha256:...` in public mode only |
| Container | non-root (10001), read-only root filesystem, `/tmp` as tmpfs, all capabilities dropped, `no-new-privileges`, 512 processes max, 3 GB RAM (no extra swap), 2 CPUs, log rotation (3 x 10 MB), healthcheck on `/echo` |
| Sharing | upload disabled, UPnP/LPD/DLNA/Bonjour off |

Files on the server (`/opt/torrserver`, change with `TS_DIR`):

```
docker-compose.yml  docker-compose.vpn.yml  Caddyfile  tls.caddy  cleanup.sh   managed by install.sh, rewritten on every run
.env                                      mode, port, host name, IP, VPN address; no secrets
credentials                               root:root 0600, the only copy of the password you read
caddy-auth.caddy                          bcrypt hash of the password for Caddy, root 0600 (public mode)
logs/access.log                           Caddy JSON access log for fail2ban, root 0600 (public mode)
vpn/                                      server key, devices (with pre-shared keys), root 0700 (vpn mode)
data/config/                              accs.db (login), config.db, settings.json
data/log                                  TorrServer log
```

## Security model

- **TorrServer itself is never published on the internet.** The container port is always `127.0.0.1:8090` (plus the VPN address in vpn mode). Docker's published ports bypass firewalld and ufw, so the bind address is the control that counts. In public mode only Caddy's ports are published.
- **Login.** TorrServer keeps users in `data/config/accs.db`, a JSON object `{"user":"password"}` read at start (plain text; this is how TorrServer works, see `server/web/auth/auth.go`). The file is owned by the container user, mode 0600, in a 0750 directory. If it is missing, TorrServer answers 401 to everything. `/echo` (version string) answers without a login and is what the healthcheck uses.
- **Routes TorrServer leaves open.** Its own login does not cover `/play/:hash/:id`, `/subs/:hash/:id`, `/playlist?hash=`, `/stream` with `play` or `m3u` for a torrent already loaded, and `/swagger/*` (checked in `server/web/api/route.go`). They need a known infohash, but on the internet they would let anyone who knows one check whether the server holds it and stream it on your bandwidth. That is why Caddy asks for the same login (HTTP basic auth, bcrypt hash) on every path except `/echo` and passes the Authorization header on. Unauthenticated `/play/<hash>/1`, `/playlist` and `/swagger` through Caddy answer 401.
- **Firewall changes are additive and recorded.** Only if firewalld or ufw is active, no reload, SSH rules are never read for change or touched. Every rule the script adds is written to `/opt/torrserver/.firewall-added`; leaving a mode or `--uninstall` removes exactly those. Rules that already existed are left alone.
- **Rotate the password:** `sudo ./install.sh --rotate-password` writes a new `accs.db` and a new Caddy hash, recreates the containers and prints the new password once.

## Update

Bump the version (tags: <https://github.com/YouROK/TorrServer/releases>) and, for the digest pin, resolve it from the registry (`docker buildx imagetools inspect ghcr.io/yourok/torrserver:TAG`); an empty `TS_IMAGE_DIGEST=` pins by tag only:

```bash
sudo TS_VERSION=MatriX.148 TS_IMAGE_DIGEST=sha256:... ./install.sh
```

## Uninstall

```bash
sudo ./install.sh --uninstall           # removes containers, timer, firewall rules, WireGuard interface and fail2ban jail it added; keeps data, credentials, VPN keys
sudo ./install.sh --uninstall --purge   # also deletes /opt/torrserver and the Caddy volumes (certificates)
```

## Troubleshooting

- `sudo ./install.sh --status`, `docker logs torrserver`, `docker inspect -f '{{.State.Health.Status}}' torrserver`, `docker compose -f /opt/torrserver/docker-compose.yml config`.
- Certificate not issued: `docker logs torrserver-caddy`. Check that the name resolves to the server (`getent hosts 1-2-3-4.sslip.io`), TCP 80 is reachable from the internet (Hetzner Cloud Firewall too) and the Let's Encrypt limits above.
- Banned yourself: `sudo fail2ban-client set torrserver-caddy unbanip YOUR.IP`.
- 401 with the right password: rerun `sudo ./install.sh` (rewrites `accs.db` from `credentials`).
- Stopping takes about 10 seconds: `TS_DONTKILL=1` makes TorrServer ignore SIGTERM, so Docker waits for the grace period and then kills it.
- SELinux (EL, Fedora, openSUSE): bind mounts use `:z`. Denials show in `ausearch -m avc -ts recent`.
- VPN will not start: `journalctl -u wg-quick@wg0`; the kernel needs the `wireguard` module (in all current kernels; not available inside containers or some OpenVZ/LXC guests).

## Unverified

- **Let's Encrypt for sslip.io was not issued here.** The sandbox has no internet, so a real certificate could not be requested. Caddy's HTTP/HTTPS handling, the redirect on the HTTP port, the random port binding, login at the proxy, headers and the access log were tested with real containers using Caddy's own CA (`TS_TLS=internal`, a test switch). That `<dashed-ip>.sslip.io` resolves and that Let's Encrypt accepts it (and its rate limits for the shared domain) is documented behaviour of both services, not tested here.
- Public IP detection: the Hetzner metadata, route and ipify branches were tested against a local fake server and a stubbed `ip`; the real metadata endpoint was not reached.
- The fail2ban filter was tested with `fail2ban-regex` against a real Caddy log (every 401 matched, nothing else). Starting the jail and the `DOCKER-USER` ban were not run, and the `iptables-multiport` action assumes Docker's iptables rules (not tested on nftables-only or firewalld-only hosts).
- WireGuard: key generation, config rendering, `wg-quick strip`, device add/remove and the Docker bind on the VPN address were run with real `wg` and Docker; the tunnel itself (kernel module, handshake, traffic) was not, because the sandbox kernel has no WireGuard. `systemctl`, `ufw` and `firewall-cmd` were stubs.
- Behaviour of `UseDisk=false` and `RemoveCacheOnDrop` comes from reading the source at MatriX.147.2 and from the settings round trip, not from a real stream with peers. The published ghcr.io image could not be pulled in the sandbox; tests ran on a locally built image of the same tag.
- Not tested on the five server OSes themselves (only on a container host); package-manager paths for `curl`/`jq`/`openssl`/`fail2ban`/`wireguard-tools` are as documented by the distributions.
