# Plain servers (no GitLab Runner)

A fresh Hetzner server with SSH keys only, an admin user `ops` with sudo, a firewall with only SSH open, fail2ban, daily security updates (no automatic reboot), Docker Engine and Compose, swap if there is none, sysctl tuning and kernel hardening, core dumps off, time sync, a journald limit, a weekly cleanup (not on Ubuntu and Debian) and admin tools. Root keeps key login on port 22, so nothing here can lock you out. Every step is checked before it changes anything, so reruns are safe; a failed step is logged to `/var/log/server-init-failed.log` and the next step still runs. For a GitLab Runner host see [../runner/README.md](../runner/README.md).

| Script | OS |
|---|---|
| `server-init-fedora.sh` | Fedora 44 |
| `server-init-el10.sh` | CentOS Stream 10, Rocky Linux 10, AlmaLinux 10 |
| `server-init-debian.sh` | Ubuntu 26.04, Debian 13, and the Hetzner Apps images (Ubuntu 24.04) |
| `server-init-opensuse.sh` | openSUSE Leap 16.0 |

All run on x86_64 and ARM64 and refuse to run on any other OS.

## Set up a server

1. In the Hetzner Console create the server with your SSH key. Optionally paste the matching file from `cloud-init/` as **Cloud config** (see [Cloud config](#cloud-config)). Add a Cloud Firewall: inbound TCP 22 from your IP, plus any port you publish (80, 443). The host firewall below is a second layer; the Cloud Firewall also covers ports that Docker publishes.
2. Accept the host key once. Laptop, any directory:

   ```bash
   ssh root@SERVER_IP true
   ```

3. Bootstrap. Laptop, repo root, clean checkout:

   ```bash
   server/bootstrap.sh SERVER_IP
   ```

4. Test the admin login from a second terminal. Laptop, any directory:

   ```bash
   ssh ops@SERVER_IP 'sudo -n true && echo ok'
   ```

The bootstrap waits for cloud-init, streams `server/` and `common/` of `git HEAD` to `/root/server-init-config` over SSH (nothing is cloned on the server and no credential goes there; the alternative is a bootstrap-free local install on the server, as root: `git clone https://github.com/greenblacked/server-init-config /root/server-init-config`, then the `server-init-*.sh` for your OS from `/root/server-init-config/server`, then `server/install-tools.sh` on Fedora and EL or `server/install-health.sh` elsewhere, which install `health`, `srv`, `server-update`, the disk guard and the timers), runs the `server-init-*.sh` for the OS in `/etc/os-release`, installs `health` (plus the maintenance tools on Fedora and EL) and ends with `health`. It never installs a runner. Options: `--user`, `--port`, `--os`, `--allow-dirty`, `--continue-degraded`, `--dry-run`. `ADMIN_USER`, `EXTRA_PORTS` (for example `"80/tcp 443/tcp"`), `TIMEZONE`, `INSTALL_DOCKER`, `INSTALL_SWAP`, `INSTALL_CLEANUP` and `APP` in the environment are saved to `/etc/server-init.conf` on the first run; edit that file and rerun the bootstrap to change them. An existing conf is never rewritten: missing keys use the defaults.

Example with open web ports. Laptop, repo root:

```bash
EXTRA_PORTS="80/tcp 443/tcp" server/bootstrap.sh SERVER_IP
```

## Daily use

Server, as `ops`, any directory:

```bash
health -q
```

`health` reports system, disk and memory, security, firewall and open ports, fail2ban, updates, pending reboot, SSH settings, services, Docker and containers, and lynis, rkhunter, AIDE, ClamAV and auditd when installed. `-q` skips the slow checks; exit code 0 ok, 1 warnings, 2 failures. It re-runs itself through passwordless sudo and skips only root-only checks without it. GitLab Runner checks run only when a runner is registered (or with `--profile runner`). It is about 52 KB, so it is not embedded in the Cloud config (32 KiB limit); the bootstrap installs it.

On Fedora and EL the bootstrap also installs the maintenance tools; `srv` is the one entry point:

| Command | Does |
|---|---|
| `srv status` | short health summary, fresh (`health --brief`) |
| `srv health [-q]` | full health report |
| `srv update [--check\|--security\|--reboot]` | update packages, clean up, report if a reboot is needed; `--check` lists updates (exit 100 when there are some); never reboots unless `--reboot` |
| `srv clean [--dry-run]` | `server-cleanup` |
| `srv logs` | last runs of update, cleanup and disk guard |
| `srv timers` | state and next run of the timers |
| `srv notify-test` | send a test notification |

When the admin logs in, a cached summary of about 7 lines is printed: load, disk and memory with WARN/FAIL marks, firewall, banned IPs, pending updates and reboot, last update and cleanup, result of the last full report. It only prints a file, so it is instant; scp, rsync and sftp are unaffected. On Ubuntu, Debian and openSUSE there is `health`, the init's cleanup (openSUSE) and the distro's update timers.

<details>
<summary>Timers and settings of the maintenance tools (Fedora and EL)</summary>

| Timer | When | Does |
|---|---|---|
| `server-cleanup.timer` | weekly | `server-cleanup` |
| `server-update.timer` | daily 04:30 (+ up to 30 min) | `server-update --security`, then cleanup. Replaces `dnf-automatic` (two updaters would fight over the dnf lock); `UPDATE_SCHEDULE=off` gives it back |
| `server-disk-guard.timer` | every 30 min | runs `server-cleanup` when `/` is at least `DISK_CLEAN_THRESHOLD` % full, at most once per `DISK_CLEAN_COOLDOWN_H` hours; notifies if still above |
| `server-health-brief.timer` | every 15 min | writes the login summary; a full report at most every 6 hours |

| Setting (`/etc/server-init.conf`) | Default | Meaning |
|---|---|---|
| `UPDATE_SCHEDULE` | `*-*-* 04:30` | `OnCalendar` of the daily update; `off` keeps `dnf-automatic` |
| `AUTO_REBOOT` | `0` | `1`: the daily update reboots when needed |
| `LOGIN_SUMMARY` | `1` | `0`: no summary at login |
| `DISK_CLEAN_THRESHOLD` / `DISK_CLEAN_COOLDOWN_H` | `85` / `6` | disk guard limit in percent / hours between runs |

The installer appends these as commented lines to the conf; uncomment to change and rerun the bootstrap.

Notifications are off by default. After an update, a cleanup, a disk guard alarm, a failed full health run or a pending reboot, `server-notify` sends a short message to the first channel set in `/etc/server-init.d/notify.env` (root-only, mode 0600, created as a commented template): `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`, `SLACK_WEBHOOK_URL` or `MAIL_TO`. Secrets are never printed or logged; curl gets the URL on stdin with `--fail --max-time 10`. A failed notification never fails the job.

</details>

## Cleanup

A weekly systemd timer (`server-cleanup.timer`, random delay up to 1 h, runs missed jobs after boot) runs `/usr/local/sbin/server-cleanup` niced with idle IO priority. Server, as `ops`, any directory:

```bash
sudo server-cleanup --dry-run
```

```bash
sudo server-cleanup
```

The first prints the plan, the second runs now. Next run and last output: `systemctl list-timers server-cleanup.timer` and `journalctl -u server-cleanup.service -n 30`. It cleans journald (vacuum by time and size), package caches (`dnf`, `zypper`, `apt-get`), old stopped containers, build cache and dangling images (never volumes, never `docker system prune -a`), `/tmp` and `/var/tmp` by the system's age rules, old rotated logs and core dumps. It never touches `/home`, `/root`, `/srv`, `/opt`, Docker volumes or databases. Disable with `INSTALL_CLEANUP=0` in `/etc/server-init.conf` and a rerun of the bootstrap.

The Ubuntu and Debian init has no cleanup step: with it the Cloud config would pass Hetzner's 32 KiB limit. There the bootstrap has already copied the script to `/root/server-init-config/server/`; run it when needed. Server, as `ops`, any directory:

```bash
sudo bash /root/server-init-config/server/server-cleanup.sh --dry-run
```

Drop `--dry-run` to clean for real.

| Setting (`/etc/server-init.conf`) | Default | Meaning |
|---|---|---|
| `INSTALL_CLEANUP` | `1` | `0` disables the timer |
| `CLEAN_SCHEDULE` | `weekly` | systemd `OnCalendar` value |
| `CLEAN_JOURNAL_TIME` / `CLEAN_JOURNAL_SIZE` | `1month` / `500M` | journal vacuum limits |
| `CLEAN_AUTOREMOVE` | `0` | `1` runs package autoremove (can remove wanted packages) |
| `CLEAN_DOCKER_UNUSED_IMAGES` | `0` | `1` prunes unused images older than 30 days |

## Update

Updates of the OS run daily by themselves and never reboot unless `AUTO_REBOOT=1`; kernel updates apply after your next reboot. To bring the scripts of this repo to the server, rerun the bootstrap. Laptop, repo root:

```bash
server/bootstrap.sh SERVER_IP
```

It replaces the server copy, reruns the init (checked steps are skipped) and refreshes the tools. Settings in `/etc/server-init.conf` stay.

## Roll back

Settings live in `/etc/server-init.conf`; set a key and rerun the bootstrap to change or switch off a part (`INSTALL_DOCKER=0`, `INSTALL_CLEANUP=0`, `LOGIN_SUMMARY=0`, `UPDATE_SCHEDULE=off`). To stop the maintenance timers, server, as `ops`, any directory:

```bash
sudo systemctl disable --now server-update.timer server-cleanup.timer server-disk-guard.timer server-health-brief.timer
```

## Close root SSH (optional)

The init keeps root's key login so nothing can lock you out. After the admin login works from a second terminal, you can close it. Server, as `ops`, any directory:

```bash
sudo bash /root/server-init-config/server/lock-root.sh
```

The script refuses unless `ADMIN_USER` (from `/etc/server-init.conf`) has an SSH key and `sudo -n true` works for it. It writes `/etc/ssh/sshd_config.d/00-a-root-lock.conf` with `PermitRootLogin no` (the name makes it load before `00-hardening.conf`, because the first match wins), checks `sshd -t`, reloads sshd, verifies the effective value with `sshd -T` and restores the previous state on any failure. It never changes the SSH port, and rerunning the init does not undo it. To reopen root (from a session that is still open): `sudo bash /root/server-init-config/server/lock-root.sh --unlock-root`; `--status` shows the effective setting. If you lose both logins, use the Hetzner web console: `rm /etc/ssh/sshd_config.d/00-a-root-lock.conf && systemctl reload ssh` (`sshd` on Fedora, EL and openSUSE).

A firewall mistake that cuts SSH is fixed from the Hetzner web console. The init saves SSH in the rules before the firewall starts, so a rerun cannot cut it.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Permission denied (publickey)` as `ops` | Log in as root and rerun the bootstrap; it copies root's keys to `ops` again. |
| Banned after failed logins | fail2ban bans an IP for 1 hour after 5 failures in 10 minutes. An SSH agent offering many keys can trip it: set `IdentitiesOnly yes` for the server in `~/.ssh/config`. Unban from the Hetzner web console: `fail2ban-client set sshd unbanip YOUR_IP`. The console asks for the root password, which Hetzner does not set when you add an SSH key: use Rescue, Reset root password first. |
| Cloud config pasted into a terminal | It is cloud-init user-data. Paste it into **Cloud config** when creating the server, never into a shell. |
| `fatal: detected dubious ownership` | A git command ran as root in a directory owned by another user. The server copy has no `.git`; run git on your laptop. |
| `sudo: health: command not found` | `secure_path` lacks `/usr/local/bin`. Check `/etc/sudoers.d/50-secure-path` (installed with `health`) and `/etc/sudoers.d/90-ops`, or run `sudo /usr/local/bin/health`. |
| `SHA1` GPG warning on EL10 | Harmless; packages are still verified. |
| A service from Docker is open to the world | Published ports (`-p 8080:80`) bypass firewalld and ufw. Bind to `127.0.0.1:8080:80` unless it should be public. |
| A step failed | `sudo cat /var/log/server-init-failed.log` (Docker: also `/var/log/server-init-docker.log`), fix the cause, rerun the bootstrap. |

## Cloud config

Paste the file for the OS into the Hetzner Console field **Cloud config** when you create the server. The file embeds the init script, so it is generated by `tools/render-cloud-init.py`; edit only the `/etc/server-init.conf` block at the top (ports, admin name). Each stays under Hetzner's 32 KiB limit.

| File | OS |
|---|---|
| `cloud-init/server-fedora.yaml` | Fedora 44 |
| `cloud-init/server-el10.yaml` | CentOS Stream 10, Rocky Linux 10, AlmaLinux 10 |
| `cloud-init/server-debian.yaml` | Ubuntu 26.04, Debian 13, Hetzner Apps |
| `cloud-init/server-opensuse.yaml` | openSUSE Leap 16.0 |

On CentOS Stream, Rocky and AlmaLinux 10 the first boot upgrades the packages. If that installs a newer kernel and Docker cannot start on the running one, the init finishes its steps and then reboots the server once (this happens only under cloud-init, never on a rerun or from the bootstrap); the SSH session drops for about a minute, and Docker is up afterwards. What the failed start printed stays in `/var/log/server-init-docker.log`.

After the first boot, run the bootstrap above; it adds `health` and the tools that do not fit into the Cloud config. To check the result first. Laptop, any directory:

```bash
ssh root@SERVER_IP 'cloud-init status --wait; cat /var/log/server-init-failed.log 2>/dev/null || echo no-failures'
```

## Security tools

Tools to test and audit **your own** servers. Use them only against systems you own or are explicitly authorized to test. On Hetzner, scanning or attacking third-party systems violates their terms: check their current policy before running anything against a host that is not yours.

Server, as `ops`, any directory (the bootstrap left the repo copy in `/root/server-init-config`):

```bash
sudo bash -c 'cd /root/server-init-config && common/security-tools.sh'
```

```bash
sudo bash -c 'cd /root/server-init-config && common/security-tools.sh --audit --network --scan --kali'
```

The first installs the default groups; the second adds the Kali helper. `--help` lists all options and their cost.

| Group | Installs |
|---|---|
| `--audit` | lynis, OpenSCAP (EL/Fedora, evaluation only), auditd with a small ruleset, ssh-audit, testssl.sh |
| `--network` | nmap, tcpdump, tshark, iperf3, socat, ncat, whois, dig, lsof, mtr, traceroute, iftop, nethogs, bmon |
| `--scan` | trivy, gitleaks, hadolint, cosign, osv-scanner, trufflehog, dockle: release binaries at pinned versions, checked against the checksums file of the same release (catches corrupt downloads, not a replaced release); a mismatch is refused; the script exits non-zero if every download it tried failed (release binaries, the testssl clone, the ssh-audit pip install) |
| opt-in | `--aide`, `--clamav` (no clamd), `--rkhunter`, `--chkrootkit`, `--arp-scan`, `--grype`, `--syft`, `--k8s` |
| `--kali` | the `kali` command: Kali Linux in a Docker container, built on first use (2 to 3 GB); needs Docker |
| `--audit-timer` | weekly lynis, oscap, aide and rkhunter reports in `/var/log/security-audit` (idle priority) |

It supports CentOS Stream/Rocky/AlmaLinux 10, Fedora 44, Debian 13 and Ubuntu 26.04, skips what a release does not package and never fails for a missing optional tool. A failed checksum is the exception: the tool is not installed and the script exits non-zero.

<details>
<summary>Commands for each tool</summary>

Server, as `ops`, any directory. Replace `your-host`, `your-site.example.com` and `IMAGE` with your own targets.

```bash
sudo lynis audit system
ssh-audit your-host
testssl your-site.example.com:443
nmap -sV your-host
trivy image IMAGE
gitleaks detect -s .
hadolint Dockerfile
dockle IMAGE
kali
```

`sudo lynis audit system` writes its index to `/var/log/lynis-report.dat`. `trivy fs .` scans a project folder; run `gitleaks`, `hadolint` and `trufflehog git file://. --only-verified` in the project directory. `osv-scanner scan source -r .` checks dependency CVEs. OpenSCAP: `sudo oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_standard --report /tmp/oscap.html /usr/share/xml/scap/ssg/content/ssg-rl10-ds.xml` (`ssg-almalinux10-ds.xml`, `ssg-cs10-ds.xml`, `ssg-fedora-ds.xml`; never `--remediate`). With the opt-in tools: `sudo rkhunter --check --sk`, `sudo aide --config /etc/security-tools/aide.conf --check`, `sudo clamscan -r -i /srv` (needs about 1.2 GB RAM). `sudo tshark -i eth0 -c 100 -f 'port 53'` captures; `iftop` and `nethogs` show live traffic. `kubescape scan` and `kube-bench run` need `--k8s` and a cluster you own.

`kali` runs with `--rm` on the Docker bridge network (`kali --host-net` for the host network) and without the Docker socket; `/home/kali` lives in the volume `kali-home`. `kali update` rebuilds the image, `kali remove` deletes image and volume. auditd rules cover only the paths that exist when the script runs: rerun it after installing Docker.

</details>

<details>
<summary>Reference: firewall, Ubuntu and Debian, Hetzner Apps, openSUSE</summary>

### Firewall

firewalld on Fedora, EL and openSUSE, ufw on Ubuntu and Debian: only SSH and your `EXTRA_PORTS` are open. SSH (port 22 and any other port sshd listens on, read with `sshd -T`) is saved in the permanent rules and verified before the firewall starts, and verified again afterwards (if it is missing, the firewall is switched off again). The Hetzner Cloud Firewall is separate: it filters before traffic reaches the server, so a port must be open in both places. Check, server, as `ops`, any directory:

```bash
sudo firewall-cmd --list-services --list-ports
```

On Ubuntu and Debian use `sudo ufw status`. Then `sudo fail2ban-client status sshd | tail -3`, `swapon --show` and `systemctl list-timers --no-pager | head`.

### Ubuntu and Debian

| Component | What it does |
|---|---|
| Firewall | `ufw`. SSH (`22/tcp`) is saved in the rules and checked in `ufw show added` before ufw is enabled, and in `ufw status` afterwards. `deny incoming` / `allow outgoing` are set only when ufw is first switched on. An already active ufw keeps its rules; the script only adds rules and never runs `ufw reset`. |
| Updates | `unattended-upgrades`, security origin only, `Automatic-Reboot "false"`. |
| fail2ban | journal backend (Debian 13 has no `/var/log/auth.log`), bans through nftables. |
| Docker | `download.docker.com` repo for `ubuntu` or `debian` (key in `/etc/apt/keyrings`, installed only if its fingerprint is Docker's `9DC8 5822 9FC7 DD38 854A  E2D8 8D81 803C 0EBF CD88`). The distro packages are used only when the repo answers HTTP 404 for the codename; a network error stops the Docker step so a rerun can retry; the log says which. |
| SSH | drop-in `00-hardening.conf`, checked with `sshd -t`. On Ubuntu the service is `ssh` (may be socket activated). |
| Time sync | keeps `systemd-timesyncd` or `chrony` if one runs, installs `chrony` only if neither does. |
| Swap | `fallocate` on ext4, `btrfs filesystem mkswapfile` on btrfs, only when there is no swap. |

### Hetzner Apps images

The [Hetzner Apps](https://github.com/hetznercloud/apps) (Coolify, Docker CE, GitLab CE, Jitsi Meet, LAMP, Nextcloud, Owncast, PhotoPrism, Prometheus Grafana, RustDesk, WireGuard, WordPress) are Ubuntu 24.04 images with the software preinstalled. With `APP=auto` (default) the Debian init recognises the app by its files and packages (a fresh Coolify image has none until Coolify is installed on first login: set `APP=coolify` for it, otherwise the init sees an unknown Hetzner image and stops before the firewall), never reinstalls or reconfigures Docker when it exists, never touches the app's configuration, keeps existing firewall rules and adds only the app's documented ports.

| APP | Ports opened |
|---|---|
| `coolify` | `8000/tcp` |
| `docker-ce` | none |
| `gitlab`, `lamp`, `nextcloud`, `wordpress`, `prometheus-grafana` | `80/tcp 443/tcp` |
| `jitsi` | `80/tcp 443/tcp 10000/udp`, plus `3478/udp 5349/tcp` when `coturn` is installed |
| `wireguard` | `51820/udp 80/tcp 443/tcp`, but ufw is **not** enabled (its `nftables.conf` flushes the ruleset at boot) |
| `owncast` | `80/tcp 443/tcp 1935/tcp` |
| `photoprism` | `80/tcp 443/tcp 2342/tcp` |
| `rustdesk` | `21115-21119/tcp`, `21116/udp` |

Other ports go into `EXTRA_PORTS`. `APP=none` ignores detection; naming an app forces its ports. An unrecognised Hetzner app (a `/opt/hcloud/*_setup.sh` that is not in the table) makes the firewall step log why and fail without enabling ufw, so a public service is never blocked by guesswork: set `APP=none` plus `EXTRA_PORTS` in `/etc/server-init.conf` and rerun to take over the firewall. Hetzner Cloud Firewalls are separate and unaffected.

### openSUSE Leap 16

- Packages come from the openSUSE repositories only. Docker CE has no openSUSE repository, so Docker and Compose are the distribution's packages.
- Security updates: `server-security-updates.timer` runs `zypper patch --category security` daily (`systemctl list-timers server-security-updates.timer`).
- Swap on btrfs lives in its own `/swap` subvolume. After a snapper rollback `/swap` comes back as an empty directory; rerun the bootstrap and it is replaced by a new subvolume and swap file. A non-empty `/swap` that is not a subvolume is left alone and the swap step fails with a logged message.
- If `fail2ban` is missing from the repositories, that step is logged and skipped.

### Run an init script without the bootstrap

Copy one script and run it. Laptop, repo root (pick the script for the OS):

```bash
scp server/server-init-el10.sh root@SERVER_IP:/usr/local/sbin/server-init.sh
```

```bash
ssh root@SERVER_IP 'chmod 0755 /usr/local/sbin/server-init.sh && ADMIN_USER=ops EXTRA_PORTS="" /usr/local/sbin/server-init.sh'
```

Settings are saved to `/etc/server-init.conf` on the first run (`ADMIN_USER`, `EXTRA_PORTS`, `INSTALL_DOCKER`, `INSTALL_SWAP`, `TIMEZONE`, the cleanup keys, `APP` on Debian).

The shell setup (100000-line history with timestamps shared between sessions, `Ctrl+R` with fzf, `Ctrl+T` finds files) is `/etc/profile.d/90-server-shell.sh`, interactive bash only; log in again to get it. Its text is the same as `common/shell-history.sh`; `tools/test-cloud-init.py` checks they match.

</details>

## Local AI (separate server)

`install-ai.sh` runs a small local chat on a second server (2 vCPU / 4 GB, CPU only): Ollama with one small model and Open WebUI in front. It is not for a runner host, where a model would compete with CI jobs for memory; the installer warns if `gitlab-runner` is active. It creates a 2 GB swap file if there is none, puts the stack in `/opt/ai`, generates `WEBUI_SECRET_KEY` into a root-only `.env`, starts it and pulls the model. Open WebUI listens on `127.0.0.1:3080` only (set `UI_PORT` if taken; an existing install keeps the port in `/opt/ai/.env`) and Ollama publishes no port.

Server, as `ops`, any directory (after the bootstrap has copied the repo):

```bash
sudo bash -c 'cd /root/server-init-config && server/install-ai.sh'
```

For a smaller, faster model that fits the 2 GB Ollama limit, set `MODEL=llama3.2:1b` the same way: `sudo bash -c 'cd /root/server-init-config && MODEL=llama3.2:1b server/install-ai.sh'`. The default is `qwen2.5:1.5b`. Bigger models need a higher `mem_limit` for `ollama` in `server/ai/docker-compose.yml` first.

Then tunnel from your laptop (any directory) and open `http://localhost:3080`:

```bash
ssh -N -L 3080:127.0.0.1:3080 ops@SERVER_IP
```

Create the first account: it becomes the admin and Open WebUI closes sign-ups at that moment. Verify, server, as `ops`, any directory (read-only check):

```bash
sudo bash -c 'cd /root/server-init-config && server/install-ai.sh --check-signup'
```

Expect a few tokens per second on shared vCPUs: good for short questions and summaries. To update, change the image tags in `server/ai/docker-compose.yml`, rerun the bootstrap and `install-ai.sh`. `docker compose down` in `/opt/ai` stops the stack and keeps models and chats; `docker compose down -v` deletes both for good.
