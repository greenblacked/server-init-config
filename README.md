# server-init-config

Bootstrap and operations config for a self-hosted GitLab Runner on Hetzner Cloud.
It's built for an ARM64 CAX11 running Rocky Linux 10. Debian 13 and x86_64 work too.

Two bootstraps, run from your laptop: [`server/bootstrap.sh`](server/README.md#bootstrap-from-your-laptop) for a plain server (hardening, `health`, maintenance tools, never a runner) and [`runner/bootstrap.sh`](runner/README.md) for a GitLab Runner host.

The quickest path on Rocky is [`runner/`](runner/README.md): a base init, then every component installed with `setup.sh --<component>` or a self-contained copy-paste block from `runner/COMMANDS.md`. Its README starts with [the plan: what to apply in which order](runner/README.md#plan-what-to-apply-in-which-order). The rest of this file describes the full layout and the step-by-step variant.

What a server built from this repo has:

- Docker Engine and GitLab Runner (docker executor), with job pickup tuned via `request_concurrency`
- A Docker Hub pull-through cache on `127.0.0.1:5000`, registered as a Docker mirror
- Optionally, a Verdaccio npm cache and a shared `/srv/ci-cache` for npm and Sonar
- Optionally, a daily prewarm of the CI images from GitLab Container Registry
- Weekly cleanup, plus an emergency disk guard at 85%
- Optionally, Prometheus, node_exporter and Grafana, all bound to `127.0.0.1`, plus Grafana on an HTTPS domain via Caddy
- Optionally, log collection: Loki + Grafana Alloy for container logs and the systemd journal, 7 days, queried in Grafana
- A `health` command: one report covering the system, security, services, runner, containers, caches and 24h trends
- Optionally, an admin login `ops` with sudo and `gitlab-runner` and `monitoring` as service accounts without login (`runner/install/users.sh`), then root SSH closed (`runner/install/lock-root.sh`); the init itself keeps root login by key
- SSH keys only, automatic security updates, SELinux enforcing (on Rocky)

## Layout

| Path | Purpose |
|---|---|
| `runner/` | everything for a GitLab Runner host: `cloud-init/` (generated user-data, `templates/` are the sources), `install/` (installers and `update.sh`), `scripts/` and `systemd/` (cleanup, disk guard, image prewarm), `stacks/` (Docker Compose stacks: `monitoring`, `logging`, `registry-cache`, `npm-cache`), `ci/` (`.gitlab-ci.yml` snippets), `setup.sh`, `register.sh`, `update.sh`, `bootstrap.sh`, `COMMANDS.md` and its [README](runner/README.md) (**start here for a Rocky runner**) |
| `server/` | general servers (not runners): base setup scripts for Fedora 44, CentOS Stream / Rocky / AlmaLinux 10, Ubuntu 26.04 / Debian 13 (including Hetzner Apps images) and openSUSE Leap 16, `cloud-init/` (generated user-data embedding `server-init-*.sh`), the maintenance tools, `bootstrap.sh`, and `ai/` with `install-ai.sh` (Ollama + Open WebUI for a separate small server, see [Local AI](#local-ai-separate-server)); see its [README](server/README.md) |
| `common/` | used by both: `health`, `shell-history.sh`, `lib.sh`, `admin-tools.sh`, `security-tools.sh` with `kali`, `security-audit-run.sh`, `security/kali/` and `systemd/` (optional security tools for auditing your own servers, see [`server/README.md`](server/README.md#security-tools)) |
| `tools/render-cloud-init.py` | renders templates and embeds repo files; `--check` detects stale output |
| `tools/render-paste-commands.py` | renders `runner/COMMANDS.md` from the repo files; `--check` detects stale output |
| `tools/test-cloud-init.py`, `tools/test-server-tools.sh` | tests for the generated cloud-init files and the server tools |

## Build a new server

1. **Hetzner Console**: create the server (CAX11, `nbg1`, Rocky Linux 10 or Debian 13), add your SSH key, and paste `runner/cloud-init/rocky.yaml` or `runner/cloud-init/debian.yaml` as Cloud config. For an x86 server (CX/CPX/CCX) you can paste `runner/cloud-init/rocky-x86.yaml` or `runner/cloud-init/debian-x86.yaml`; then set the runner's tag and the `tags:` in `runner/ci/*.yml` to your x86 tag instead of `arm64`, and expect `x86_64` instead of `aarch64` in the smoke test.
2. **Firewall**: inbound TCP 22 from your IP only, ICMP optional, outbound left empty (empty means allow all). Open 80/443 only if you publish Grafana.
3. **Bootstrap from your laptop** (primary path). Create the runner in GitLab first (Settings → CI/CD → Runners → New runner), then, from a clean checkout of this repo:

   ```bash
   runner/bootstrap.sh SERVER_IP
   ```

   On a new server, accept its host key first (the script uses `BatchMode` and never auto-accepts keys): connect once with `ssh root@SERVER_IP` and compare the fingerprint with the one in the cloud-init console output (Hetzner Console, server, Console), or `ssh-keyscan -p PORT SERVER_IP >> ~/.ssh/known_hosts` after verifying it the same way.

   It waits for cloud-init (and stops with `/var/log/ci-bootstrap-failed.log` if it failed), streams `git archive HEAD` to `/root/server-init-config` over SSH (the repo is private and no credential goes to the server), installs users, admin tools, host tools, the runner registration, Docker Hub cache, monitoring, logging and the npm and shared caches via `runner/setup.sh`, and ends with `health`. You type the `glrt-` token at the prompt on the server. Root SSH stays open: the script never runs `lock-root` or `selinux`. Options: `--no-register`, `--with-prewarm`, `--user`, `--port`, `--allow-dirty`, `--dry-run` (see `--help`); `DOMAIN` and `ACME_EMAIL` in the environment add Grafana on a domain. Rerunning is safe: the server copy is replaced and installed components are skipped.

   Then go to step 6. Steps 4 and 5 below, and the copy in this paragraph, are the manual alternative to step 3.

   **Manual alternative: wait for cloud-init**, then copy the repo to the server. You log in as root with your key, as Hetzner sets it up; the init only switches off password logins. The repo is private, so either use `scp` from your laptop or a read-only deploy key:

   ```bash
   ssh root@SERVER_IP cloud-init status --wait
   scp -r server-init-config root@SERVER_IP:
   ssh root@SERVER_IP
   ```

4. **Manual: install the host tools and register the runner.** Create the runner in GitLab first (Settings → CI/CD → Runners → New runner) and copy its `glrt-` token:

   ```bash
   cd ~/server-init-config
   sudo runner/install/host-tools.sh
   sudo DESCRIPTION=hetzner-cax11 runner/install/register-runner.sh
   ```

5. **Manual: optional components**, in this order:

   ```bash
   sudo runner/install/monitoring.sh
   sudo runner/install/logging.sh
   sudo runner/install/npm-cache.sh
   sudo runner/install/shared-cache.sh
   sudo runner/install/image-prewarm.sh
   sudo DOMAIN=grafana.example.com ACME_EMAIL=you@example.com runner/install/grafana-domain.sh
   ```

   Run `runner/install/selinux-enforcing.sh` only on servers that weren't built from the Rocky cloud-init, which already enables it. Servers built from an older init move to the new users with `runner/install/users.sh` and `runner/install/lock-root.sh`; the steps are in [`runner/README.md`](runner/README.md#moving-an-existing-server-to-these-users).

6. **Validate**:

   ```bash
   sudo health
   ```

   Then run `runner/ci/smoke.yml` in a project. Its log must show `on <your runner description>` and `aarch64` (`x86_64` on an x86 server). If you used the bootstrap script, test `ssh ops@SERVER_IP 'sudo -n true && echo ok'` from a second terminal, then close root SSH with `setup.sh --lock-root`.

## Local AI (separate server)

`server/install-ai.sh` runs a lightweight local chat on a second, small server (2 vCPU / 4 GB): Ollama with one small model and Open WebUI in front of it, CPU only. It is not meant for the runner host, where a model would compete with CI jobs for memory; the installer warns if `gitlab-runner` is active.

What it does: creates a 2 GB swap file if the host has none, copies `server/ai/docker-compose.yml` to `/opt/ai`, generates `WEBUI_SECRET_KEY` into a root-only `.env`, starts the stack and pulls the model. Open WebUI listens on `127.0.0.1:3080` only (3000 is left to Grafana; set `UI_PORT=<port>` if 3080 is taken, the choice is saved in `.env`, and an existing install keeps the port already in `/opt/ai/.env` unless `UI_PORT` is set) and Ollama publishes no port, so nothing new is reachable from the internet.

```bash
cd ~/server-init-config
sudo server/install-ai.sh                          # default model qwen2.5:1.5b
sudo MODEL=llama3.2:1b server/install-ai.sh        # smaller and faster, fits the 2 GB Ollama limit
```

Bigger models (for example `llama3.2:3b`) need a higher `mem_limit` for `ollama` in `server/ai/docker-compose.yml` first.

Then, from your laptop:

```bash
ssh -N -L 3080:127.0.0.1:3080 ops@SERVER_IP    # use your UI_PORT on both sides if you changed it
```

Open `http://localhost:3080` and create the first account. It becomes the admin, and Open WebUI closes sign-ups automatically at that moment. Verify with:

```bash
sudo server/install-ai.sh --check-signup
```

The check is read-only. Sign-ups live in Open WebUI's own database, not in `.env`; to open or close them later, use Admin Panel → Settings → General.

Expect a few tokens per second on shared vCPUs: good for short questions, translation and summaries, not a replacement for a hosted model. To update, change the image tags in `server/ai/docker-compose.yml` and rerun `server/install-ai.sh`; `runner/install/update.sh` does not manage this stack. `docker compose down` in `/opt/ai` stops it and keeps models and chats; `docker compose down -v` deletes both for good.

## Update a server

`runner/install/update.sh` brings a running server to the state of the repo checkout. It only touches components that are installed: host tools, monitoring, logging, registry cache, npm cache. It never touches secrets (passwords, tokens, `config.toml`), the runner registration or `daemon.json`. In the monitoring and logging `.env` files it only sets `MON_UID` and `MON_GID` (logging also `DOCKER_GID`) and keeps the file root-only at mode `600`. For logging it also creates or removes `/opt/logging/docker-compose.override.yml` (extra `group_add` for the journal group, only when its gid differs from the docker gid).

```bash
# 1. get the new repo state onto the server (scp copy, or a git clone there)
scp -r server-init-config ops@SERVER_IP:
ssh ops@SERVER_IP

# 2. preview, then apply
cd ~/server-init-config
sudo runner/install/update.sh --dry-run
sudo runner/install/update.sh
```

| Option | Effect |
|---|---|
| `-n`, `--dry-run` | print what would change, change nothing |
| `--pull` | `git pull --ff-only` in the checkout first (needs a git clone on the server) |
| `--os` | also upgrade OS packages, Docker and GitLab Runner included; never reboots, only tells you when a reboot is advisable |
| `--rollback` | restore the files from the newest backup and recreate the stacks |

What it does on every run:

- Validates before changing: `bash -n` for scripts, `promtool` for the Prometheus config, `jq` for the dashboard, `docker compose config` for stacks.
- Backs up each changed file to `/var/backups/server-init-config/<timestamp>/` (last 5 runs kept). If validation fails or a stack does not come back healthy, the files changed in that run are restored automatically.
- Reloads Prometheus, restarts Grafana only if its provisioning changed, and recreates a cache stack only if its config changed.
- Skips steps that would interrupt CI (cache stacks, `--os`) while jobs are running, lists them at the end and exits with code `3`. Rerun when the runner is idle.
- Finishes with `health -q`.

Rollback: `runner/install/update.sh --rollback` restores the newest backup. Running `update.sh` again re-applies the repo state. Older backups are plain file trees (paths mirror `/`), so you can copy single files back by hand.

Not updated by this script: `/etc/gitlab-runner/config.toml` (use `runner/install/register-runner.sh`, `shared-cache.sh`, `npm-cache.sh`), the Caddy override created by `grafana-domain.sh`, users and SSH (use `runner/install/users.sh`), and files written by cloud-init (dnf-automatic, kernel settings). It does move the monitoring and logging containers to the `monitoring` service user and hands their data volumes over, so `runner/install/users.sh` must have run first.

## The `health` command

```bash
sudo health        # full report (~10-40 s); the admin alias `health` adds sudo
sudo health -q     # skip runner verify, network and pending-update checks
sudo health -c     # only container health
sudo watch -n 5 'health -c --no-color'
```

Exit codes: `0` OK, `1` warnings, `2` failures. The thresholds are variables at the top of `common/health`.

## Changing configs

Edit the source files, then regenerate the cloud-init files before committing:

```bash
tools/render-cloud-init.py
tools/render-cloud-init.py --check
tools/render-paste-commands.py
tools/render-paste-commands.py --check
tools/test-cloud-init.py          # schema, syntax, embedded files, live SSH login, lockout guard
shellcheck -S warning common/*.sh common/health common/kali runner/*.sh runner/install/*.sh runner/scripts/*.sh server/*.sh
```

The cloud-init output stays under Hetzner's 32 KiB user-data limit (the renderer fails above it). `runner/install/users.sh` is embedded; `health` isn't, and is installed with `runner/install/host-tools.sh` instead.

## Security notes

- No tokens or passwords are stored in this repo. Runner tokens, deploy tokens and the Grafana password are entered or generated on the server.
- Users: you log in as the admin `ops`, by key, with sudo. `gitlab-runner` and `monitoring` are service accounts without login; the runner service and the monitoring and logging containers run as them. Nobody you log in as is in the `docker` group, which is root-equivalent. Details and the reasoning are in [`runner/README.md`](runner/README.md#users).
- `/etc/gitlab-runner/config.toml` (owned by `gitlab-runner`) and `/root/.docker/config.json` contain credentials and are kept at mode `600`.
- Job containers are not privileged. Enable `privileged = true` only for trusted projects that need Docker-in-Docker.
- Verdaccio binds to the `docker0` bridge IP. If that IP changes (`bip` in `daemon.json`), the container restart-loops until you rerun `runner/install/update.sh` or `runner/install/npm-cache.sh`.
- `/srv/ci-cache` and the npm cache are shared by every project on the runner. Don't attach untrusted projects or forks.
- All monitoring and cache ports listen on `127.0.0.1` or the `docker0` bridge. Reach Grafana and Prometheus through an SSH tunnel: `ssh -N -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 ops@SERVER_IP`.

## Rollback

Every installer backs up what it changes as `*.bak.<timestamp>`:

```bash
sudo -i    # the commands below need root
cp -a "$(ls -1t /etc/gitlab-runner/config.toml.bak.* | head -1)" /etc/gitlab-runner/config.toml && chown gitlab-runner:gitlab-runner /etc/gitlab-runner/config.toml && systemctl restart gitlab-runner
cp -a "$(ls -1t /etc/docker/daemon.json.bak.* | head -1)" /etc/docker/daemon.json && systemctl restart docker
cd /opt/<stack> && docker compose down
runner/install/users.sh --unlock-root    # reopen root SSH and port 22 (run from the repo copy)
```

`docker compose down -v` also deletes the stack's data volumes, and that can't be undone.

## Decommission

1. In GitLab, delete the runner and any deploy tokens.
2. In Hetzner, delete the server **and** its Primary IPv4, which is billed separately even when unattached. Delete leftover snapshots too.
3. Remove DNS records that point at the server's IP.
