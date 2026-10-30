# General servers (not runners)

Base setup for a fresh Hetzner server: SSH keys only, admin user `ops` with sudo, firewalld with only SSH open,
fail2ban for SSH, daily automatic security updates (no auto-reboot), Docker Engine + Compose, swap when there is
none, sysctl tuning, journald limit, chrony and admin tools. Root keeps key login on port 22, so the setup cannot
lock you out. Every step is checked before it changes anything, so reruns are safe; a failed step is logged to
`/var/log/server-init-failed.log` and the next step still runs.

| Script | OS |
|---|---|
| `server-init-fedora.sh` | Fedora 44 |
| `server-init-el10.sh` | CentOS Stream 10, Rocky Linux 10, AlmaLinux 10 |
| `server-init-opensuse.sh` | openSUSE Leap 16.0 |

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
# paste the content of server/server-init-el10.sh (or -fedora.sh, -opensuse.sh) here
SERVERINIT
chmod 0755 /usr/local/sbin/server-init.sh && /usr/local/sbin/server-init.sh
```

Settings are saved to `/etc/server-init.conf` on the first run (`ADMIN_USER`, `EXTRA_PORTS` such as
`"80/tcp 443/tcp"`, `INSTALL_DOCKER`, `INSTALL_SWAP`, `TIMEZONE`). Edit the file and rerun
`/usr/local/sbin/server-init.sh` to change them.

## Cloud config (new servers)

| File | OS |
|---|---|
| `cloud-init/server-fedora.yaml` | Fedora 44 |
| `cloud-init/server-el10.yaml` | CentOS Stream 10, Rocky Linux 10, AlmaLinux 10 |
| `cloud-init/server-opensuse.yaml` | openSUSE Leap 16.0 |

Paste the file for the server's OS into Hetzner Console, **Cloud config**, when you create the server. It is
user-data for cloud-init, not shell commands: never paste it into a terminal. If you need ports or other
settings, edit the `/etc/server-init.conf` block at the top of the file first. The file embeds the script, so it
is generated (`tools/render-cloud-init.py`) and must not be edited except for that block. After the first boot:

```bash
ssh root@SERVER_IP 'cloud-init status --wait'
```

Then run the commands under [Check](#check).

## Check

```bash
cat /var/log/server-init-failed.log 2>/dev/null || echo no-failures
```

```bash
systemctl is-active firewalld fail2ban chronyd docker; firewall-cmd --list-services; firewall-cmd --list-ports; fail2ban-client status sshd | tail -3; systemctl list-timers '*automatic*' '*security-updates*' --no-pager | head -3; swapon --show
```

From a second terminal, before you log out:

```bash
ssh ops@SERVER_IP 'sudo -n true && echo sudo-ok'
```

## Notes

- Ports published by Docker (`-p 8080:80`) bypass firewalld. Bind to `127.0.0.1:8080:80` unless the port should be public.
- fail2ban bans an IP for 1 hour after 5 failed SSH logins in 10 minutes. An SSH agent that offers many keys can
  trip it; use `IdentitiesOnly yes` for the server in `~/.ssh/config`. To unban from the Hetzner web console:
  `fail2ban-client set sshd unbanip YOUR_IP`.
- Security updates are installed daily, but the server never reboots by itself; kernel updates apply after your next reboot.

### openSUSE Leap 16

- Packages come from the openSUSE repositories only (no repository is added). Docker CE has no openSUSE repository,
  so Docker and Compose are the distribution's `docker` and `docker-compose` packages.
- Security updates: the script installs a systemd timer `server-security-updates.timer` that runs
  `zypper patch --category security` daily. Check it with `systemctl list-timers server-security-updates.timer`.
- Swap on btrfs (the default root with snapper snapshots) lives in its own `/swap` subvolume, because a swap file
  cannot be in a snapshotted subvolume. After a snapper rollback `/swap` comes back as an empty plain directory;
  rerun the script and it replaces that empty directory with a new subvolume and swap file (a non-empty `/swap` that
  is not a subvolume is left alone and the swap step fails with a logged message).
- If `fail2ban` is not available in the repositories, that step is logged to `/var/log/server-init-failed.log` and skipped.
