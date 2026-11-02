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

   It waits for cloud-init (and shows `/var/log/ci-bootstrap-failed.log` if a step failed), streams `git archive HEAD` to `/root/server-init-config`, installs users, admin tools, health and cleanup, the runner registration (you type the token on the server), Docker Hub cache, monitoring, logging, npm cache and shared cache, and ends with `health`. It also turns on the host firewall and fail2ban. Options: `--no-register`, `--no-firewall`, `--with-prewarm`, `--user`, `--port`, `--allow-dirty`, `--dry-run`. `DOMAIN` and `ACME_EMAIL` in the environment add Grafana on an HTTPS domain. It never runs lock-root or selinux; if SELinux is not enforcing on the server (`rocky-clean.yaml` leaves it as the image has it), it prints the command for it at the end. Rerunning is safe: installed components are skipped.
4. **Smoke test**: run `ci/smoke.yml` in a project. The log must show `on <runner description>` and `aarch64` (`x86_64` on x86). If the job stays pending, check `tags:`.
5. **Test the admin login** from a second terminal (laptop, any directory), then close root SSH if you want:

   ```bash
   ssh ops@SERVER_IP 'sudo -n true && echo ok'
   ```
6. **SELinux (Rocky with `rocky-clean.yaml`)**: the clean init leaves the mode as the image has it. While no CI job runs, make it enforcing (server, as `ops`, any directory; restarts Docker):

   ```bash
   sudo bash -c 'cd /root/server-init-config && runner/setup.sh --selinux'
   ```

### Which init file

| File | OS | What the server has after boot |
|---|---|---|
| `cloud-init/rocky-clean.yaml` (recommended) | Rocky 10 | Docker, GitLab Runner, SSH hardening (password logins off), security updates, admin tools, aliases, tmux. Nothing else: SELinux, users and caches come from `setup.sh`. |
| `cloud-init/rocky.yaml` | Rocky 10 | The same host plus the Docker Hub cache on `127.0.0.1:5000`, weekly cleanup, disk guard and engine update timers, the job isolation rules, SELinux enforcing; firewalld is left as the image has it. No aliases and no `health`; `bootstrap.sh` adds them, together with the host firewall and fail2ban. |
| `cloud-init/debian.yaml` | Debian 13 | Docker, GitLab Runner, Docker Hub cache, cleanup timers, unattended-upgrades. |
| `cloud-init/*-x86.yaml` | x86_64 | The same for CX, CPX and CCX servers. |

Pick one: `rocky-clean.yaml` gives you each component as a deliberate step, `rocky.yaml` is the all-in-one. `bootstrap.sh` works with either, because installed components are skipped. The init never changes users, the SSH port or the SSH login: you log in as root with your key until you decide otherwise.

## What the bootstrap does, step by step

You can run every step yourself with `setup.sh`, on the server, as root, in `/root/server-init-config` (or from `ops` with `sudo bash -c 'cd /root/server-init-config && runner/setup.sh --list'`). The repo copy is under `/root`, which `ops` cannot read, so always wrap the command like this.

| # | Step | `setup.sh` flag | Check |
|---|---|---|---|
| 1 | Users: admin `ops`, service accounts, SSH hardening (root stays open) | `--users` | `ssh ops@SERVER_IP 'sudo -n true && echo ok'` |
| 2 | Admin tools and aliases | `--packages` | `htop --version` |
| 3 | `health`, weekly cleanup, disk guard, job isolation, weekly Docker and runner update, kernel hardening (sysctl), no core dumps | `--tools` | `health -q`, `systemctl list-timers 'runner-*'`, `systemctl is-active ci-job-isolation` |
| 3b | Host firewall (SSH only) and fail2ban | `--firewall` | `sudo firewall-cmd --list-all` or `sudo ufw status`, `sudo fail2ban-client status sshd` |
| 4 | Register the runner (asks for the token; also sets the per-job limits) | `--register`, `--job-limits` | GitLab shows it Online; `sudo gitlab-runner verify` |
| 5 | Docker Hub cache | `--registry-cache` | `curl -s 127.0.0.1:5000/v2/_catalog` |
| 6 | Monitoring (Prometheus, node_exporter, Grafana) | `--monitoring` | SSH tunnel, then `http://localhost:3000` |
| 7 | Logging (Loki, Alloy) | `--logging` | `health` shows both ready |
| 8 | npm cache (needs 4) | `--npm-cache` | `sudo grep 'environment =' /etc/gitlab-runner/config.toml` |
| 9 | Shared cache `/srv/ci-cache` (needs 4, trusted projects only) | `--shared-cache` | `sudo grep 'volumes =' /etc/gitlab-runner/config.toml` |
| opt | Image prewarm, Grafana domain, security tools, SELinux, lock root | `--prewarm`, `--grafana-domain`, `--security`, `--selinux`, `--lock-root` | see below |

