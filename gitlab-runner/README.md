# GitLab Runner on Rocky Linux

The init installs the base host: Docker, GitLab Runner and admin tools. Everything else is in the repo. You copy the repo to the server and install components one by one, in either of two ways:

- **A. Script**: `gitlab-runner/setup.sh --<component>`. It checks prerequisites, keeps the right order and skips what is already installed.
- **B. Copy-paste**: plain command blocks below, one per component, with a check at the end.

| File | Purpose |
|---|---|
| `cloud-init-rocky.yaml` | user-data for a new server: SSH hardening, Docker, GitLab Runner, security updates, admin tools, aliases, tmux config |
| `setup.sh` | installs components (variant A); `--list` shows what is installed |
| `register.sh` | registers the runner (asks for the `glrt-` token); wrapper over `install/register-runner.sh` |
| `update.sh` | updates installed components to the repo state; wrapper over `install/update.sh` |

## 1. Create the server

1. **GitLab**: Settings → CI/CD → Runners → New runner. Set tags and "run untagged jobs", then copy the `glrt-` token. It is shown once.
2. **Hetzner Console**: Rocky Linux, your SSH key, paste `gitlab-runner/cloud-init-rocky.yaml` as Cloud config. Firewall: inbound TCP 22 from your IP only, outbound left empty (allow all).
3. **Wait for cloud-init**:

   ```bash
   ssh root@SERVER_IP 'cloud-init status --wait; cat /var/log/ci-bootstrap-failed.log 2>/dev/null; systemctl is-active docker gitlab-runner'
   ```

   `done` and two `active` lines mean the base is ready. Lines in `ci-bootstrap-failed.log` name optional tools that are not in the repositories for this Rocky version, or a failed service.

What the init installs:

- SSH hardening (drop-in `00-` so it wins over earlier ones), automatic security updates, journal size limit, timezone.
- Docker Engine and GitLab Runner (docker executor); the runner is restarted after the `docker` group is added.
- Tools: `htop`, `btop`, `ncdu`, `iotop`, `mtr`, `nano`, `vim`, `rsync`, `wget`, `unzip`, `bash-completion`, `skopeo`, `restic`, `dnf-utils`, `dig`, `lsof`, `sysstat`, `tcpdump`, `traceroute`, `nc`, `tmux`, `jq`, `git`. Tools outside the base repositories come from EPEL. A missing one is logged and doesn't stop the boot.
- Aliases: `runner-logs`, `runner-errors`, `runner-jobs`, `runner-metrics`, `dfd`, `dstats`. tmux: mouse on, 50000 lines of history.

## 2. Copy the repo to the server

From your laptop, in the folder that contains `server-init-config`. Repeat this every time the repo changes:

```bash
scp -r server-init-config root@SERVER_IP:/root/
ssh root@SERVER_IP
cd /root/server-init-config
```

All commands below run on the server in `/root/server-init-config`. If a script says `Permission denied` (the copy lost its executable bits, for example from Windows), run `chmod +x gitlab-runner/*.sh install/*.sh scripts/*` once, or prefix the command with `bash`.

## 3. Install components

### A. Script

```bash
gitlab-runner/setup.sh --list                       # what is installed
gitlab-runner/setup.sh --all                        # tools, runner, Docker Hub cache, monitoring, logging, npm and shared cache
gitlab-runner/setup.sh --register --monitoring      # or pick components
DOMAIN=grafana.example.com ACME_EMAIL=you@example.com gitlab-runner/setup.sh --grafana-domain
```

| Flag | Installs |
|---|---|
| `--base` | tools + registry-cache + monitoring |
| `--all` | `--base` + register + logging + npm-cache + shared-cache |
| `--tools` | `health`, weekly cleanup, disk guard and their timers |
| `--register` | registers the runner (asks for the token) |
| `--registry-cache` | Docker Hub pull-through cache on `127.0.0.1:5000` |
| `--monitoring` | Prometheus, node_exporter, Grafana |
| `--logging` | Loki + Grafana Alloy: container logs and the journal in Grafana |
| `--npm-cache` | Verdaccio npm cache for jobs |
| `--shared-cache` | shared `/srv/ci-cache` for npm and Sonar |
| `--prewarm` | daily pre-pull of CI images (asks for a deploy token) |
| `--grafana-domain` | Grafana on HTTPS via Caddy (`DOMAIN`, `ACME_EMAIL`) |
| `--selinux` | SELinux enforcing, then checks Docker and the runner |

Components are installed in that order whatever the order of the flags. If one fails, fix the cause and rerun the same command. Finished components are skipped.

