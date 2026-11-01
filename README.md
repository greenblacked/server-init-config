# server-init-config

Set up and look after Hetzner Cloud servers: a plain hardened server, or a GitLab Runner host. Everything is run from your laptop over SSH; the repo is streamed to the server with `git archive` by default (nothing is cloned there, no credential goes there); cloning it on the server also works: `git clone https://github.com/greenblacked/server-init-config`. Root keeps key login on port 22 throughout, so none of this can lock you out.

## Which one do I need?

| Goal | OS | Cloud config (optional, paste when creating the server) | First command, on your laptop in the repo root |
|---|---|---|---|
| Plain server | Fedora 44 | `server/cloud-init/server-fedora.yaml` | `server/bootstrap.sh SERVER_IP` |
| Plain server | CentOS Stream 10, Rocky 10, AlmaLinux 10 | `server/cloud-init/server-el10.yaml` | `server/bootstrap.sh SERVER_IP` |
| Plain server | Ubuntu 26.04, Debian 13 (also the Hetzner Apps images) | `server/cloud-init/server-debian.yaml` | `server/bootstrap.sh SERVER_IP` |
| Plain server | openSUSE Leap 16 | `server/cloud-init/server-opensuse.yaml` | `server/bootstrap.sh SERVER_IP` |
| GitLab Runner host | Rocky Linux 10 (ARM64 or x86_64) | `runner/cloud-init/rocky-clean.yaml` (recommended) or `rocky.yaml` | `runner/bootstrap.sh SERVER_IP` |
| GitLab Runner host | Debian 13 (ARM64 or x86_64) | `runner/cloud-init/debian.yaml` | `runner/bootstrap.sh SERVER_IP` |

x86 servers use `rocky-x86.yaml` or `debian-x86.yaml`; then set the tags in `runner/ci/*.yml` to your x86 tag instead of `arm64`. The Cloud config is optional for plain servers: `server/bootstrap.sh` works on a fresh image too. It is user-data for cloud-init, never paste it into a terminal.

## 60-second quick start

Before either path, in the Hetzner Console: add your SSH key, and in the Cloud Firewall allow inbound TCP 22 from your IP only. The first connection needs the host key accepted once (the scripts never auto-accept keys).

**Plain server.** Accept the host key (laptop, any directory), then bootstrap (laptop, repo root):

```bash
ssh root@SERVER_IP true
```

```bash
server/bootstrap.sh SERVER_IP
```

It waits for cloud-init, copies `server/` and `common/`, runs the init for the detected OS (admin user `ops`, SSH keys only, firewall, fail2ban, automatic security updates, Docker, swap), installs `health` and, on Fedora and EL, `srv` with the timers, and ends with `health`. Then test the admin login from a second terminal (laptop, any directory):

```bash
ssh ops@SERVER_IP 'sudo -n true && echo ok'
```

**Runner host.** Create the runner in GitLab first (Settings, CI/CD, Runners, New runner) and keep the `glrt-` token ready. Then (laptop, repo root):

```bash
runner/bootstrap.sh SERVER_IP
```

