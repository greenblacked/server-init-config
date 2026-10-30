# GitLab Runner host

A Hetzner server that runs CI jobs for GitLab with the docker executor. Built for an ARM64 CAX11 (2 vCPU, 4 GB) on Rocky Linux 10; Debian 13 and x86_64 work too. For a plain server without a runner see [../server/README.md](../server/README.md).

## Build one

1. **GitLab**: Settings, CI/CD, Runners, New runner. Set tags and "run untagged jobs", copy the `glrt-` token (shown once).
2. **Hetzner Console**: create the server (Rocky Linux 10 or Debian 13), add your SSH key, paste an init file as **Cloud config**, and add a Cloud Firewall with inbound TCP 22 from your IP only (outbound empty means allow all). Open 80 and 443 only if you publish Grafana.
3. **Bootstrap**, from your laptop in the repo root. Accept the host key first, because the script never does:

   ```bash
   ssh root@SERVER_IP true
   ```

   ```bash
   runner/bootstrap.sh SERVER_IP
   ```

   It waits for cloud-init (and shows `/var/log/ci-bootstrap-failed.log` if a step failed), streams `git archive HEAD` to `/root/server-init-config`, installs users, admin tools, health and cleanup, the runner registration (you type the token on the server), Docker Hub cache, monitoring, logging, npm cache and shared cache, and ends with `health`. Options: `--no-register`, `--with-prewarm`, `--user`, `--port`, `--allow-dirty`, `--dry-run`. `DOMAIN` and `ACME_EMAIL` in the environment add Grafana on an HTTPS domain. It never runs lock-root or selinux. Rerunning is safe: installed components are skipped.
4. **Smoke test**: run `ci/smoke.yml` in a project. The log must show `on <runner description>` and `aarch64` (`x86_64` on x86). If the job stays pending, check `tags:`.
5. **Test the admin login** from a second terminal (laptop, any directory), then close root SSH if you want:

   ```bash
   ssh ops@SERVER_IP 'sudo -n true && echo ok'
   ```

### Which init file

| File | OS | What the server has after boot |
|---|---|---|
| `cloud-init/rocky-clean.yaml` (recommended) | Rocky 10 | Docker, GitLab Runner, SSH hardening (password logins off), security updates, admin tools, aliases, tmux. Nothing else: SELinux, users and caches come from `setup.sh`. |
| `cloud-init/rocky.yaml` | Rocky 10 | The same host plus the Docker Hub cache on `127.0.0.1:5000`, weekly cleanup and disk guard timers, SELinux enforcing, and firewalld switched off. No aliases and no `health`; `bootstrap.sh` adds them. |
| `cloud-init/debian.yaml` | Debian 13 | Docker, GitLab Runner, Docker Hub cache, cleanup timers, unattended-upgrades. |
| `cloud-init/*-x86.yaml` | x86_64 | The same for CX, CPX and CCX servers. |

Pick one: `rocky-clean.yaml` gives you each component as a deliberate step, `rocky.yaml` is the all-in-one. `bootstrap.sh` works with either, because installed components are skipped. The init never changes users, the SSH port or the SSH login: you log in as root with your key until you decide otherwise.

## What the bootstrap does, step by step

You can run every step yourself with `setup.sh`, on the server, as root, in `/root/server-init-config` (or from `ops` with `sudo bash -c 'cd /root/server-init-config && runner/setup.sh --list'`). The repo copy is under `/root`, which `ops` cannot read, so always wrap the command like this.

| # | Step | `setup.sh` flag | Check |
|---|---|---|---|
| 1 | Users: admin `ops`, service accounts, SSH hardening (root stays open) | `--users` | `ssh ops@SERVER_IP 'sudo -n true && echo ok'` |
| 2 | Admin tools and aliases | `--packages` | `htop --version` |
| 3 | `health`, weekly cleanup, disk guard | `--tools` | `health -q`, `systemctl list-timers 'runner-*'` |
| 4 | Register the runner (asks for the token) | `--register` | GitLab shows it Online; `sudo gitlab-runner verify` |
| 5 | Docker Hub cache | `--registry-cache` | `curl -s 127.0.0.1:5000/v2/_catalog` |
| 6 | Monitoring (Prometheus, node_exporter, Grafana) | `--monitoring` | SSH tunnel, then `http://localhost:3000` |
| 7 | Logging (Loki, Alloy) | `--logging` | `health` shows both ready |
| 8 | npm cache (needs 4) | `--npm-cache` | `sudo grep 'environment =' /etc/gitlab-runner/config.toml` |
| 9 | Shared cache `/srv/ci-cache` (needs 4, trusted projects only) | `--shared-cache` | `sudo grep 'volumes =' /etc/gitlab-runner/config.toml` |
| opt | Image prewarm, Grafana domain, security tools, SELinux, lock root | `--prewarm`, `--grafana-domain`, `--security`, `--selinux`, `--lock-root` | see below |

