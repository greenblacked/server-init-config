# server-init-config

Bootstrap and operations config for a self-hosted GitLab Runner on Hetzner Cloud.
It's built for an ARM64 CAX11 running Rocky Linux 10. Debian 13 and x86_64 work too.

What a server built from this repo has:

- Docker Engine and GitLab Runner (docker executor), with job pickup tuned via `request_concurrency`
- A Docker Hub pull-through cache on `127.0.0.1:5000`, registered as a Docker mirror
- Optionally, a Verdaccio npm cache and a shared `/srv/ci-cache` for npm and Sonar
- Optionally, a daily prewarm of the CI images from GitLab Container Registry
- Weekly cleanup, plus an emergency disk guard at 85%
- Optionally, Prometheus, node_exporter and Grafana, all bound to `127.0.0.1`, plus Grafana on an HTTPS domain via Caddy
- A `health` command: one report covering the system, security, services, runner, containers, caches and 24h trends
- SSH hardening, automatic security updates, SELinux enforcing (on Rocky)

## Layout

| Path | Purpose |
|---|---|
| `cloud-init/rocky.yaml`, `cloud-init/debian.yaml` | user-data for new servers (generated, do not edit) |
| `cloud-init/templates/` | sources for the cloud-init files |
| `tools/render-cloud-init.py` | renders templates and embeds repo files; `--check` detects stale output |
| `scripts/` | host scripts: `health`, weekly cleanup, disk guard, image prewarm |
| `systemd/` | services and timers for the scripts |
| `install/` | idempotent installers for optional components, run on the server from a clone |
| `monitoring/`, `registry-cache/`, `npm-cache/` | Docker Compose stacks and their configs |
| `ci/` | `.gitlab-ci.yml` snippets: smoke test, defaults, arm64 check, multi-arch mirroring |

## Build a new server

1. **Hetzner Console**: create the server (CAX11, `nbg1`, Rocky Linux 10 or Debian 13), add your SSH key, and paste `cloud-init/rocky.yaml` or `cloud-init/debian.yaml` as Cloud config.
2. **Firewall**: inbound TCP 22 from your IP only, ICMP optional, outbound left empty (empty means allow all). Open 80/443 only if you publish Grafana.
3. **Wait for cloud-init**, then copy the repo to the server. The repo is private, so either use `scp -r` from your laptop or a read-only deploy key:

   ```bash
   cloud-init status --wait
   scp -r server-init-config root@SERVER_IP:/root/
   ```

4. **Install the host tools and register the runner.** Create the runner in GitLab first (Settings → CI/CD → Runners → New runner) and copy its `glrt-` token:

   ```bash
   cd /root/server-init-config
   install/host-tools.sh
   DESCRIPTION=hetzner-cax11 install/register-runner.sh
   ```

5. **Optional components**, in this order:

   ```bash
   install/monitoring.sh
   install/npm-cache.sh
   install/shared-cache.sh
   install/image-prewarm.sh
   DOMAIN=grafana.example.com ACME_EMAIL=you@example.com install/grafana-domain.sh
   ```

   Run `install/selinux-enforcing.sh` only on servers that weren't built from the Rocky cloud-init, which already enables it.

6. **Validate**:

   ```bash
   health
   ```

   Then run `ci/smoke.yml` in a project. Its log must show `on <your runner description>` and `aarch64`.

## The `health` command

```bash
health        # full report (~10-40 s)
health -q     # skip runner verify, network and pending-update checks
health -c     # only container health
watch -n 5 'health -c --no-color'
```

Exit codes: `0` OK, `1` warnings, `2` failures. The thresholds are variables at the top of `scripts/health`.

## Changing configs

Edit the source files, then regenerate the cloud-init files before committing:

```bash
tools/render-cloud-init.py
tools/render-cloud-init.py --check
shellcheck scripts/* install/*.sh
```

The cloud-init output stays under Hetzner's 32 KiB user-data limit. That's why `health` isn't embedded in it and is installed with `install/host-tools.sh` instead.

## Security notes

- No tokens or passwords are stored in this repo. Runner tokens, deploy tokens and the Grafana password are entered or generated on the server.
- `/etc/gitlab-runner/config.toml` and `/root/.docker/config.json` contain credentials and are kept at mode `600`.
- Job containers are not privileged. Enable `privileged = true` only for trusted projects that need Docker-in-Docker.
- `/srv/ci-cache` and the npm cache are shared by every project on the runner. Don't attach untrusted projects or forks.
- All monitoring and cache ports listen on `127.0.0.1` or the `docker0` bridge. Reach Grafana and Prometheus through an SSH tunnel: `ssh -N -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 root@SERVER_IP`.

## Rollback

Every installer backs up what it changes as `*.bak.<timestamp>`:

```bash
cp -a "$(ls -1t /etc/gitlab-runner/config.toml.bak.* | head -1)" /etc/gitlab-runner/config.toml && systemctl restart gitlab-runner
cp -a "$(ls -1t /etc/docker/daemon.json.bak.* | head -1)" /etc/docker/daemon.json && systemctl restart docker
cd /opt/<stack> && docker compose down
```

`docker compose down -v` also deletes the stack's data volumes, and that can't be undone.

## Decommission

1. In GitLab, delete the runner and any deploy tokens.
2. In Hetzner, delete the server **and** its Primary IPv4, which is billed separately even when unattached. Delete leftover snapshots too.
3. Remove DNS records that point at the server's IP.