`--base` is steps 1, 2, 3, 3b, 5, 6; `--all` is `--base` plus 4, 7, 8, 9 and asks for the token. Components are installed in this order whatever the flag order. If one fails, fix the cause and rerun the same command.

Server, as `ops`, any directory:

```bash
sudo bash -c 'cd /root/server-init-config && runner/setup.sh --list'
```

```bash
sudo bash -c 'cd /root/server-init-config && DOMAIN=grafana.example.com ACME_EMAIL=you@example.com runner/setup.sh --grafana-domain'
```

The domain needs monitoring, an A record and TCP 80 and 443 in the Cloud Firewall. The step also opens 80/443 in the host firewall (firewalld or ufw) so the certificate can be issued; the SSH rules are not touched.

### Without a repo copy

[`COMMANDS.md`](COMMANDS.md) has one self-contained block per component, generated from the repo files by `tools/render-paste-commands.py`. Paste a block into an SSH session as `ops` (as root before the Users block ran); it writes the files it needs and runs the installer. Use them in order and skip what you don't need. The first block, "Base host", gives a Rocky server created without the init the same base as `rocky-clean.yaml`; paste the Users block after it.

## Users

| User | Kind | SSH | What it does |
|---|---|---|---|
| `ops` | admin | by key | your login; sudo without password; not in the `docker` group, so Docker needs `sudo` |
| `gitlab-runner` | service | no | the runner service; Docker access through the `docker` group, which the executor needs |
| `monitoring` | service | no | Prometheus, node_exporter, Grafana, Loki and Alloy; reads its config but cannot change it |
| `root` | | by key until locked | the init does not change it |

SSH accepts keys only, and only members of `ssh-users`. Local forwarding (`ssh -L`) works; remote, agent and X11 forwarding are off. Set `ADMIN_USER=...` for another admin name. `SSH_PORT=...` for another port is remembered from `00-ci-hardening.conf`, so reruns, `--lock-root` and `--unlock-root` keep it (`SSH_PORT=22` goes back to 22); `users.sh` opens the port in the host firewall (firewalld or ufw) and refuses to write the config if the running rules do not allow it; open it in the Cloud Firewall first. Why the split: anyone with the Developer role in a project can compromise a runner host, and `docker` group membership is root-equivalent, so nobody you log in as has it.

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

### Grafana upgrade and rollback

Grafana migrates its SQLite database forward on the first start of a new version and cannot go back (13.0 also moves folders and dashboards into a new storage; an older Grafana then reads stale tables). So `runner/update.sh` (and `setup.sh --monitoring`, if an old volume is left over) first runs `runner/install/monitoring-backup.sh`. When the Grafana major in the repo differs from the installed one, it stops Grafana, writes the data volume to `/var/backups/monitoring/grafana-<old version>-<date>.tar.gz` (root only, mode 0600, last 3 kept) and starts it again; with the same major it does nothing, and a rerun after the compose file was updated keeps the first archive. The archive holds the database and its secrets: do not copy it off the server. If the helper container cannot run (image pull refused, no network), the backup fails and `update.sh` stops before it changes anything; it never skips the backup silently. `update.sh --dry-run` only reports what it would do. A volume left over from an earlier install is archived too; when its version cannot be told (no compose file and no old container) the archive is named `grafana-unknown-...`.

`update.sh --rollback` restores repo-managed files only, never this data. It decides by what actually ran, not by the compose file: if the Grafana container that was started is on a newer major than the backed-up compose file, the old Grafana cannot read the migrated database, so `/opt/monitoring/docker-compose.yml` is not restored at all (the installed file, with its image tag and the 512 MB limit, stays), everything else is restored, and the command says so. The same applies when an update fails after Grafana started (Prometheus not ready). If the new Grafana never started (for example `docker compose pull` failed after the new compose file was written), the data is untouched and `--rollback` puts the old compose file and image back. Going back to the old Grafana after it migrated always means restoring the archive, as below.