`--base` is steps 1, 2, 3, 5, 6; `--all` is `--base` plus 4, 7, 8, 9 and asks for the token. Components are installed in this order whatever the flag order. If one fails, fix the cause and rerun the same command.

Server, as `ops`, any directory:

```bash
sudo bash -c 'cd /root/server-init-config && runner/setup.sh --list'
```

```bash
sudo bash -c 'cd /root/server-init-config && DOMAIN=grafana.example.com ACME_EMAIL=you@example.com runner/setup.sh --grafana-domain'
```

The domain needs monitoring, an A record and TCP 80 and 443 in the Cloud Firewall.

### Without a repo copy

[`COMMANDS.md`](COMMANDS.md) has one self-contained block per component, generated from the repo files by `tools/render-paste-commands.py`. Paste a block into an SSH session as `ops` (as root before the Users block ran); it writes the files it needs and runs the installer. Use them in order and skip what you don't need. The first block, "Base host", gives a Rocky server created without the init the same base as `rocky-clean.yaml`; paste the Users block after it.

## Users

| User | Kind | SSH | What it does |
|---|---|---|---|
| `ops` | admin | by key | your login; sudo without password; not in the `docker` group, so Docker needs `sudo` |
| `gitlab-runner` | service | no | the runner service; Docker access through the `docker` group, which the executor needs |
| `monitoring` | service | no | Prometheus, node_exporter, Grafana, Loki and Alloy; reads its config but cannot change it |
| `root` | | by key until locked | the init does not change it |

SSH accepts keys only, and only members of `ssh-users`. Local forwarding (`ssh -L`) works; remote, agent and X11 forwarding are off. Set `ADMIN_USER=...` for another admin name. `SSH_PORT=...` for another port is remembered from `00-ci-hardening.conf`, so reruns, `--lock-root` and `--unlock-root` keep it (`SSH_PORT=22` goes back to 22); open the port in the Cloud Firewall first. Why the split: anyone with the Developer role in a project can compromise a runner host, and `docker` group membership is root-equivalent, so nobody you log in as has it.

A shortcut for your laptop's `~/.ssh/config`, then `ssh runner` works:

```text
Host runner
  HostName SERVER_IP
  User ops
```

## Close root SSH

Only after the `ops` login works from a second terminal. The step refuses to run while `ops` has no key. Server, as `ops`, any directory:

```bash
sudo bash -c 'cd /root/server-init-config && runner/setup.sh --lock-root'
```

From now on `ssh ops@SERVER_IP`; `ssh root@SERVER_IP` is refused. To reopen it, server, as `ops`, any directory:

```bash
sudo bash -c 'cd /root/server-init-config && runner/install/users.sh --unlock-root'
```

If you lost both logins, use the Hetzner web console. `rm /etc/ssh/sshd_config.d/00-ci-hardening.conf && systemctl reload sshd` as root goes back to the previous SSH rules entirely.

### Moving an older server (root login, no `ops`)

Do it in this order. Laptop, repo root, copy the repo with `runner/bootstrap.sh SERVER_IP --no-register` (it runs the users step first and keeps root open). Then test `ssh ops@SERVER_IP 'sudo -n true && echo ok'` from a second terminal and apply the update, which moves the runner and the stacks to the service users (server, as `ops`, any directory):

```bash
sudo bash -c 'cd /root/server-init-config && runner/update.sh'
```

Then lock root as above. To put the runner service back to root (no jobs running), as root: `rm /etc/systemd/system/gitlab-runner.service.d/10-service-user.conf && systemctl daemon-reload && systemctl restart gitlab-runner`.

## Daily use

Server, as `ops`, any directory. Aliases come from `/etc/profile.d/ci-runner.sh`:

| Alias | Does |
|---|---|
| `health` | `sudo health`: full report; `health -q` quick; `health -c` containers only |
| `runner-logs` | follow the runner log |
| `runner-errors` | errors and warnings of the last 30 minutes |
| `runner-jobs` | running job containers: name and status (`sudo docker ps --filter label=com.gitlab.gitlab-runner.managed=true`) |
| `runner-metrics` | runner metrics from `127.0.0.1:9252` |
| `dfd` | `df -h /` and `sudo docker system df` |
| `dstats` | `sudo docker stats --no-stream` |

Also `sudo gitlab-runner list` and `sudo gitlab-runner verify`. On a login shell the history is 100000 lines, `Ctrl+R` searches it with fzf and `Ctrl+T` finds files.

