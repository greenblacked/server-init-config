# General servers (not runners)

Base setup for a fresh Hetzner server: SSH keys only, admin user `ops` with sudo, firewalld with only SSH open,
fail2ban for SSH, daily automatic security updates (no auto-reboot), Docker Engine + Compose, swap when there is
none, sysctl tuning, journald limit, weekly cleanup, chrony and admin tools (including `mc`, `fd`, `rg`, `fzf`). Root keeps key login on port 22, so the setup cannot
lock you out. Every step is checked before it changes anything, so reruns are safe; a failed step is logged to
`/var/log/server-init-failed.log` and the next step still runs.

Shell: 100000-line history with timestamps, shared between sessions; `Ctrl+R` searches it with fzf and `Ctrl+T` finds files
(`/etc/profile.d/90-server-shell.sh`, interactive bash only; log in again to get it). The text is the same as
`scripts/shell-history.sh`; `tools/test-cloud-init.py` checks that they match.

| Script | OS |
|---|---|
| `server-init-fedora.sh` | Fedora 44 |
| `server-init-el10.sh` | CentOS Stream 10, Rocky Linux 10, AlmaLinux 10 |

Both run on x86_64 and ARM64. The script refuses to run on an OS it is not written for.

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
# paste the content of server/server-init-el10.sh (or -fedora.sh) here
SERVERINIT
chmod 0755 /usr/local/sbin/server-init.sh && /usr/local/sbin/server-init.sh
```

Settings are saved to `/etc/server-init.conf` on the first run (`ADMIN_USER`, `EXTRA_PORTS` such as
`"80/tcp 443/tcp"`, `INSTALL_DOCKER`, `INSTALL_SWAP`, `TIMEZONE`, and the cleanup keys below). Edit the file and rerun
`/usr/local/sbin/server-init.sh` to change them. An existing conf is never rewritten: keys it lacks use the defaults.

## Cleanup

The `cleanup` step installs `/usr/local/sbin/server-cleanup` and a weekly systemd timer (`server-cleanup.timer`,
random delay up to 1 h, runs missed jobs after boot). It runs niced with idle IO priority and `ProtectHome=read-only`.
The tool is `server/server-cleanup.sh`; the same text is embedded in both init scripts and in the Cloud config
(`tools/test-cloud-init.py` checks the copies match).

What it does (each part is skipped when its tool is missing):

- journald: `journalctl --vacuum-time` and `--vacuum-size`.
- packages: `dnf clean packages`; sets `installonly_limit=3` in `/etc/dnf/dnf.conf` if unset (dnf then drops old
  kernels itself, never the running one); `dnf autoremove` only with `CLEAN_AUTOREMOVE=1`.
- Docker (only if running): stopped containers and build cache older than 7 days, dangling images. Never volumes, never
  `docker system prune -a`. `CLEAN_DOCKER_UNUSED_IMAGES=1` also prunes unused images older than 30 days.
- temp: `systemd-tmpfiles --clean` for `/tmp` and `/var/tmp`, so the system's own age rules apply (10 days for `/tmp`,
  30 for `/var/tmp` on Fedora and EL).
- `/var/log/*.gz` and `*.[0-9]` older than 30 days; core dumps older than 7 days; `/var/crash` and `/var/spool/abrt` older than 30 days.
- It never touches `/home`, `/root`, `/srv`, `/opt`, Docker volumes, databases or the repo.

```bash
sudo server-cleanup --dry-run          # print the plan, change nothing
sudo server-cleanup                    # run now
systemctl list-timers server-cleanup.timer
journalctl -u server-cleanup.service -n 30
```

Disable: set `INSTALL_CLEANUP=0` in `/etc/server-init.conf` and rerun `server-init.sh` (it disables the timer), or
`sudo systemctl disable --now server-cleanup.timer`.

| Setting (`/etc/server-init.conf`) | Default | Meaning |
|---|---|---|
| `INSTALL_CLEANUP` | `1` | `0` disables the timer |
| `CLEAN_SCHEDULE` | `weekly` | systemd `OnCalendar` value |
| `CLEAN_JOURNAL_TIME` / `CLEAN_JOURNAL_SIZE` | `1month` / `500M` | journal vacuum limits |
| `CLEAN_AUTOREMOVE` | `0` | `1` runs `dnf autoremove` (can remove wanted packages) |
| `CLEAN_DOCKER_UNUSED_IMAGES` | `0` | `1` prunes unused images older than 30 days |

Exit codes: 0 ok, 1 not root, 2 bad option, 3 an action failed (details in the log, tag `server-cleanup`).

## Daily use: `srv` and the maintenance tools

The cleanup step is part of the init scripts. The rest of the tools are not embedded in the Cloud config (Hetzner's
limit is 32 KiB); install them once from a checkout of this repo, after the init script ran:

```bash
sudo server/install-tools.sh
```

It installs `srv`, `server-update`, `server-notify`, `server-disk-guard`, `health` (via `install-health.sh`), the login
summary and three timers. Rerun it after changing settings. Everything goes through one command:

| Command | What it does |
|---|---|
| `srv status` | short health summary, fresh (`health --brief`) |
| `srv health [-q]` | full health report |
| `srv update [--check\|--security\|--reboot]` | update packages, then clean up, then report if a reboot is needed |
| `srv clean [--dry-run]` | `server-cleanup` |
| `srv logs` | last runs of update, cleanup and disk guard from the journal |
| `srv timers` | state and next run of the timers |
| `srv notify-test` | send a test notification |

`srv` re-runs itself through passwordless `sudo`. `srv update --check` lists updates (exit 100 when there are some);
it never reboots unless you pass `--reboot`, and then only when a reboot is needed.

Timers (all systemd timers, no cron needed):

| Timer | When | Does |
|---|---|---|
| `server-cleanup.timer` | weekly | `server-cleanup` |
| `server-update.timer` | daily 04:30 (+ up to 30 min) | `server-update --security`, then cleanup. Replaces `dnf-automatic`: `install-tools.sh` disables its timer, because two updaters would fight over the dnf lock. `UPDATE_SCHEDULE=off` gives it back. |
| `server-disk-guard.timer` | every 30 min | runs `server-cleanup` when `/` is at least `DISK_CLEAN_THRESHOLD` % full, at most once per `DISK_CLEAN_COOLDOWN_H` hours; notifies if still above after |
| `server-health-brief.timer` | every 15 min | writes the login summary (`/var/lib/server-health/brief.txt`); runs a full health report at most every 6 hours |

The server never reboots by itself unless `AUTO_REBOOT=1`; then only the daily timer run reboots, and only when a reboot is needed.

When the admin user logs in interactively, the cached summary is printed (about 7 lines: load, disk and memory with
WARN/FAIL marks, firewall, banned IPs, pending updates and reboot, last update and cleanup, result of the last full
report). It only prints a file, so it is instant; scp, rsync and sftp are unaffected.

| Setting (`/etc/server-init.conf`) | Default | Meaning |
|---|---|---|
| `UPDATE_SCHEDULE` | `*-*-* 04:30` | `OnCalendar` of the daily update; `off` keeps `dnf-automatic` instead |
| `AUTO_REBOOT` | `0` | `1`: the daily update reboots when needed |
| `LOGIN_SUMMARY` | `1` | `0`: no summary at login |
| `DISK_CLEAN_THRESHOLD` / `DISK_CLEAN_COOLDOWN_H` | `85` / `6` | disk guard limit in percent / minimum hours between runs |

`install-tools.sh` appends these as commented lines to the conf; uncomment to change, then rerun it.

### Notifications (optional, off by default)

After an update, a cleanup, a disk guard alarm, a failed full health run or a pending reboot, `server-notify` sends a short
message to the first channel set in `/etc/server-init.d/notify.env` (created by `install-tools.sh` as a commented
template, root-only, mode 0600; ignored if it is not): `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`, `SLACK_WEBHOOK_URL` or
`MAIL_TO` (needs `mail` or `sendmail`). Test with `srv notify-test`. Secrets are never printed or logged; curl gets the
URL and data on stdin, not in its arguments, with `--fail --max-time 10`. The Telegram token is part of the URL, so
root can see it only inside the curl process's stdin during the call. A failed notification is logged and never fails the job.

## Cloud config (new servers)

| File | OS |
|---|---|
| `cloud-init/server-fedora.yaml` | Fedora 44 |
| `cloud-init/server-el10.yaml` | CentOS Stream 10, Rocky Linux 10, AlmaLinux 10 |

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
systemctl is-active firewalld fail2ban chronyd docker; firewall-cmd --list-services; firewall-cmd --list-ports; fail2ban-client status sshd | tail -3; systemctl list-timers '*automatic*' --no-pager | head -3; swapon --show
```

From a second terminal, before you log out:

```bash
ssh ops@SERVER_IP 'sudo -n true && echo sudo-ok'
```

## Health report

`health` gives a one-command status report: system, disk and memory, security, firewall and open ports, fail2ban,
automatic updates, pending reboot, SSH settings, services, Docker and containers. Install it once from a checkout
of this repo on the server (`sudo server/install-tools.sh` does this too):

```bash
sudo server/install-health.sh
```

Then, as your admin user (`ops`), no `sudo` needed:

```bash
health -q
```

`-q` skips the slow checks; `health` without it runs everything. It re-runs itself through passwordless sudo
when you are not root; without sudo rights it still runs and skips only the root-only checks. On a plain server
the GitLab Runner checks are skipped; they run only when a runner is registered (or with `--profile runner`).
It is not embedded in the Cloud config files: it is about 30 KB and Hetzner's user-data limit is 32 KiB.

## Notes

- Ports published by Docker (`-p 8080:80`) bypass firewalld. Bind to `127.0.0.1:8080:80` unless the port should be public.
- fail2ban bans an IP for 1 hour after 5 failed SSH logins in 10 minutes. An SSH agent that offers many keys can
  trip it; use `IdentitiesOnly yes` for the server in `~/.ssh/config`. To unban from the Hetzner web console:
  `fail2ban-client set sshd unbanip YOUR_IP`.
- Security updates are installed daily (`dnf-automatic`, or `server-update.timer` after `install-tools.sh`), but the server never reboots
  by itself unless `AUTO_REBOOT=1`; kernel updates apply after your next reboot.
