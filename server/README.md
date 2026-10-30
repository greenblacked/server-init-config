# General servers (not runners)

Base setup for a fresh Hetzner server: SSH keys only, admin user `ops` with sudo, a firewall (firewalld on the
Red Hat family, ufw on Ubuntu and Debian) with only SSH open,
fail2ban for SSH, daily automatic security updates (no auto-reboot), Docker Engine + Compose, swap when there is
none, sysctl tuning, journald limit, time sync and admin tools. Root keeps key login on port 22, so the setup cannot
lock you out. Every step is checked before it changes anything, so reruns are safe; a failed step is logged to
`/var/log/server-init-failed.log` and the next step still runs.

| Script | OS |
|---|---|
| `server-init-fedora.sh` | Fedora 44 |
| `server-init-el10.sh` | CentOS Stream 10, Rocky Linux 10, AlmaLinux 10 |
| `server-init-debian.sh` | Ubuntu 26.04, Ubuntu 24.04, Debian 13 (also the Hetzner Apps images, see [Hetzner Apps](#hetzner-apps-images)) |

All run on x86_64 and ARM64. The script refuses to run on an OS it is not written for.

## Run it

From your laptop, in this repo (pick the script for the server's OS):

```bash
scp server/server-init-el10.sh root@SERVER_IP:/usr/local/sbin/server-init.sh
```

```bash
ssh root@SERVER_IP 'chmod 0755 /usr/local/sbin/server-init.sh && ADMIN_USER=ops EXTRA_PORTS="" /usr/local/sbin/server-init.sh'
```

Or paste it on the server as root, without a copy of the repo:

```bash
cat > /usr/local/sbin/server-init.sh <<'SERVERINIT'
# paste the content of server/server-init-el10.sh (or -fedora.sh, -debian.sh) here
SERVERINIT
chmod 0755 /usr/local/sbin/server-init.sh && /usr/local/sbin/server-init.sh
```

Settings are saved to `/etc/server-init.conf` on the first run (`ADMIN_USER`, `EXTRA_PORTS` such as
`"80/tcp 443/tcp"`, `INSTALL_DOCKER`, `INSTALL_SWAP`, `TIMEZONE`, and for the Debian script `APP`). Edit the file and rerun
`/usr/local/sbin/server-init.sh` to change them.

## Cloud config (new servers)

| File | OS |
|---|---|
| `cloud-init/server-fedora.yaml` | Fedora 44 |
| `cloud-init/server-el10.yaml` | CentOS Stream 10, Rocky Linux 10, AlmaLinux 10 |
| `cloud-init/server-debian.yaml` | Ubuntu 26.04, Ubuntu 24.04, Debian 13 |

Paste the file for the server's OS into Hetzner Console, **Cloud config**, when you create the server. It is
user-data for cloud-init, not shell commands: never paste it into a terminal. If you need ports or other
settings, edit the `/etc/server-init.conf` block at the top of the file first. The file embeds the script, so it
is generated (`tools/render-cloud-init.py`) and must not be edited except for that block. After the first boot:

```bash
ssh root@SERVER_IP 'cloud-init status --wait'
```

Then run the commands under [Check](#check).

## Ubuntu and Debian

`server-init-debian.sh` uses apt non-interactively and these components:

| Component | What it does |
|---|---|
| Firewall | `ufw`. SSH (`22/tcp`) is saved in the rules and checked in `ufw show added` before ufw is enabled, and checked again in `ufw status` afterwards (if it is missing, ufw is switched off again). `deny incoming` / `allow outgoing` are set only when ufw is switched on for the first time. An already active ufw keeps its defaults and rules: the script only adds rules and never runs `ufw reset`. |
| Automatic updates | `unattended-upgrades`, security origin only (`/etc/apt/apt.conf.d/20auto-upgrades` and `52server-init-unattended`), `Automatic-Reboot "false"`. |
| fail2ban | journal backend (Debian 13 has no `/var/log/auth.log`), `python3-systemd`, bans through nftables, which works whether or not ufw is active. |
| Docker | `download.docker.com` repo for `ubuntu` or `debian` (key in `/etc/apt/keyrings`, architecture and codename from the system). If Docker has no repo for the codename, the distro packages `docker.io` + Compose (`docker-compose-v2` on Ubuntu, `docker-compose` on Debian) are used; the log says which. |
| SSH | drop-in `00-hardening.conf`, checked with `sshd -t`. On Ubuntu the service is `ssh` (it may be socket activated): a running service is reloaded, otherwise the next connection already reads the drop-in. |
| Time sync | keeps `systemd-timesyncd` or `chrony` if one is running, installs `chrony` only if neither is. |
| Swap | `fallocate` on ext4 (falls back to `dd`), `btrfs filesystem mkswapfile` on btrfs, only when there is no swap at all. |

## Hetzner Apps images

The [Hetzner Apps](https://github.com/hetznercloud/apps) (Coolify, Docker CE, GitLab CE, Jitsi Meet, LAMP,
Nextcloud, Owncast, PhotoPrism, Prometheus Grafana, RustDesk, WireGuard, WordPress) are Ubuntu 24.04 images with the software preinstalled, so
`server-init-debian.sh` accepts Ubuntu 24.04 as well as 26.04. With `APP=auto` (default in
`/etc/server-init.conf`) it recognises the image by the files and packages that repo installs and then:

- never reinstalls or reconfigures Docker when `docker` exists (no `daemon.json` is written either),
- never touches the app's own configuration,
- keeps all existing firewall rules and adds only the app's documented ports to ufw.

| APP | Marker | Ports opened (source in `apps/hetzner/<app>/`) |
|---|---|---|
| `coolify` | `/data/coolify` or `/opt/hcloud/coolify_setup.sh` | `8000/tcp` (`test.sh`) |
| `docker-ce` | `/etc/apt/preferences.d/docker-ce.pref` and `docker.list` | none |
| `gitlab` | package `gitlab-ce` or `/opt/hcloud/gitlab_setup.sh` | `80/tcp 443/tcp` |
| `jitsi` | package `jitsi-meet` or `/opt/hcloud/jitsi_setup.sh` | `80/tcp 443/tcp 10000/udp` (videobridge media), plus `3478/udp 5349/tcp` when `coturn` is installed |
| `lamp` | `/opt/hcloud/lamp_setup.sh` | `80/tcp 443/tcp` |
| `nextcloud` | `/opt/hcloud/nextcloud_setup.sh` | `80/tcp 443/tcp` |
| `wordpress` | `/opt/hcloud/wp_setup.sh` | `80/tcp 443/tcp` |
| `wireguard` | `/opt/hcloud/wireguard_setup.sh` or `/etc/default/wireguard-ui` | `51820/udp 80/tcp 443/tcp`, but ufw is **not** enabled (see below) |
| `owncast` | `/opt/containers/owncast/docker-compose.yml` | `80/tcp 443/tcp 1935/tcp` |
| `photoprism` | `/opt/containers/photoprism/docker-compose.yml` | `80/tcp 443/tcp 2342/tcp` |
| `prometheus-grafana` | `/opt/containers/prometheus-grafana/docker-compose.yml` | `80/tcp 443/tcp` |
| `rustdesk` | `/opt/containers/rustdesk/docker-compose.yml` | `21115-21119/tcp`, `21116/udp` |

Anything else (for example Coolify's own proxy ports) goes into `EXTRA_PORTS`. Set `APP=none` to ignore app
detection, or name the app to force its ports.

- **WireGuard** image: its `/etc/nftables.conf` starts with `flush ruleset` and `nftables.service` is enabled, which
  could wipe ufw's and fail2ban's tables at boot. The script therefore leaves ufw off there and logs the ports.
- **Unrecognised Hetzner app** (`/opt/hcloud/*_setup.sh` or the `001_onboot` script exists but is not in the table):
  the firewall step does not enable ufw, logs why and fails, so the app's public service is never blocked by guesswork.
  Set `APP=none` plus `EXTRA_PORTS` in `/etc/server-init.conf` and rerun to take over the firewall yourself.

For the other apps the app repo configures no ufw rules, so the first run switches ufw on with SSH and these ports. Hetzner Cloud Firewalls, if you use them, are separate and unaffected.

## Check

```bash
cat /var/log/server-init-failed.log 2>/dev/null || echo no-failures
```

```bash
systemctl is-active firewalld fail2ban chronyd docker; firewall-cmd --list-services; firewall-cmd --list-ports; fail2ban-client status sshd | tail -3; systemctl list-timers '*automatic*' --no-pager | head -3; swapon --show
```

On Ubuntu and Debian:

```bash
systemctl is-active fail2ban docker; ufw status; fail2ban-client status sshd | tail -3; systemctl list-timers 'apt-daily*' --no-pager | head -4; swapon --show
```

From a second terminal, before you log out:

```bash
ssh ops@SERVER_IP 'sudo -n true && echo sudo-ok'
```

## Notes

- Ports published by Docker (`-p 8080:80`) bypass firewalld and ufw. Bind to `127.0.0.1:8080:80` unless the port should be public.
- fail2ban bans an IP for 1 hour after 5 failed SSH logins in 10 minutes. An SSH agent that offers many keys can
  trip it; use `IdentitiesOnly yes` for the server in `~/.ssh/config`. To unban from the Hetzner web console:
  `fail2ban-client set sshd unbanip YOUR_IP`.
- Security updates are installed daily, but the server never reboots by itself; kernel updates apply after your next reboot.