### Cleanup

The weekly cleanup runs Monday 03:30; the disk guard checks every 30 minutes and cleans with 1-day retention when `/` reaches 85%. Server, as `ops`, any directory:

```bash
sudo runner-weekly-cleanup.sh --dry-run
```

```bash
sudo runner-weekly-cleanup.sh
```

The first previews, the second runs now (it skips the cache wipe while jobs run). `RETENTION_DAYS=1` keeps only the last day; `runner-weekly-cleanup.sh --help` lists the settings. What it removed: `sudo journalctl -t runner-weekly-cleanup --since "-7d" --no-pager`. Next runs: `systemctl list-timers 'runner-*' --no-pager`.

### Grafana and logs

Everything listens on `127.0.0.1`. Tunnel from your laptop (any directory), then open `http://localhost:3000` (user `admin`) and `http://localhost:9090`:

```bash
ssh -N -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 ops@SERVER_IP
```

The Grafana password (server, as `ops`, any directory):

```bash
sudo grep GF_SECURITY_ADMIN_PASSWORD /opt/monitoring/.env
```

Logs are in Grafana, Explore, Loki, kept 7 days: `{unit="gitlab-runner.service"}`, `{unit="docker.service"}`, `{unit="sshd.service"} |= "Failed"`, `{compose_project="registry-cache"}`. Job containers are not collected; their output is the job log in GitLab.

## Concurrent jobs and limits

`concurrent` is the number of jobs at once and `request_concurrency` the number of parallel job requests to GitLab. The init writes `concurrent = 2`, which fits a CAX11 (2 vCPU, 4 GB); keep it at or below the vCPU count. Job containers have no CPU or memory limit unless you add one, so two heavy jobs can starve the host, Docker and the monitoring. A sizing that fits the CAX11 with `concurrent = 2` is 1.5 GB and 1.5 CPUs per job, leaving about 1 GB for the host. Add it under `[runners.docker]` in `/etc/gitlab-runner/config.toml`:

```text
memory = "1536m"
memory_swap = "1536m"
cpus = "1.5"
shm_size = 268435456
```

Edit with a backup, then restart while no jobs run. Server, as `ops`, any directory:

```bash
sudo cp -a /etc/gitlab-runner/config.toml /etc/gitlab-runner/config.toml.bak.manual
sudo nano /etc/gitlab-runner/config.toml
sudo gitlab-runner verify
sudo systemctl restart gitlab-runner
```

`pull_policy = "if-not-present"` reuses images on the host; GitLab allows that only for runners limited to trusted projects. Use `always` if you attach projects you don't control.

## Update

Laptop, repo root:

```bash
runner/bootstrap.sh SERVER_IP
```

Then server, as `ops`, any directory:

```bash
sudo bash -c 'cd /root/server-init-config && runner/update.sh --dry-run'
```

```bash
sudo bash -c 'cd /root/server-init-config && runner/update.sh'
```

Add `--os` to upgrade OS packages including Docker and GitLab Runner (never reboots), `--rollback` to restore the newest backup. `--pull` needs a git clone and a credential on the server, which this setup deliberately does not have: do not use it. The update only touches installed components; it syncs scripts, units and stack configs, backs up each changed file to `/var/backups/server-init-config/<timestamp>/` (last 5 kept), restores them if a check fails, skips CI-affecting steps while jobs run (exit code 3) and ends with `health -q`. It never touches secrets, `config.toml`, the registration, `daemon.json` or SSH.

## Troubleshooting

