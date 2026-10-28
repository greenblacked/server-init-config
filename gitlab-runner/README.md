# GitLab Runner on Rocky Linux: everything in one place

Paste one init into Hetzner, wait a few minutes, enter the runner token. Docker, GitLab Runner, the Docker Hub cache, Prometheus and Grafana, `health`, the weekly cleanup and the disk guard are installed for you. Rocky Linux 9/10, ARM64 or x86_64.

## Quick start

1. **Create the runner in GitLab** (Settings → CI/CD → Runners → New runner). Set tags and "run untagged jobs" there, then copy the `glrt-` token. It is shown once.
2. **Create the server** in Hetzner Console: Rocky Linux, your SSH key, and paste `gitlab-runner/cloud-init-rocky.yaml` as Cloud config. Firewall: inbound TCP 22 from your IP only, outbound left empty (allow all).
3. **Wait, then register the runner**:

   ```bash
   ssh root@SERVER_IP
   cloud-init status --wait
   /opt/server-init-config/gitlab-runner/setup.sh --register
   health
   ```

   First boot takes several minutes, because the monitoring images are pulled during cloud-init.
4. **Test** with `../ci/smoke.yml` in a project. The job log must show `on <your runner description>`.

## What the init does

- Hardens SSH (the drop-in is named `00-` so it wins over earlier ones), enables automatic security updates, sets the journal size limit and the timezone.
- Installs Docker Engine and GitLab Runner (docker executor), and restarts the runner after the `docker` group is added.
- Installs the tools `htop`, `ncdu`, `iotop` (from EPEL), `dig`, `lsof`, `sysstat`, `tcpdump`, `traceroute`, `nc`, `tmux`, `jq`, `git`, plus shell aliases and a tmux config.
- Unpacks the base set of this repo to `/opt/server-init-config` and runs `setup.sh --base`, which installs:
  - `health`, the weekly cleanup (Monday 03:30) and the disk guard (85%) with their timers,
  - the Docker Hub pull-through cache on `127.0.0.1:5000`, wired into Docker as a mirror,
  - Prometheus, node_exporter and Grafana, all bound to `127.0.0.1`, with the runner dashboard and alerts.
- Writes any failed step to `/var/log/ci-bootstrap-failed.log`. Output of `setup.sh` goes to `/var/log/server-init-setup.log`.

Not done by the init: registering the runner (the token must not be stored in user-data), SELinux enforcing, and the optional components below.

## setup.sh: install components later

```bash
/opt/server-init-config/gitlab-runner/setup.sh --list        # what is installed
/opt/server-init-config/gitlab-runner/setup.sh --register    # asks for the glrt- token
```

| Flag | Installs |
|---|---|
| `--base` | tools + registry-cache + monitoring (what cloud-init runs) |
| `--all` | `--base` + register + npm-cache + shared-cache |
| `--tools` | `health`, cleanup, disk guard and timers |
| `--register` | registers the runner |
| `--registry-cache` | Docker Hub pull-through cache |
| `--monitoring` | Prometheus, node_exporter, Grafana |
| `--npm-cache` | Verdaccio npm cache for jobs |
| `--shared-cache` | shared `/srv/ci-cache` for npm and Sonar |
| `--prewarm` | daily pre-pull of CI images (asks for a deploy token) |
| `--grafana-domain` | Grafana on HTTPS via Caddy (`DOMAIN` and `ACME_EMAIL` in the environment) |
| `--selinux` | SELinux enforcing, then checks Docker and the runner |

Components are installed in a fixed order whatever the order of the flags, and installed ones are skipped. The init is limited to 32 KiB, so the copy on the server holds only the base set. For `--npm-cache`, `--shared-cache`, `--prewarm`, `--grafana-domain`, `--selinux` and for updates, copy the full repo:

```bash
scp -r server-init-config root@SERVER_IP:/root/        # from your laptop
ssh root@SERVER_IP
/root/server-init-config/gitlab-runner/setup.sh --npm-cache --shared-cache
```

## Update

Updating always starts from a new copy of the repo, so copy it first:

```bash
scp -r server-init-config root@SERVER_IP:/root/
ssh root@SERVER_IP
/root/server-init-config/gitlab-runner/update.sh --dry-run   # preview
/root/server-init-config/gitlab-runner/update.sh             # apply
```

`update.sh` is `install/update.sh`: it syncs scripts, units and stack configs for what is installed, backs up every changed file, restores them if a check fails, and skips CI-affecting steps while jobs run. `--os` also upgrades OS packages, `--rollback` restores the last backup. See the main README for details.

## Check the first boot

