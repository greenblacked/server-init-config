# General servers (not runners)

Base setup for a fresh Hetzner server: SSH keys only, admin user `ops` with sudo, a firewall (firewalld on the
Red Hat family, ufw on Ubuntu and Debian) with only SSH open,
fail2ban for SSH, daily automatic security updates (no auto-reboot), Docker Engine + Compose, swap when there is
none, sysctl tuning, journald limit, weekly cleanup, time sync and admin tools (including `mc`, `fd`, `rg`, `fzf`). Root keeps key login on port 22, so the setup cannot
lock you out. Every step is checked before it changes anything, so reruns are safe; a failed step is logged to
`/var/log/server-init-failed.log` and the next step still runs.

Shell: 100000-line history with timestamps, shared between sessions; `Ctrl+R` searches it with fzf and `Ctrl+T` finds files
(`/etc/profile.d/90-server-shell.sh`, interactive bash only; log in again to get it). The text is the same as
`scripts/shell-history.sh`; `tools/test-cloud-init.py` checks that they match.

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
`"80/tcp 443/tcp"`, `INSTALL_DOCKER`, `INSTALL_SWAP`, `TIMEZONE`, the cleanup keys below, and for the Debian script `APP`). Edit the file and rerun
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

## Security tools

Tools to test and audit **your own** servers. Use them only against systems you own or are authorized to test. On Hetzner,
scanning or attacking third-party systems violates their terms: check Hetzner's current policy before you run anything
against a host that is not yours.

```bash
sudo install/security-tools.sh                  # default: --audit --network --scan
sudo install/security-tools.sh --audit --network --scan --kali
sudo install/security-tools.sh --aide --clamav  # opt-in tools; --help lists all and what they cost
```

| Group | Installs |
|---|---|
| `--audit` | lynis, OpenSCAP (EL/Fedora, evaluation only), auditd with a small ruleset, ssh-audit, testssl.sh |
| `--network` | nmap, tcpdump, tshark, iperf3, socat, ncat, whois, dig, lsof, mtr, traceroute, iftop, nethogs, bmon |
| `--scan` | trivy, gitleaks, hadolint, cosign, osv-scanner, trufflehog, dockle: pinned release binaries, SHA256 checked, a mismatch is refused |
| opt-in | `--aide`, `--clamav` (no clamd), `--rkhunter`, `--chkrootkit`, `--arp-scan`, `--grype`, `--syft`, `--k8s` (kubescape, kube-bench) |
| `--kali` | the `kali` command: Kali Linux in a Docker container, built on first use (2-3 GB); needs Docker |
| `--audit-timer` | weekly lynis, oscap, aide and rkhunter reports in `/var/log/security-audit` (idle priority) |

It supports CentOS Stream/Rocky/AlmaLinux 10, Fedora 44, Debian 13 and Ubuntu 26.04, skips what a release does not
package and never fails the run for a missing optional tool. A failed checksum is the exception: that tool is not
installed and the script exits non-zero. Versions are variables at the top of the script.

```bash
sudo lynis audit system                                # hardening report, index in /var/log/lynis-report.dat
sudo oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_standard --report /tmp/oscap.html \
  /usr/share/xml/scap/ssg/content/ssg-rl10-ds.xml      # ssg-almalinux10-ds.xml, ssg-cs10-ds.xml, ssg-fedora-ds.xml; never --remediate
sudo rkhunter --check --sk                             # with --rkhunter
sudo aide --config /etc/security-tools/aide.conf --check   # with --aide
sudo clamscan -r -i /srv                               # with --clamav (needs ~1.2 GB RAM while it runs)
ssh-audit your-host                                    # SSH algorithms and known weaknesses
testssl your-site.example.com:443                      # TLS configuration
nmap -sV your-host                                     # open ports and versions
sudo tshark -i eth0 -c 100 -f 'port 53'                # capture; iftop and nethogs show live traffic
trivy image IMAGE                                      # image CVEs; trivy fs . for a project folder
gitleaks detect -s .                                   # secrets in a repo and its history
trufflehog git file://. --only-verified                # secrets, verified ones only
osv-scanner scan source -r .                           # dependency CVEs
hadolint Dockerfile                                    # Dockerfile lint
dockle IMAGE                                           # image best practices (CIS Docker)
cosign verify --key cosign.pub IMAGE                   # signature check (key or --certificate-identity options)
kubescape scan                                         # with --k8s, against a cluster you own
kube-bench run                                         # with --k8s, run on a node of your own cluster
kali                                                   # shell in the Kali container; then: nmap -sV your-host, nikto -h your-site
```

`kali` runs with `--rm`, on the Docker bridge network (`kali --host-net` for the host network) and without the Docker
socket; files in `/home/kali` live in the volume `kali-home`. `kali update` rebuilds the image, `kali remove` deletes
image and volume. auditd rules only cover the paths that exist when the script runs: rerun it after installing Docker or the runner.

## Health report

`health` gives a one-command status report: system, disk and memory, security, firewall and open ports, fail2ban,
automatic updates, pending reboot, SSH settings, services, Docker and containers, and (only when installed) lynis, rkhunter, AIDE, ClamAV and auditd status. Install it once from a checkout
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

- Ports published by Docker (`-p 8080:80`) bypass firewalld and ufw. Bind to `127.0.0.1:8080:80` unless the port should be public.
- fail2ban bans an IP for 1 hour after 5 failed SSH logins in 10 minutes. An SSH agent that offers many keys can
  trip it; use `IdentitiesOnly yes` for the server in `~/.ssh/config`. To unban from the Hetzner web console:
  `fail2ban-client set sshd unbanip YOUR_IP`.
- Security updates are installed daily (`dnf-automatic`, or `server-update.timer` after `install-tools.sh`), but the server never reboots
  by itself unless `AUTO_REBOOT=1`; kernel updates apply after your next reboot.