It installs the users, admin tools, health and cleanup, registers the runner (you type the token at the prompt on the server, it never goes into a command line), the Docker Hub cache, monitoring, logging and the npm and shared caches, and ends with `health`. Run `runner/ci/smoke.yml` in a project: the log must show `on <runner description>` and `aarch64` (`x86_64` on x86). Close root SSH only after the `ops` login works: see [runner/README.md](runner/README.md#close-root-ssh).

Rerunning either bootstrap is safe. Options: `--help`.

## What it changes

| Area | Plain server | Runner host |
|---|---|---|
| SSH | keys only, root by key on port 22 | keys only, only the `ssh-users` group, root by key until you lock it |
| Users | admin `ops` with sudo | `ops` (sudo), service accounts `gitlab-runner` and `monitoring` without login |
| Firewall | firewalld (RHEL family, openSUSE, Fedora) or ufw (Ubuntu, Debian): only SSH and your `EXTRA_PORTS`; SSH is saved before the firewall starts | firewalld (Rocky) or ufw (Debian) with only SSH open, set by `setup.sh --firewall` (the bootstrap runs it; `--no-firewall` skips it); also use the Hetzner Cloud Firewall |
| Brute force | fail2ban for SSH (5 failures in 10 minutes, 1 hour ban) | the same, installed with the firewall step |
| Updates | daily security updates, no automatic reboot | same (dnf-automatic or unattended-upgrades), plus a weekly upgrade of Docker CE and GitLab Runner that runs only while no job runs |
| Docker | Docker Engine and Compose (distro packages on openSUSE) | Docker Engine, GitLab Runner (docker executor), `concurrent = 2` |
| Extras | swap if none, sysctl tuning and kernel hardening, core dumps off, journald limit, time sync, weekly cleanup (not on Ubuntu or Debian), admin tools, shell history with fzf, optional `server/lock-root.sh` | Docker Hub cache, monitoring, logging, npm and shared caches, weekly cleanup, disk guard at 85%, kernel hardening, core dumps off, per-job CPU, memory and process limits, CI jobs blocked from the cloud metadata address and from host services |
| SELinux | as the image has it | enforcing on Rocky (`rocky.yaml` sets it at boot, `rocky-clean.yaml` leaves it to `setup.sh --selinux`) |

## Daily use

On the server, as `ops`, any directory:

```bash
health -q
```

`health` is the one report for system, security, firewall, services, containers and trends (full report 10 to 40 seconds; exit code 0 ok, 1 warnings, 2 failures). It re-runs itself through sudo when that needs no password.

On Fedora and EL plain servers, `srv` is the single entry point (`srv status`, `srv update`, `srv clean`, `srv logs`, `srv timers`), and the admin sees a 7-line summary at login: load, disk, memory, firewall, banned IPs, pending updates and reboot, last update and cleanup. On Ubuntu, Debian and openSUSE use `health` and the init's own timers. On runner hosts, aliases:

| Alias | Does |
|---|---|
| `health` | `sudo health` |
| `runner-logs`, `runner-errors` | follow the runner log, errors of the last 30 minutes |
| `runner-jobs` | running job containers: name and status |
| `runner-metrics` | runner metrics from `127.0.0.1:9252` |
| `dfd`, `dstats` | disk use incl. Docker, container stats |

## Update and clean

Updating means: stream the new repo state, then apply it. Laptop, repo root:

```bash
server/bootstrap.sh SERVER_IP
```

For a runner host, run `runner/bootstrap.sh SERVER_IP` instead, then (laptop, any directory):

```bash
ssh ops@SERVER_IP 'sudo bash -c "cd /root/server-init-config && runner/update.sh --dry-run"'
ssh ops@SERVER_IP 'sudo bash -c "cd /root/server-init-config && runner/update.sh"'
```

`update.sh` backs up every file it changes, restores them if a check fails, and skips steps that would interrupt CI while jobs run (exit code 3, rerun later). With the default streaming install do not use `update.sh --pull`: the server has no git clone. After a `git clone` of the public repo `--pull` works without a credential. Cleanup runs weekly by itself; to run it now: `srv clean` or `sudo server-cleanup` (plain servers on Fedora, EL and openSUSE), `sudo bash /root/server-init-config/server/server-cleanup.sh` (Ubuntu and Debian), `sudo runner-weekly-cleanup.sh` (runner). Add `--dry-run` to any of them to preview.

## Roll back

On a plain server every step is a file you can undo: settings are in `/etc/server-init.conf`, `UPDATE_SCHEDULE=off` gives the updates back to the distro timer, and `sudo systemctl disable --now server-update.timer server-cleanup.timer` stops the maintenance timers. A bad firewall rule is fixed from the Hetzner web console. On a runner host (server, as `ops`, any directory), restore the files `update.sh` changed from the newest backup:

```bash
sudo bash -c 'cd /root/server-init-config && runner/update.sh --rollback'
```

Restore the runner configuration from its newest backup (server, as root via `sudo -i`, any directory):

```bash
cp -a "$(ls -1t /etc/gitlab-runner/config.toml.bak.* | head -1)" /etc/gitlab-runner/config.toml && chown gitlab-runner:gitlab-runner /etc/gitlab-runner/config.toml && systemctl restart gitlab-runner
cp -a "$(ls -1t /etc/docker/daemon.json.bak.* | head -1)" /etc/docker/daemon.json && systemctl restart docker
```

Plain servers: `sudo bash /root/server-init-config/server/lock-root.sh --unlock-root` (server, as `ops`, any directory).

Reopen root SSH after you locked it on a runner host (server, as `ops` or root, any directory):

```bash
sudo bash /root/server-init-config/runner/install/users.sh --unlock-root
```

Stop a stack without deleting data: `sudo docker compose -f /opt/monitoring/docker-compose.yml down` (also `/opt/logging`, `/opt/registry-cache`, `/opt/npm-cache`). Never add `-v` unless you want its data volumes deleted for good.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Connection timed out` | The Hetzner Cloud Firewall has no inbound rule for TCP 22 from your current IP. Fix the rule in the Console; it applies at once. |
| `Permission denied (publickey)` as `ops` | The key was not copied or you use another key. Plain server: log in as root and rerun `server/bootstrap.sh`; it copies root's keys again. Runner host: rerunning `runner/bootstrap.sh` does not (the users step counts as installed and is skipped); as root run `bash /root/server-init-config/runner/install/users.sh` on the server, which merges root's keys into `ops`. If root is already locked, use the Hetzner web console. |
| Connection refused right after many tries | fail2ban banned your IP (1 hour). Unban from the Hetzner web console: `fail2ban-client set sshd unbanip YOUR_IP`. The console asks for the root password, which Hetzner does not set when you add an SSH key: use Rescue, Reset root password in the Console first. Use `IdentitiesOnly yes` in `~/.ssh/config` to stop agents offering many keys. |
| Cloud config pasted into a terminal gives errors | It is cloud-init user-data. Paste it into the Console field **Cloud config** when creating the server. |
| `fatal: detected dubious ownership` | A git command ran as root in a directory owned by another user. The server copy has no `.git`; run git on your laptop. |
| `sudo: health: command not found` | `secure_path` lacks `/usr/local/bin`. Check `sudo cat /etc/sudoers.d/50-secure-path` and `/etc/sudoers.d/90-ops`, or run `sudo /usr/local/bin/health`. |
| `service user monitoring missing` | The Users step has not run. `sudo bash -c 'cd /root/server-init-config && runner/setup.sh --users'`, then the component again. |
| Runner aliases: `permission denied ... docker.sock` | You ran `docker` without sudo; `ops` is deliberately not in the `docker` group. The aliases already use sudo; use `sudo docker`. |
| `SHA1` or `SHA-1` GPG warning on CentOS, Rocky or Alma 10 | Harmless: an old vendor key signature. Packages are still verified. |
| `Request bottleneck: request_concurrency=1` | Add `request_concurrency = 2` under `[[runners]]` in `/etc/gitlab-runner/config.toml` and restart the runner. |
| Jobs stay pending | Tags do not match, untagged jobs are not allowed, or an instance runner took them. Compare tags in the job log and runner settings. |
| `toomanyrequests` pulling an image | Docker Hub rate limit. Install the Docker Hub cache (`runner/setup.sh --registry-cache`). |
| Disk full | `dfd` on a runner, `srv clean` or `sudo server-cleanup`. The weekly cleanup and the disk guard do this automatically. |
| A step failed | See `/var/log/server-init-failed.log` (plain server) or `/var/log/ci-bootstrap-failed.log` (runner). Fix the cause and rerun the same command. |

<details>
<summary>Reference: layout, tools, security</summary>

### Layout

| Path | Purpose |
|---|---|
| `runner/` | GitLab Runner host: `cloud-init/` (generated, sources in `templates/`), `install/` (installers, `update.sh`), `scripts/` and `systemd/` (cleanup, disk guard, prewarm), `stacks/` (Compose stacks), `ci/` (`.gitlab-ci.yml` snippets), `setup.sh`, `register.sh`, `update.sh`, `bootstrap.sh`, `COMMANDS.md`. See [runner/README.md](runner/README.md). |
| `server/` | plain servers: `server-init-*.sh` per OS, `cloud-init/`, maintenance tools (`srv`, update, cleanup, notify, disk guard), `bootstrap.sh`, `ai/`. See [server/README.md](server/README.md). |
| `common/` | shared: `health`, `shell-history.sh`, `lib.sh`, `admin-tools.sh`, security tools. See [common/README.md](common/README.md). |
| `tools/` | `render-cloud-init.py`, `render-paste-commands.py` (both with `--check`), `test-cloud-init.py`, `test-server-tools.sh`; `ci/` holds the scripts the GitHub workflows run (see [CI](#ci)) |
| `other/` | standalone extras, not copied by the bootstrap scripts (each README says how to get it onto a server); `other/torrserver/` installs TorrServer in Docker for streaming only: HTTPS with login on a random port (sslip.io, no domain needed), or localhost, or optional WireGuard (see its README) |
| `other/lampa-stack/` | Lampa + Lampac (online sources, optional 18+) + TorrServer (streaming) + qBittorrent behind Caddy and Authelia; public HTTPS on a random port (sslip.io, Let's Encrypt) by default, `--local` tunnel or optional `--vpn` WireGuard; every path needs a login or a per-device key; installed by its own `install.sh` (see its README) |

### Supported systems

| OS | Plain server | Runner host |
|---|---|---|
| CentOS Stream 10, Rocky Linux 10, AlmaLinux 10 | yes | Rocky 10 |
| Fedora 44 | yes | no |
| Ubuntu 26.04 (24.04 for Hetzner Apps images) | yes | no |
| Debian 13 | yes | yes |
| openSUSE Leap 16 | yes | no |

All on x86_64 and ARM64. Hetzner Apps images (Ubuntu 24.04 with Coolify, GitLab CE, Nextcloud and others) are detected and keep their own Docker and configuration; only the app's documented ports are added. Details in [server/README.md](server/README.md#hetzner-apps-images).

### Security tools (authorized use only)

`common/security-tools.sh` installs lynis, OpenSCAP, auditd, ssh-audit, testssl, nmap and network tools, trivy, gitleaks and more, plus a `kali` container helper. Use them only against systems you own or are explicitly authorized to test. On Hetzner, scanning or attacking third-party systems violates their terms; check their current policy first. Commands: [server/README.md](server/README.md#security-tools). On a runner host: `setup.sh --security`.

### Runner concurrency

`concurrent = 2` on a CAX11 (2 vCPU, 4 GB): two jobs at once. Registering the runner (or `setup.sh --job-limits`) sets per-job limits by default: 1536 MB memory, 1.5 CPUs, 256 MB shared memory, smaller limits for `services:` containers, and a ceiling on processes and memory for all jobs together. Change them as described in [runner/README.md](runner/README.md#concurrent-jobs-and-limits).

### Changing the repo

Edit the sources, then regenerate and check (laptop, repo root):

```bash
tools/render-cloud-init.py
tools/render-paste-commands.py
tools/render-cloud-init.py --check
tools/render-paste-commands.py --check
python3 tools/test-cloud-init.py
tools/test-server-tools.sh
```

Generated files (`*/cloud-init/*.yaml`, `runner/COMMANDS.md`) are never edited by hand. Cloud config stays under Hetzner's 32 KiB limit; the test enforces it.

### CI

GitHub Actions (`.github/workflows/`) test what a laptop cannot: real package mirrors, real Docker, a real kernel with WireGuard. No secrets are used or needed; actions are pinned by commit SHA; every workflow has `permissions: contents: read`, per-job timeouts, and uploads its logs as an artifact when it fails. All logic lives in `tools/ci/*.sh` (the workflows only call them), so the same checks run by hand.

| Workflow | Runs on | What it checks | Same check locally |
|---|---|---|---|
| `lint.yml` | every push and pull request | shellcheck `-S warning` and `bash -n` on every shell file, generated files current (`--check`), yamllint, hadolint, `docker compose config` on every compose file, actionlint; `tools/ci/check-pins.sh` (every `uses:` is a 40-hex commit SHA, every workflow has a top-level `permissions:`); unit tests of the shell helpers in `tests/unit/` (`backup`, `edit_with_backup`, `put`, the log redaction in `tools/ci/lib.sh`; plain bash, run by `tests/unit/run.sh`); `tools/test-cloud-init.py` with the real cloud-init CLI (schema) and a live sshd test; `tools/test-server-tools.sh` including the destructive tests in a container | `tools/ci/lint.sh [shell\|render\|cloud-init\|server-tools\|yaml\|dockerfiles\|compose\|actionlint\|pins\|unit]` |
| `server-matrix.yml` | every push to `main`; pull requests touching `server/`, `common/`, `tools/ci/`; weekly; manual | per OS (CentOS Stream 10, Rocky 10, Alma 10, Fedora 44, Ubuntu 26.04, Debian 13, openSUSE Leap 16.0): a privileged systemd container, the real `server/bootstrap.sh` over its sshd, then assertions: OS detected, every init step ok except a documented list of container-only failures (`swap`, `system-tuning`, `docker`; bootstrap stops after a failed init step, so the test then runs the tools/health step itself), firewall allows SSH, fail2ban sshd jail, update timer, `ops` and sudoers, rerun changes no managed file, `bootstrap --user ops`, `health --brief` and `health -q` free of bash errors | `tools/ci/server-e2e.sh debian:13` (Docker; `STRICT=1` empties the allow-list) |
| `runner-matrix.yml` | every push to `main`; pull requests touching `runner/`, `common/`, `tools/ci/`; weekly; manual | Rocky 10 and Debian 13 in a systemd container: users and SSH, admin tools, `health` and timers, firewall and fail2ban, job limits on a stand-in `config.toml`, rerun is a no-op. On the runner VM itself (a container cannot test the host's netfilter): registry cache, `DOCKER-USER` isolation of the metadata address and host services (a network namespace plays the metadata service), re-applied after a Docker restart, npm cache stack. Runner cloud-init files against the cloud-init schema. No runner is ever registered. | `tools/ci/runner-e2e.sh debian:13`; `sudo ALLOW_LOCAL=1 tools/ci/runner-host-e2e.sh` (disposable VM only) |
| `stacks.yml` | every push to `main`; pull requests touching `other/`, `tools/ci/`; weekly; manual | TorrServer: local and public mode (Caddy's own CA, because Let's Encrypt cannot reach a CI VM), 401 without and 200 with the login, streaming-only settings read back, fail2ban ban, cleanup dry run, mode switch, `--uninstall --purge` leaves nothing, public IP found through the real `api.ipify.org`. Lampa stack: `--local` with the real Lampac image and `tests/smoke.sh` without `SMOKE_SKIP_LAMPAC`, `--enable-sisi` and `--disable-sisi`, devices, `--vpn` with a real WireGuard tunnel from a network namespace, `--remove-device` revokes it | `sudo ALLOW_LOCAL=1 tools/ci/stack-torrserver.sh`, `sudo ALLOW_LOCAL=1 tools/ci/stack-lampa.sh` (disposable VM only) |
| `security-tools.yml` | every push to `main`; pull requests touching `common/`, `tools/ci/`; weekly; manual | `common/security-tools.sh --scan` with real downloads and SHA-256 checks on amd64 and arm64 runners, each binary run for its pinned version; `--audit --network` package names on Rocky 10, Fedora 44, Debian 13, Ubuntu 26.04 with EPEL and CRB | `sudo ALLOW_LOCAL=1 tools/ci/security-tools-e2e.sh scan`; `tools/ci/security-tools-e2e.sh pkgs debian:13` |

The heavy matrices run on every push to `main`, on pull requests that touch their paths, and once a week (Monday) to catch mirror, image and upstream changes. `server-matrix.yml` and `security-tools.yml` run on both amd64 and arm64 runners. Superseded pull request runs are cancelled automatically. To run one matrix by hand: Actions tab, pick the workflow, Run workflow.

Limits of what CI proves: a container shares the runner's kernel (no reboot, `swap` and some sysctl keys cannot be tested), Docker Engine inside the server containers may not start (that is why `docker` is in the allow-list), the Hetzner metadata service, Let's Encrypt on a real public port and the Hetzner Cloud Firewall are not available.

To update a pinned action: look up the tag's commit (`git ls-remote --tags https://github.com/OWNER/REPO`), put the full SHA in the workflow and the version in the comment next to it. The lint tool downloads (`tools/ci/install-lint-tools.sh`) pin version and SHA-256 together.

### Security notes

- No tokens or passwords are stored in the repo, in command lines or in logs. The runner token is typed at a prompt; the Grafana password is generated on the server.
- Never put the runner token in user-data: anything on the server, including job containers, can read it through the metadata service.
- Ports published by Docker (`-p 8080:80`) bypass firewalld and ufw. Bind to `127.0.0.1` unless the port should be public. The Hetzner Cloud Firewall still filters them.
- Job containers are not privileged. Membership of the `docker` group is root-equivalent; only `gitlab-runner` has it.
- `/srv/ci-cache` and the npm cache are shared by every project on the runner: do not attach untrusted projects or forks.
- Reach Grafana and Prometheus through an SSH tunnel (laptop, any directory): `ssh -N -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 ops@SERVER_IP`.

### Decommission

Delete the runner in GitLab and its deploy tokens. In Hetzner delete the server and its Primary IPv4 (billed separately even when unattached) and any snapshots. Remove DNS records that point at the server.

</details>