On a first install `runner/install/monitoring.sh` generates `GF_SECURITY_SECRET_KEY` into `/opt/monitoring/.env` (root only, mode 600, never printed). Grafana encrypts stored credentials (data source passwords, API keys) with this key; without it Grafana uses a default key that is public, so a copy of `grafana.db` could be decrypted by anyone. Keep the key together with every backup archive (store both the same way): an archive restored without its key keeps the encrypted values but cannot read them. Never add or change the key on an install that already has data, the old values would become unreadable; installs from before this change, and a first install over a leftover volume, keep the default key (the backup step says so). To move such an install to its own key, re-enter the data source credentials in Grafana after setting `GF_SECURITY_SECRET_KEY` in `.env`.

The upgrade from 12.0.0 to 13.x skips the latest 12.x minor that the Grafana 13.0 upgrade notes recommend as a stop. It was not staged on purpose: the database of this stack is small (one provisioned dashboard and datasource, no hand-made content by default) and the CI test (`tools/ci/runner-host-e2e.sh`, section 4) upgrades a 12.0.0 database that holds a folder and a dashboard straight to the repo tag and checks that both survive. If you keep much hand-made content in this Grafana, set the tag to `12.4.13` in `/opt/monitoring/docker-compose.yml`, run `docker compose up -d grafana` there, check `/api/health`, and only then run `runner/update.sh`, which still archives the data before the move to 13. Grafana 13 migrates dashboards on the first start and the container limit is 512 MB; CI covered a small database only. A large `grafana.db` that is OOM-killed during the migration shows up as `sudo docker inspect -f '{{.State.OOMKilled}}' monitoring-grafana-1` printing `true`: restore the archive as below, raise `mem_limit` for `grafana` in `/opt/monitoring/docker-compose.yml`, and start the new image again.

To go back (server, as `ops`, any directory), first put the repo checkout in `/root/server-init-config` back to the commit you upgraded from, otherwise the next `runner/update.sh` upgrades again. List the archives, newest first:

```bash
sudo ls -1t /var/backups/monitoring
```

Restore one (replace `FILE` with the archive named after the old version, for example `grafana-12.0.0-20261102-101500.tar.gz`; this replaces everything in the Grafana volume, but only after `tar -tzf` has read the whole archive, so a corrupt or truncated file stops the command before anything is deleted), then start the old image:

```bash
sudo bash -c 'tar -tzf /var/backups/monitoring/FILE >/dev/null && cd /opt/monitoring && docker compose stop grafana && docker run --rm -i --network none -v monitoring_grafana-data:/v alpine:3.22@sha256:2e0b81d60597f449baa56dc25d355367869d2dca4cd57e866f1e2b52af3eb55f sh -c "find /v -mindepth 1 -delete && tar -xzf - -C /v" < /var/backups/monitoring/FILE'
```

```bash
sudo bash -c 'cd /opt/monitoring && sed -i "s|image: grafana/grafana:.*|image: grafana/grafana:12.0.0|" docker-compose.yml && docker compose up -d grafana && curl -fsS http://127.0.0.1:3000/api/health'
```

`version` in the answer should be the old one. Dashboards edited after the upgrade are lost; the provisioned runner dashboard comes back from the repo files.

## Concurrent jobs and limits

`concurrent` is the number of jobs at once and `request_concurrency` the number of parallel job requests to GitLab. The init writes `concurrent = 2`, which fits a CAX11 (2 vCPU, 4 GB); keep it at or below the vCPU count.

Registering the runner (or `setup.sh --job-limits`) adds per-job limits under `[runners.docker]` in `/etc/gitlab-runner/config.toml`, so one job cannot starve the host, Docker and the monitoring:

```text
memory = "1536m"
memory_swap = "1536m"
cpus = "1.5"
pids_limit = 2048
shm_size = 268435456
cgroup_parent = "ci-jobs.slice"
service_memory = "384m"
service_memory_swap = "384m"
service_cpus = "0.5"
service_cgroup_parent = "ci-jobs.slice"
```

The `service_*` keys give the same kind of limit to the `services:` containers of a job (postgres, redis, ...). GitLab Runner has no per-container process limit, so processes are capped for all jobs together: the step writes `/etc/systemd/system/ci-jobs.slice` with `TasksMax=4096` and `MemoryMax=3G`, and every job and service container runs inside that slice (`cgroup_parent`). A fork bomb in a job stops at that ceiling instead of exhausting the host.
Two jobs at 1.5 GB and 1.5 CPUs leave about 1 GB and one CPU's worth for the host on a CAX11. A job over its memory limit is killed (exit code 137) instead of freezing the server. Values you set yourself in `config.toml` are kept; to change them, pass the new values and rerun the step (a backup is made; the runner reloads the file by itself, new jobs get the new limits). Server, as `ops`, any directory:

```bash
sudo bash -c 'cd /root/server-init-config && JOB_MEMORY=3g JOB_CPUS=2 runner/install/job-limits.sh'
```

`JOB_MEMORY`, `JOB_MEMORY_SWAP` (default: equal to the memory, so no swap), `JOB_CPUS`, `JOB_SHM_SIZE` (bytes), `JOB_SERVICE_MEMORY`, `JOB_SERVICE_MEMORY_SWAP`, `JOB_SERVICE_CPUS`, `JOBS_TASKS_MAX` (processes for all jobs together) and `JOBS_MEMORY_MAX` (memory for all jobs together; empty turns it off) are the settings.

### What jobs cannot reach

`ci-job-isolation.service` (installed with `--tools`, reapplied after every Docker start) sets two kinds of iptables rules for IPv4:

- Traffic from containers to `169.254.169.254` (Hetzner metadata) is dropped in `DOCKER-USER`.
- Traffic from `docker0` and the `br-*` bridges to the host itself goes through the chain `CI-JOBS-IN`: replies, ping and the npm cache (docker0 IP, port 4873) are let in, everything else is dropped.

Internet access of jobs, the Docker Hub cache (Docker pulls through the mirror, jobs do not) and traffic between the containers of one job are not affected. Check, server, as `ops`, any directory: `sudo iptables -S DOCKER-USER`, `sudo iptables -S CI-JOBS-IN`. If a job legitimately needs a host service, add an `ACCEPT` rule for it to `CI-JOBS-IN` in `runner/scripts/ci-job-isolation.sh` and rerun `sudo systemctl restart ci-job-isolation`.

### Updates of Docker and GitLab Runner

