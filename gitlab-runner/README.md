# GitLab Runner on Rocky Linux

A minimal, standalone setup: Docker Engine and a GitLab Runner with the docker executor on Rocky Linux 9/10 (ARM64 or x86_64).
For caches, cleanup timers, monitoring and the `health` command use the full setup in `../cloud-init/rocky.yaml` and `../install/`.

| File | Purpose |
|---|---|
| `cloud-init-rocky.yaml` | user-data for a new server: SSH hardening, Docker, GitLab Runner, automatic security updates, admin tools, shell aliases, tmux config |
| `register.sh` | registers the runner with a `glrt-` token and applies the job pickup fix (`request_concurrency`) |

What the init installs besides Docker and the runner:

- **Tools**: `htop`, `ncdu`, `iotop` (from EPEL; a failure is logged to `/var/log/ci-bootstrap-failed.log` and doesn't stop the boot), plus `bind-utils` (`dig`), `lsof`, `sysstat`, `tcpdump`, `traceroute`, `nmap-ncat`, `tmux`, `jq`, `git`.
- **Aliases** (new login shells): `runner-logs`, `runner-errors`, `runner-jobs`, `runner-metrics`, `dfd` (disk and Docker usage), `dstats`.
- **tmux**: mouse on, 50000 lines of history. Start with `tmux new -s main`, detach with `Ctrl-b d`, return with `tmux attach -t main`.

The `health` command, the weekly cleanup and the disk guard are not in the init. `health` alone is 26 KB, and Hetzner's user-data limit is 32 KiB. They are installed from the repo in step 5.

## Install

1. **Create the runner in GitLab** (Settings → CI/CD → Runners → New runner). Set tags and "run untagged jobs" there, then copy the `glrt-` token. It is shown once.
2. **Create the server** in Hetzner Console: Rocky Linux, your SSH key, and paste `cloud-init-rocky.yaml` as Cloud config.
3. **Firewall**: inbound TCP 22 from your IP only. Leave outbound empty, which means allow all. The runner needs outbound HTTPS to GitLab and your registries.
4. **Wait for cloud-init, then register.** Copy the whole repo, because step 5 needs `scripts/` and `systemd/` (run the `scp` from your laptop):

   ```bash
   scp -r server-init-config root@SERVER_IP:/root/
   ssh root@SERVER_IP
   cloud-init status --wait
   /root/server-init-config/gitlab-runner/register.sh
   ```

   Self-managed GitLab: `GITLAB_URL=https://gitlab.example.com DESCRIPTION=my-runner /root/server-init-config/gitlab-runner/register.sh`.
5. **Install `health`, the weekly cleanup and the disk guard** (idempotent, safe to repeat):

   ```bash
   /root/server-init-config/install/host-tools.sh
   health -q
   ```

   `health` skips whatever isn't installed, such as caches and monitoring, so it works on this minimal setup.
6. **Test** with `../ci/smoke.yml` in a project. The job log must show `on <your runner description>`.

## Check the first boot

```bash
cloud-init status --long                        # should be "done"
cat /var/log/ci-bootstrap-failed.log 2>/dev/null  # empty or missing means docker and gitlab-runner were active
systemctl is-active docker gitlab-runner
sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication|x11forwarding) '
grep Groups /proc/$(systemctl show -p MainPID --value gitlab-runner)/status ; getent group docker
grep -E '^(upgrade_type|apply_updates)' /etc/dnf/automatic.conf
uname -r ; rpm -q kernel-core                   # different versions mean a reboot is pending
```

If `/etc/dnf/automatic.conf` is missing, the DNF version uses a different config path or timer name. Set up automatic updates by hand using the official docs.

## Everyday commands

```bash
# one-word status (after install/host-tools.sh) and live process view
health            # full report; health -q for the quick one; health -c for containers only
htop              # F4 filter, F5 tree, F6 sort; `ncdu -x /` shows what fills the disk

# status and logs
systemctl status gitlab-runner --no-pager
gitlab-runner --version
gitlab-runner list
gitlab-runner verify
journalctl -u gitlab-runner -f
journalctl -u gitlab-runner --since "-15min" --no-pager | grep -Ei 'error|warn|bottleneck'

# running jobs and load
docker ps --filter label=com.gitlab.gitlab-runner.managed=true --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
docker stats --no-stream
curl -s 127.0.0.1:9252/metrics | grep '^gitlab_runner_' | head -30

# disk
df -h / ; docker system df
docker image prune -af --filter until=168h
docker builder prune -af --filter until=168h
```

### Change the runner config

```bash
cp -a /etc/gitlab-runner/config.toml /etc/gitlab-runner/config.toml.bak.$(date +%Y%m%d-%H%M%S)
nano /etc/gitlab-runner/config.toml    # concurrent, request_concurrency, pull_policy, volumes
gitlab-runner verify
systemctl restart gitlab-runner        # do it while no jobs are running
```

`concurrent` is the number of jobs at once and `request_concurrency` is the number of parallel job requests to GitLab. Keep `concurrent` at or below the number of vCPUs. A CAX11 has 2.

### Upgrade

```bash
dnf check-update gitlab-runner docker-ce
dnf -y upgrade gitlab-runner docker-ce docker-ce-cli containerd.io    # when no jobs are running
systemctl is-active docker gitlab-runner
```

### Remove or replace the runner

```bash
gitlab-runner unregister --all-runners   # removes it from GitLab and from config.toml
```

Then delete the runner in GitLab if it still shows up, create a new one and run `register.sh` again.

## Troubleshooting

- **`Request bottleneck: request_concurrency=1` in the log**: the runner asks GitLab for one job at a time, so pickup is slow. Check `grep request_concurrency /etc/gitlab-runner/config.toml`; `register.sh` sets it to 2. Add it under `[[runners]]` and restart if it is missing.
- **Jobs stay pending**: the job's `tags:` don't match the runner, or untagged jobs are not allowed on it, or instance runners with a different tag (for example `saas-linux-small-amd64`) pick them up. Compare the tags in the job log and in the runner settings, then fix `tags:` in `.gitlab-ci.yml` or disable instance runners for the project.
- **`permission denied … /var/run/docker.sock`**: the running runner process doesn't have the `docker` group. Verify with the `Groups` check above, then `systemctl restart gitlab-runner`.
- **`Cannot connect to the Docker daemon`**: Docker is stopped. `systemctl status docker`, then `journalctl -u docker --since "-10min"`.
- **`toomanyrequests` when pulling an image**: Docker Hub rate limit. Use a pull-through cache: `../install/registry-cache.sh`.
- **Runner is offline in GitLab**: check `systemctl is-active gitlab-runner` and `gitlab-runner verify`. If both are fine, the Hetzner Firewall may be blocking outbound HTTPS.
- **Disk full**: `df -h /; docker system df`, then the prune commands above. The full setup has a weekly cleanup timer and a disk guard (`../install/host-tools.sh`).

## Security notes

- The runner token is entered at the prompt and stored only in `/etc/gitlab-runner/config.toml` with mode `600`. Don't paste it into chat or commit it.
- Job containers are not privileged. Enable `privileged = true` only for trusted projects that need Docker-in-Docker.
- Membership in the `docker` group is root-equivalent on the host. Don't attach untrusted projects or forks to this runner.
- SELinux is left as the image has it. To switch it to enforcing and check Docker and the runner, use `../install/selinux-enforcing.sh`.

## Decommission

Delete the runner in GitLab, then delete the server **and** its Primary IPv4 in Hetzner. The IPv4 is billed separately even when unattached. Delete leftover snapshots too.