Runner-specific; the general table is in the [main README](../README.md#troubleshooting).

| Symptom | Cause and fix |
|---|---|
| `incomplete copy: the whole repository is needed` | Run `setup.sh` from a complete copy: rerun `runner/bootstrap.sh SERVER_IP` from your laptop. |
| `permission denied ... /var/run/docker.sock` in the runner log | The runner process lacks the `docker` group. `ps -o user=,supgrp= -p "$(systemctl show -p MainPID --value gitlab-runner)"` should list `docker`; then `sudo systemctl restart gitlab-runner`. |
| Runner will not start after the switch to `gitlab-runner` | `sudo journalctl -u gitlab-runner -n 30`. Usually a file in `/etc/gitlab-runner` still owned by root: `sudo chown -R gitlab-runner:gitlab-runner /etc/gitlab-runner`. |
| A monitoring container restarts with `permission denied` | Its volume belongs to the old user. Run `runner/update.sh` as above. |
| `Cannot connect to the Docker daemon` | `sudo systemctl status docker`, `sudo journalctl -u docker --since "-10min"`. |
| Runner offline in GitLab | `systemctl is-active gitlab-runner`, `sudo gitlab-runner verify`; the Cloud Firewall may block outbound HTTPS. |
| No logs in Grafana | `health` shows whether Loki and Alloy are ready; `sudo docker compose -f /opt/logging/docker-compose.yml logs --tail 50 alloy`. |
| Verdaccio restart-loops | The `docker0` IP changed (`bip` in `daemon.json`). Rerun `runner/update.sh` or `setup.sh --npm-cache`. |

<details>
<summary>Reference</summary>

### Files

| File | Purpose |
|---|---|
| `bootstrap.sh` | laptop side: copy the repo and run the safe components |
| `setup.sh` | installs components; `--list` shows what is installed |
| `register.sh` | registers the runner (asks for the `glrt-` token); wraps `install/register-runner.sh` |
| `update.sh` | brings installed components to the repo state; wraps `install/update.sh` |
| `install/` | one installer per component, `users.sh`, `lock-root.sh`, `update.sh` |
| `scripts/`, `systemd/` | weekly cleanup, disk guard, image prewarm and their timers |
| `stacks/` | Compose stacks: `monitoring`, `logging`, `registry-cache`, `npm-cache` |
| `ci/` | `.gitlab-ci.yml` snippets: smoke test, defaults, image mirroring |
| `cloud-init/` | generated user-data; sources in `templates/` |
| `COMMANDS.md` | copy-paste blocks, generated |

### What the init writes

- SSH drop-in `00-ci-hardening.conf`: no password or keyboard-interactive logins, root by key, no X11. sshd checks it first (`sshd -t`); if it is rejected the file is removed and the defaults stay.
- Security updates, journal limit (500 MB, 14 days), timezone, Docker Engine and GitLab Runner.
- Tools: htop, btop, ncdu, iotop, mtr, nano, vim, rsync, wget, unzip, bash-completion, skopeo, restic, dnf-utils, dig, lsof, sysstat, tcpdump, traceroute, nc, tmux, jq, git, mc, fd, rg, fzf. EPEL ones that are missing are logged to `ci-bootstrap-failed.log` and do not stop the boot.
- Not in the init, on purpose: users, closing root SSH, another SSH port, SELinux enforcing (`rocky-clean.yaml`), service users.

### Check the first boot

Server, as `ops` (after the users step), any directory:

```bash
cloud-init status --long
sudo cat /var/log/ci-bootstrap-failed.log
sudo sshd -T | grep -Ei '^(port|passwordauthentication|permitrootlogin|allowgroups|allowtcpforwarding) '
```

The log file does not exist when nothing failed. Before the users step, run the same as root over `ssh root@SERVER_IP`.

### Other setup.sh flags

| Flag | Installs |
|---|---|
| `--security` | security tools for your own host (lynis, OpenSCAP, auditd, nmap, trivy, gitleaks, ...); not part of `--base` or `--all` |
| `--prewarm` | daily pre-pull of CI images; asks for a deploy token with `read_registry` |
| `--selinux` | SELinux enforcing, then checks Docker and the runner; restarts Docker, so no jobs running; last |
| `--lock-root` | closes root SSH; never part of `--all` |

### Security tools (authorized use only)

Run them only against hosts you own or are authorized to test; on Hetzner, scanning third-party systems violates their terms. Server, as `ops`, any directory:

```bash
sudo bash -c 'cd /root/server-init-config && runner/setup.sh --security'
```

```bash
sudo bash -c 'cd /root/server-init-config && common/security-tools.sh --aide --audit-timer'
```

The second adds opt-in extras (`--help` lists them); the runner host is a 4 GB machine, mind the RAM. Commands for every tool are in [../server/README.md](../server/README.md#security-tools); `health` reports on them when installed.

### Remove or replace the runner

Server, as `ops`, any directory:

```bash
sudo gitlab-runner unregister --all-runners
```

Then delete the runner in GitLab if it still shows, create a new one and run `register.sh` again.

### Security notes

- The token is stored only in `/etc/gitlab-runner/config.toml` (owner `gitlab-runner`, mode `600`). Never put it in user-data.
- Job containers are not privileged. Enable `privileged = true` only for trusted projects that need Docker-in-Docker.
- Monitoring, logging and the caches listen on `127.0.0.1` or the `docker0` bridge. `/srv/ci-cache` and the npm cache are shared by every project: no untrusted projects or forks.
- Not done here: rootless Docker and `userns-remap` (they change ownership of bind mounts and caches), a host firewall next to the Cloud Firewall, and filtering the cloud metadata endpoint (169.254.169.254) from job containers, which GitLab suggests.

### Decommission

Delete the runner in GitLab, then the server and its Primary IPv4 in Hetzner (billed separately even when unattached), and leftover snapshots.

</details>