### B. Copy-paste

Run the blocks in this order and skip the ones you don't need. Each block ends with a check.

**Tools: `health`, cleanup, disk guard**

```bash
cd /root/server-init-config
install/host-tools.sh
systemctl list-timers 'runner-*' --no-pager
health -q
```

**Register the runner** (asks for the `glrt-` token)

```bash
cd /root/server-init-config
DESCRIPTION=hetzner-cax11 install/register-runner.sh
gitlab-runner verify
grep -nE 'request_concurrency|executor' /etc/gitlab-runner/config.toml
```

**Docker Hub cache** (restarts Docker, run it while no jobs are running)

```bash
cd /root/server-init-config
install/registry-cache.sh
docker info 2>/dev/null | grep -A1 'Registry Mirrors'
curl -s 127.0.0.1:5000/v2/_catalog
```

**Monitoring: Prometheus, node_exporter, Grafana**

```bash
cd /root/server-init-config
install/monitoring.sh
grep GF_SECURITY_ADMIN_PASSWORD /opt/monitoring/.env
curl -s 127.0.0.1:9090/api/v1/targets | jq -r '.data.activeTargets[] | "\(.labels.job) \(.health)"'
```

**Logging: Loki + Alloy** (after monitoring, so Grafana gets the Loki datasource)

```bash
cd /root/server-init-config
install/logging.sh
curl -s 127.0.0.1:3100/ready ; echo
curl -s 127.0.0.1:12345/-/ready ; echo
```

**npm cache (Verdaccio)** (needs a registered runner, run it while no jobs are running)

```bash
cd /root/server-init-config
install/npm-cache.sh
grep -n 'environment =' /etc/gitlab-runner/config.toml
```

**Shared cache `/srv/ci-cache`** (needs a registered runner, run it while no jobs are running)

```bash
cd /root/server-init-config
install/shared-cache.sh
grep -nE 'volumes =|environment =' /etc/gitlab-runner/config.toml
```

**Image prewarm** (asks for the image path and a deploy token with `read_registry`)

```bash
cd /root/server-init-config
install/image-prewarm.sh
systemctl list-timers ci-image-prewarm.timer --no-pager
```

**Grafana on a domain** (A record to the server IP first, ports 80/443 open in the Hetzner Firewall)

```bash
cd /root/server-init-config
DOMAIN=grafana.example.com ACME_EMAIL=you@example.com install/grafana-domain.sh
curl -sI https://grafana.example.com/api/health | head -1
```

Replace `grafana.example.com` and `you@example.com` with your domain and email.

**SELinux enforcing**

```bash
cd /root/server-init-config
install/selinux-enforcing.sh
getenforce
ausearch -m avc -ts recent | tail -5
```

**Everything at once** (same as `setup.sh --all`, asks for the token once)

```bash
cd /root/server-init-config
install/host-tools.sh && \
DESCRIPTION=hetzner-cax11 install/register-runner.sh && \
install/registry-cache.sh && \
install/monitoring.sh && \
install/logging.sh && \
install/npm-cache.sh && \
install/shared-cache.sh && \
health -q
```

## 4. Update

Copy the repo again (step 2), then:

```bash
cd /root/server-init-config
gitlab-runner/update.sh --dry-run   # preview, changes nothing
gitlab-runner/update.sh             # apply
gitlab-runner/update.sh --os        # also OS packages, Docker and GitLab Runner; never reboots
gitlab-runner/update.sh --rollback  # restore the files from the last backup
```

It syncs scripts, units and stack configs for what is installed. It backs up every changed file, restores them if a check fails, and skips CI-affecting steps while jobs are running (exit code `3`, rerun later).

## Everyday commands

```bash
health            # full report; health -q quick; health -c containers only
htop / btop       # processes
ncdu -x /         # what fills the disk
runner-logs       # journalctl -u gitlab-runner -f
runner-errors     # errors and warnings of the last 30 minutes
runner-jobs       # running job containers
runner-metrics    # runner metrics from 127.0.0.1:9252
dfd               # df -h / and docker system df
dstats            # docker stats --no-stream
gitlab-runner list ; gitlab-runner verify
docker image prune -af --filter until=168h
```

### Grafana, Prometheus and logs

All of them listen on `127.0.0.1` only. Reach them through an SSH tunnel from your laptop:

```bash
ssh -N -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 root@SERVER_IP
# Grafana    http://localhost:3000   user admin, password: grep GF_SECURITY_ADMIN_PASSWORD /opt/monitoring/.env
# Prometheus http://localhost:9090
```