`dnf-automatic` (security only) and `unattended-upgrades` do not cover the Docker and GitLab repositories. `runner-engine-update.timer` (Sunday 04:30) upgrades `docker-ce*`, `containerd.io` and `gitlab-runner` only when `docker ps` answers and shows no CI job; otherwise it logs why it skipped and tries again next week. Before upgrading it stops the runner gracefully (no new job, a job already running finishes; the script adds a `KillSignal=SIGQUIT` drop-in for that), looks at the job list again, and only then upgrades; if a job is still there it starts the runner again and changes nothing. It then restarts Docker, starts the runner and checks both are active. The result is one line in `/var/log/runner-engine-update.log`, which `health` shows. Run it now (server, as `ops`, any directory): `sudo runner-engine-update.sh --dry-run`, then `sudo runner-engine-update.sh`.

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
| `reboot` or `systemctl restart gitlab-runner` takes very long | After the weekly engine update has run once, the runner stops gracefully (`KillSignal=SIGQUIT`, no stop timeout): a reboot or restart waits until running jobs finish, bounded only by the GitLab job timeout. To force it now: `sudo systemctl kill -s SIGTERM gitlab-runner` (running jobs are lost). |
| Verdaccio restart-loops | The `docker0` IP changed (`bip` in `daemon.json`). Rerun `runner/update.sh` or `setup.sh --npm-cache`. |
| Verdaccio restart-loops after an upgrade | `sudo docker compose -f /opt/npm-cache/docker-compose.yml logs --tail 30`. The start script prints what it did (lines starting with `npm-cache:`); see [npm cache upgrade](#npm-cache-upgrade-and-rollback). |

### npm cache upgrade and rollback

Verdaccio 7 (`verdaccio/verdaccio:7.0.2`) replaced 6.1.2. The cache only holds copies of what npmjs serves, so the upgrade does not convert anything:

- On every start a script from the compose file (`configs: start`) runs before Verdaccio. It records the deployed major version in `/verdaccio/storage/.deployed-major` inside the `npm-cache_verdaccio-storage` volume. If that file is missing but the storage is not empty, the storage counts as 6.x.
- Storage of another major version is moved, not deleted, to `/verdaccio/storage/backup-6.x-<date>-<time>/` (same volume, so the move is instant and the data stays). Version 7 starts empty and fills again from npmjs on demand. The log line starts with `npm-cache:`. Rerunning changes nothing: with the state file at `7` it does not touch the storage. The backups use disk space; delete one yourself once you no longer need it.
- Version 7 refuses to start unless the server secret is exactly 32 characters, and there is no setting or environment variable for it: it lives in `data/.verdaccio-db.json` in the storage. The script keeps a valid one and otherwise writes 32 hex characters (128 random bits) from `/dev/urandom` to that file, mode 600, owner uid 10001. It is generated once, stays across restarts and recreations, and is never printed or logged. Tokens stay valid only while it is unchanged; the cache uses none (no registration, anonymous reads).
- `runner/update.sh` only syncs `docker-compose.yml` and `config.yaml` and recreates the container, so the script travels inside the compose file and the update upgrades existing servers the same way.

Rollback, server, as `ops` (the old compose file is the pre-update copy in `/var/backups/server-init-config/<timestamp>/opt/npm-cache/`, or the file from the older repo commit with the `docker0` IP substituted; the new one would move the storage aside again):

```bash
sudo docker compose -f /opt/npm-cache/docker-compose.yml down
sudo cp -a /var/backups/server-init-config/TIMESTAMP/opt/npm-cache/docker-compose.yml /opt/npm-cache/docker-compose.yml
sudo docker run --rm -v npm-cache_verdaccio-storage:/s --entrypoint sh verdaccio/verdaccio:6.1.2 -c 'ls -d /s/backup-*'
sudo docker run --rm -v npm-cache_verdaccio-storage:/s --entrypoint sh verdaccio/verdaccio:6.1.2 -c 'cd /s && mkdir undone-7.x && mv data htpasswd .deployed-major undone-7.x/; mv BACKUP/* . && rmdir BACKUP'
sudo docker compose -f /opt/npm-cache/docker-compose.yml up -d
```

Replace `BACKUP` with the directory name from the `ls` (for example `backup-6.x-20261102-150730`). The 7.x storage is kept in `undone-7.x` (a missing `htpasswd` in the `mv` is harmless). Without the second `docker run`, 6.1.2 also starts on the storage that 7.x wrote (same layout, secret of 32 characters); it is only a cache. Do not run 6.x and 7.x on the same storage at the same time. `runner/update.sh` and `setup.sh --npm-cache` move to 7.x again, so keep the repository on the old commit while you stay on 6.x.

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
- Security updates, journal limit (500 MB, 14 days), timezone, kernel hardening (`kptr_restrict`, `dmesg_restrict`, `ptrace_scope`, protected fifos and regular files, `log_martians`) and core dumps off.
- Docker Engine and GitLab Runner from repo files written by the init. The signing keys are installed only if their fingerprints match (`pin-repo-key`): Docker `9DC8 5822 9FC7 DD38 854A  E2D8 8D81 803C 0EBF CD88` (checked against the key download), GitLab Runner `F640 3F65 44A3 8863 DAA0  B6E0 3F01 618A 5131 2F3F` (from GitLab's install docs, **not verified here**: compare it with https://docs.gitlab.com/runner/install/linux-repository/ before relying on it; a mismatch stops the install instead of trusting the key).
- Tools: htop, btop, ncdu, iotop, mtr, nano, vim, rsync, wget, unzip, bash-completion, skopeo, dnf-utils, dig, lsof, sysstat, tcpdump, traceroute, nc, tmux, jq, git, mc, fd, rg, fzf. EPEL ones that are missing are logged to `ci-bootstrap-failed.log` and do not stop the boot.
- Not in the init, on purpose: users, closing root SSH, another SSH port, SELinux enforcing (`rocky-clean.yaml`), service users.

### Reboot on first boot (Rocky)

The Rocky image boots an older kernel than the one the package upgrade installs, and the new kernel's `kernel-modules` (netfilter) exist only for the new kernel. Until then `dockerd` cannot add its iptables rules and does not start. The init files check for that at the end and reboot once, from a unit that starts after `cloud-final.service` (so `cloud-init status` still ends `done`); `/var/log/ci-docker-reboot.log` then holds the last Docker journal lines. After the reboot Docker, the job isolation rules and the cache start by themselves.

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
- The host firewall (`--firewall`), fail2ban for SSH, the block of the cloud metadata address and host services for jobs, and per-job resource limits are set up by the steps above. IPv6 is not filtered by the job isolation.
- Not done here: rootless Docker and `userns-remap` (they change ownership of bind mounts and caches).

### Decommission

Delete the runner in GitLab, then the server and its Primary IPv4 in Hetzner (billed separately even when unattached), and leftover snapshots.

</details>