```bash
cloud-init status --long                          # "done"
cat /var/log/ci-bootstrap-failed.log 2>/dev/null  # empty or missing = nothing failed
tail -30 /var/log/server-init-setup.log
health
sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication|x11forwarding) '
grep Groups /proc/$(systemctl show -p MainPID --value gitlab-runner)/status ; getent group docker
grep -E '^(upgrade_type|apply_updates)' /etc/dnf/automatic.conf
uname -r ; rpm -q kernel-core                     # different versions mean a reboot is pending
```

If `/etc/dnf/automatic.conf` is missing, the DNF version uses a different config path or timer name. Set up automatic updates by hand using the official docs.

## Everyday commands

```bash
# status
health            # full report; health -q quick; health -c containers only
htop              # F4 filter, F5 tree, F6 sort
ncdu -x /         # what fills the disk

# runner (aliases from the init work in new shells)
runner-logs       # journalctl -u gitlab-runner -f
runner-errors     # errors and warnings of the last 30 minutes
runner-jobs       # running job containers
runner-metrics    # runner metrics from 127.0.0.1:9252
gitlab-runner list ; gitlab-runner verify
systemctl status gitlab-runner --no-pager

# disk and containers
dfd               # df -h / and docker system df
dstats            # docker stats --no-stream
docker image prune -af --filter until=168h
```

### Grafana and Prometheus

Both listen on `127.0.0.1` only. Reach them through an SSH tunnel:

```bash
ssh -N -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 root@SERVER_IP
# Grafana    http://localhost:3000   user: admin
# Prometheus http://localhost:9090
grep GF_SECURITY_ADMIN_PASSWORD /opt/monitoring/.env     # on the server
```

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

Then delete the runner in GitLab if it still shows up, create a new one and run `setup.sh --register` again.

## Troubleshooting

- **`Request bottleneck: request_concurrency=1` in the log**: the runner asks GitLab for one job at a time, so pickup is slow. `grep request_concurrency /etc/gitlab-runner/config.toml`; registration sets it to 2. Add it under `[[runners]]` and restart if it is missing.
- **Jobs stay pending**: the job's `tags:` don't match the runner, untagged jobs are not allowed on it, or instance runners with another tag (for example `saas-linux-small-amd64`) pick them up. Compare the tags in the job log and in the runner settings, then fix `tags:` in `.gitlab-ci.yml` or disable instance runners for the project.
- **`permission denied … /var/run/docker.sock`**: the running runner process doesn't have the `docker` group. Check with the `Groups` command above, then `systemctl restart gitlab-runner`.
- **`Cannot connect to the Docker daemon`**: Docker is stopped. `systemctl status docker`, then `journalctl -u docker --since "-10min"`.
- **`toomanyrequests` when pulling an image**: Docker Hub rate limit. The cache from `--registry-cache` is the fix; check it with `curl -s 127.0.0.1:5000/v2/_catalog`.
- **Runner is offline in GitLab**: check `systemctl is-active gitlab-runner` and `gitlab-runner verify`. If both are fine, the Hetzner Firewall may be blocking outbound HTTPS.
- **A setup step failed**: read `/var/log/server-init-setup.log`, fix the cause and rerun `setup.sh` with the same flags. Finished components are skipped.
- **Disk full**: `dfd`, then the prune commands above. The weekly cleanup and the disk guard handle this automatically.

## Maintaining the init

`cloud-init-rocky.yaml` is generated, do not edit it. Change `cloud-init/templates/runner-bundle.yaml.in` or the files listed in `BUNDLE_PATHS` in `tools/render-cloud-init.py`, then:

```bash
tools/render-cloud-init.py          # regenerate
tools/render-cloud-init.py --check  # fails if the committed file is stale
```

The renderer fails when the result exceeds Hetzner's 32 KiB user-data limit. The init is about 31 KiB now, so a bigger `health` may need something moved out of `BUNDLE_PATHS`.

## Security notes

- The runner token is entered at the prompt and stored only in `/etc/gitlab-runner/config.toml` with mode `600`. It is never put in the init: user-data is readable by anything on the server, including CI job containers, through the metadata service.
- Job containers are not privileged. Enable `privileged = true` only for trusted projects that need Docker-in-Docker.
- Membership in the `docker` group is root-equivalent on the host. Don't attach untrusted projects or forks to this runner.
- Monitoring and the cache listen on `127.0.0.1` or the `docker0` bridge. SELinux is left as the image has it; `setup.sh --selinux` switches it to enforcing.

## Decommission

Delete the runner in GitLab, then delete the server **and** its Primary IPv4 in Hetzner. The IPv4 is billed separately even when unattached. Delete leftover snapshots too.