Logs: Grafana → Explore → Loki. Useful queries:

```text
{unit="gitlab-runner.service"}                 runner service log
{unit="gitlab-runner.service"} |~ "(?i)error|warn"
{unit="docker.service"}                        Docker daemon
{unit="sshd.service"} |= "Failed"              failed SSH logins
{compose_project="registry-cache"}             Docker Hub cache
{compose_project="monitoring"}                 Prometheus, Grafana, node_exporter
{source="journal", level=~"err|crit|alert|emerg"}
```

Job containers are not collected. Their output is already the job log in GitLab. Logs are kept for 7 days (`retention_period` in `logging/loki.yaml`).

### Change the runner config

```bash
cp -a /etc/gitlab-runner/config.toml /etc/gitlab-runner/config.toml.bak.$(date +%Y%m%d-%H%M%S)
nano /etc/gitlab-runner/config.toml    # concurrent, request_concurrency, pull_policy, volumes
gitlab-runner verify
systemctl restart gitlab-runner        # do it while no jobs are running
```

`concurrent` is the number of jobs at once and `request_concurrency` is the number of parallel job requests to GitLab. Keep `concurrent` at or below the number of vCPUs. A CAX11 has 2.

### Remove or replace the runner

```bash
gitlab-runner unregister --all-runners   # removes it from GitLab and from config.toml
```

Then delete the runner in GitLab if it still shows up, create a new one and register again.

## Check the first boot

```bash
cloud-init status --long
cat /var/log/ci-bootstrap-failed.log 2>/dev/null
sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication|x11forwarding) '
grep Groups /proc/$(systemctl show -p MainPID --value gitlab-runner)/status ; getent group docker
grep -E '^(upgrade_type|apply_updates)' /etc/dnf/automatic.conf
uname -r ; rpm -q kernel-core                     # different versions mean a reboot is pending
```

If `/etc/dnf/automatic.conf` is missing, the DNF version uses a different config path or timer name. Set up automatic updates by hand using the official docs.

## Troubleshooting

- **`Request bottleneck: request_concurrency=1` in the log**: the runner asks GitLab for one job at a time, so pickup is slow. `grep request_concurrency /etc/gitlab-runner/config.toml`; registration sets it to 2. Add it under `[[runners]]` and restart if it is missing.
- **Jobs stay pending**: the job's `tags:` don't match the runner, untagged jobs are not allowed on it, or instance runners with another tag (for example `saas-linux-small-amd64`) pick them up. Compare the tags in the job log and in the runner settings, then fix `tags:` in `.gitlab-ci.yml` or disable instance runners for the project.
- **`permission denied … /var/run/docker.sock`**: the running runner process doesn't have the `docker` group. Check with the `Groups` command above, then `systemctl restart gitlab-runner`.
- **`Cannot connect to the Docker daemon`**: Docker is stopped. `systemctl status docker`, then `journalctl -u docker --since "-10min"`.
- **`toomanyrequests` when pulling an image**: Docker Hub rate limit. Install the Docker Hub cache and check it with `curl -s 127.0.0.1:5000/v2/_catalog`.
- **Runner is offline in GitLab**: check `systemctl is-active gitlab-runner` and `gitlab-runner verify`. If both are fine, the Hetzner Firewall may be blocking outbound HTTPS.
- **No logs in Grafana**: `health` shows whether Loki and Alloy are ready; `docker compose -f /opt/logging/docker-compose.yml logs --tail 50 alloy` shows why Alloy isn't sending.
- **A component install failed**: the installer prints the cause and stops. Fix it and rerun the same command; installers back up what they change as `*.bak.<timestamp>`.
- **Disk full**: `dfd`, then the prune commands above. The weekly cleanup and the disk guard handle this automatically.

## Security notes

- The runner token is entered at the prompt and stored only in `/etc/gitlab-runner/config.toml` with mode `600`. Don't put it in user-data: anything on the server, including job containers, can read user-data through the metadata service.
- Job containers are not privileged. Enable `privileged = true` only for trusted projects that need Docker-in-Docker.
- Membership in the `docker` group is root-equivalent on the host, and so is Alloy's access to the Docker socket. Don't attach untrusted projects or forks to this runner.
- Monitoring, logging and the caches listen on `127.0.0.1` or the `docker0` bridge.

## Decommission

Delete the runner in GitLab, then delete the server **and** its Primary IPv4 in Hetzner. The IPv4 is billed separately even when unattached. Delete leftover snapshots too.
