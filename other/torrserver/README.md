# TorrServer in Docker (hardened)

Installs [TorrServer](https://github.com/YouROK/TorrServer) (image `ghcr.io/yourok/torrserver`) with a login, a port that is closed to the internet, no seeding, and a cleanup of downloads every 3 days. Only download content you have the right to.

Works on Rocky/Alma/CentOS Stream 10, Fedora 44, Debian 13, Ubuntu 26.04 and openSUSE 16. Docker Engine with the compose plugin must already be installed (the script stops with a clear message if not). It installs `curl`, `jq` and `openssl` if they are missing.

```bash
sudo ./install.sh              # install or update; prints the login once
sudo ./install.sh --help
```

## What you get

| Part | Detail |
|---|---|
| Image | `ghcr.io/yourok/torrserver:MatriX.147.2@sha256:056e0cf1...` (tag and digest, never `:latest`). Change `TS_VERSION` / `TS_IMAGE_DIGEST` to update |
| Login | HTTP basic auth on (`TS_HTTPAUTH=1`), user `torrserver`, random 32-character password |
| Port | `127.0.0.1:8090` only. Reach it through an SSH tunnel, or publish it with TLS using `--public` |
| Container | non-root (10001), read-only root filesystem, `/tmp` as tmpfs, all capabilities dropped, `no-new-privileges`, 512 processes max, 3 GB RAM (no extra swap), 2 CPUs, log rotation (3 x 10 MB), healthcheck on `/echo` |
| Sharing | upload disabled, UPnP/LPD/DLNA/Bonjour off |
| Cleanup | systemd timer every 3 days |

Files on the server (`/opt/torrserver`, change with `TS_DIR`):

```
docker-compose.yml  .env  Caddyfile  cleanup.sh    managed by install.sh, rewritten on every run
credentials                                         root:root 0600, the only copy of the password you read
data/config/        accs.db (login), config.db, settings.json
data/downloads/     downloaded pieces (what the cleanup deletes)
data/log            TorrServer log
```

## Security model

- **Localhost by default.** The container port is published as `127.0.0.1:8090:8090`. Docker's published ports bypass firewalld and ufw, so binding to localhost is the control that counts; a firewall rule would not stop `0.0.0.0`.
- **Tunnel from your laptop** (basic auth over plain HTTP is only acceptable inside the tunnel):

  ```bash
  ssh -L 8090:127.0.0.1:8090 ops@SERVER     # then open http://127.0.0.1:8090/
  ```

- **Login.** TorrServer keeps users in `data/config/accs.db`, a JSON object `{"user":"password"}` read at start. The password is stored there in plain text; this is how TorrServer works (checked in `server/web/auth/auth.go`). The file is owned by the container user with mode 0600 in a 0750 directory. The generated password lives in `/opt/torrserver/credentials` (root, 0600) and is printed once at install. If `accs.db` is missing, TorrServer answers 401 to everything (it fails closed). `/echo` (version string) is the only path that answers without a login; it is what the healthcheck uses.
- **Rotate the password:** `sudo ./install.sh --rotate-password`. It writes a new `accs.db`, recreates the container (it only reads the file at start) and prints the new password once.
- **Public with TLS:** `sudo ./install.sh --public --domain ts.example.com --acme-email you@example.com`. It adds a Caddy container (HTTPS, automatic certificates) on 80/443 that proxies to TorrServer over the compose network. TorrServer itself stays on 127.0.0.1. `--public` without a domain is refused. Needs a DNS A/AAAA record for the domain pointing at the server, and TCP 80 and 443 reachable: the script opens them in firewalld or ufw (only if active, additively, no reload, never touching SSH rules, and it records what it added so `--private` and `--uninstall` remove exactly those). Also allow TCP 80 and 443 in the **Hetzner Cloud Firewall**. Go back to localhost-only with `./install.sh --private`.
- The login still protects the public URL; use the generated password, not a short one.

## Settings applied (no seeding)

TorrServer has no "stop after complete" switch. The closest, strict behaviour is: never upload, and close the torrent when nobody uses it. `install.sh` reads the current settings from the API (`POST /settings {"action":"get"}`), changes only the keys below and sends them back with `"action":"set"`, from the host to 127.0.0.1 with the generated login. Rerunning changes nothing if they already match. Key names are the fields of `BTSets` in `server/settings/btsets.go`.

| Key | Value | Effect |
|---|---|---|
| `DisableUpload` | `true` | maps to the torrent client's `NoUpload` (`torr/btserver.go`): no data is sent to peers, so completed torrents are not seeded. Downloads can be a bit slower because peers rank leechers lower |
| `UseDisk` | `true` | pieces are stored on disk instead of RAM, which makes "downloads" exist as files |
| `TorrentsSavePath` | `/opt/ts/downloads` | = `data/downloads` on the host, the folder the timer cleans |
| `RemoveCacheOnDrop` | `true` | when a torrent is dropped or removed, its pieces are deleted |
| `CacheSize` | 2048 MB (`TS_CACHE_MB`) | cache size limit |
| `TorrentDisconnectTimeout` | 120 s (`TS_IDLE_SECONDS`) | a torrent nobody reads for this long is closed, which ends its peer connections |
| `DisableUPNP` | `true` | do not ask the router to open ports |
| `EnableLPD`, `EnableDLNA`, `EnableBonjour` | `false` | no local-network announcements or media server |
| `EnableDebug` | `false` | no debug logging |

DHT and PEX stay on so torrents can find peers; with upload disabled they do not give anyone data. Settings are saved by TorrServer in `data/config/config.db` and `settings.json`. Verify: `curl -u torrserver:PASSWORD -X POST -d '{"action":"get"}' http://127.0.0.1:8090/settings | jq .DisableUpload`.

## Cleanup every 3 days

`torrserver-cleanup.timer` runs `cleanup.sh` (as a oneshot service, output in the journal: `journalctl -u torrserver-cleanup`).

1. If TorrServer answers: `drop` every loaded torrent (closes peers) and `rem` torrents added more than 3 days ago (deletes the entry and its cache).
2. Delete files in `data/downloads` last modified more than 3 days ago, then empty directories of that age. Old symlinks are removed, never followed. It stays on one filesystem and checks that the target really is `data/downloads`.

It never touches `data/config`, the log, `credentials` or `.env`. If the container is down it only does step 2. If the container is running but the API cannot be used (for example after a manual password edit) it deletes nothing and exits with an error. Try it first: `sudo /opt/torrserver/cleanup.sh --dry-run`. `CLEAN_DAYS` or `--days N` change the age.

Why `OnBootSec=1h` + `OnUnitActiveSec=3d` and not `OnCalendar`: a calendar step like `*-*-01/3` restarts every month (31st to 1st is a one-day gap) and `Persistent=true` only works with `OnCalendar`. The monotonic pair gives exactly 3 days between runs and a run 1 hour after any boot. The first run most likely happens right after install (the boot offset has already passed; nothing is old yet). Files are checked every 3 days and deleted when older than 3 days, so a file lives 3 to 6 days.

## Update

Bump the version (find tags at <https://github.com/YouROK/TorrServer/releases>) and, if you want the digest pin, resolve it from the registry (`docker buildx imagetools inspect ghcr.io/yourok/torrserver:TAG`); an empty `TS_IMAGE_DIGEST=` pins by tag only:

```bash
sudo TS_VERSION=MatriX.148 TS_IMAGE_DIGEST=sha256:... ./install.sh
```

## Uninstall

```bash
sudo ./install.sh --uninstall           # stops and removes containers, timer, firewall rules it added; keeps data and credentials
sudo ./install.sh --uninstall --purge   # also deletes /opt/torrserver and the Caddy volumes
```

## Troubleshooting

- `docker logs torrserver`, `docker inspect -f '{{.State.Health.Status}}' torrserver`, `docker compose -f /opt/torrserver/docker-compose.yml config`.
- 401 with the right password: rerun `sudo ./install.sh` (rewrites `accs.db` from `credentials`).
- Stopping takes about 10 seconds: `TS_DONTKILL=1` (from the original compose file) makes TorrServer ignore SIGTERM, so Docker waits for the grace period and then kills it.
- Resource limits: the plain-compose keys `mem_limit`, `cpus` are used (`deploy.resources` belongs to swarm). Check with `docker inspect -f '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}' torrserver`.
- SELinux (EL, Fedora, openSUSE): the data mount uses `:z`, which labels it `container_file_t`. Denials show in `ausearch -m avc -ts recent`.
- Caddy cannot get a certificate: check DNS, ports 80/443 in the Hetzner firewall, and `docker logs torrserver-caddy`.

## Unverified

- Behaviour of `RemoveCacheOnDrop` and the disk cache layout (`<TorrentsSavePath>/<infohash>/<piece>`) comes from reading the source at MatriX.147.2, not from a real download with peers.
- The container tests ran on an image built from the same source tag and `docker-entrypoint.sh` (the ghcr.io blob host is blocked in the build sandbox, so the published image was not pulled); ffmpeg is not in that image, and the digest above was read from the registry manifest only.
- Not tested on the five server OSes themselves (only on a container host); the package manager paths for `curl`/`jq`/`openssl` and the firewalld/ufw branches were tested with stubs.
