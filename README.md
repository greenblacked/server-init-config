# Server Init Config

Provision and maintain Hetzner Cloud hosts from a local Git checkout. Choose a hardened Linux server or a dedicated GitLab Runner host with Docker, monitoring, logging, and caches.

[Choose a host](#choose-a-host) · [Provision](#provision-a-host) · [Operate and recover](#operate-and-recover) · [Validate changes](#validate-changes)

## Choose a host

Cloud config goes in **Cloud config** when creating a Hetzner server. It is optional for plain servers. Runner hosts start with a runner cloud-init file.

| Host | Operating system | Cloud config | Bootstrap |
| --- | --- | --- | --- |
| Plain server | Fedora 44 | [server-fedora.yaml](server/cloud-init/server-fedora.yaml) | `server/bootstrap.sh` |
| Plain server | CentOS Stream 10, Rocky Linux 10, AlmaLinux 10 | [server-el10.yaml](server/cloud-init/server-el10.yaml) | `server/bootstrap.sh` |
| Plain server | Ubuntu 26.04, Debian 13, Hetzner Apps based on Ubuntu 24.04 | [server-debian.yaml](server/cloud-init/server-debian.yaml) | `server/bootstrap.sh` |
| Plain server | openSUSE Leap 16 | [server-opensuse.yaml](server/cloud-init/server-opensuse.yaml) | `server/bootstrap.sh` |
| Runner host | Rocky Linux 10 | [rocky-clean.yaml](runner/cloud-init/rocky-clean.yaml) (recommended for ARM64 and x86-64), [rocky.yaml](runner/cloud-init/rocky.yaml) for ARM64, [rocky-x86.yaml](runner/cloud-init/rocky-x86.yaml) for x86-64 | `runner/bootstrap.sh` |
| Runner host | Debian 13 | [debian.yaml](runner/cloud-init/debian.yaml) for ARM64, [debian-x86.yaml](runner/cloud-init/debian-x86.yaml) for x86-64 | `runner/bootstrap.sh` |

See the [plain-server guide](server/README.md) for OS differences and [Hetzner Apps behavior](server/README.md#hetzner-apps-images). The [runner guide](runner/README.md#which-init-file) explains what each image configures on first boot, including SELinux on Rocky.

## Provision a host

Create the VM with your SSH public key. Restrict inbound TCP 22 in the Hetzner Cloud Firewall to your management IP or network. Add application ports only where the workload requires them.

Clone the repository on your workstation. Use the same revision for the VM's cloud config and the bootstrap.

```bash
git clone https://github.com/greenblacked/server-init-config.git
cd server-init-config
```

Open an interactive root session in a separate terminal. Replace `SERVER_IP` with the new server's address. Before accepting the SSH host key, compare its fingerprint with the same key type shown in the VM's boot output through the [Hetzner console](https://docs.hetzner.com/cloud/servers/getting-started/vnc-console/). Keep the root session open while you run bootstrap from the local checkout.

```bash
ssh -o StrictHostKeyChecking=ask root@SERVER_IP
```

Use a clean checkout of the commit you intend to deploy. Bootstrap waits for cloud-init and streams files from Git `HEAD` over SSH to `/root/server-init-config`. The streamed copy has no `.git` directory and requires no Git credentials on the host. Run either script with `--dry-run` to see its plan.

### Plain server

```bash
server/bootstrap.sh SERVER_IP
```

The bootstrap selects the init script from `/etc/os-release`, configures the `ops` admin user, key-only SSH, firewall, fail2ban, security updates, and Docker, then runs the health report. Read the [plain-server setup guide](server/README.md#set-up-a-server) before setting extra ports or customizing an existing host.

### GitLab Runner host

Create the runner in GitLab, choose its tags, and keep the `glrt-` authentication token available for the registration prompt. Keep the token out of Cloud config and shell arguments.

```bash
runner/bootstrap.sh SERVER_IP
```

Verify the runner is online in GitLab. Add the job from [smoke.yml](runner/ci/smoke.yml) to a trusted project's `.gitlab-ci.yml` and set `tags` to match the intended runner. Use a dedicated tag if other runners could pick up the job. Run the pipeline and check the job log for the expected runner and `uname -m` output (`aarch64` or `x86_64`). See the [runner setup guide](runner/README.md#build-one) for the full sequence.

### Confirm access and health

Keep the original SSH session open until you have tested `ops` in a second terminal and confirmed recovery console access. Review warnings in the health report before proceeding. `health -q` returns 0 for healthy, 1 for warnings, and 2 for failures.

```bash
ssh ops@SERVER_IP 'sudo -n true && health -q'
```

Root SSH by key remains available through provisioning. If you choose to close it, follow the [plain-server](server/README.md#close-root-ssh-optional) or [runner](runner/README.md#close-root-ssh) procedure after verifying access.

## Operate and recover

| Task | Plain server | Runner host |
| --- | --- | --- |
| Check health | `health -q`. Fedora and EL also have `srv status` and `srv timers`. | `health -q`, `freshness --check`, and `sudo config-drift --check`. |
| Apply changes | Review the [update procedure](server/README.md#update) and the existing `/etc/server-init.conf` before rerunning bootstrap. | Follow the [runner update procedure](runner/README.md#update). Use the preview command below. |
| Recover | Open the Hetzner console if SSH is unavailable. See [plain-server rollback](server/README.md#roll-back) for restoring settings or disabling maintenance timers. | Use the rollback command below to restore repo-managed files. For Grafana data, follow the [Grafana recovery procedure](runner/README.md#grafana-upgrade-and-rollback). |
When using the streamed copy, update it from your workstation. `runner/update.sh --pull` requires a Git clone on the host. Before changing a production machine, record the deployed commit and make sure backups cover the persistent data and configuration you need to recover. If root SSH is closed, pass `--user ops` when running bootstrap from your workstation.

On a runner host, use `sudo config-drift --diff` to show changed lines between the repository baseline and deployed managed files. This is read-only and does not check running containers or expand Compose environment variables. Diff output can contain sensitive configuration; keep it local. Exit codes are 0 for no differences, 1 for differences, and 2 for comparison errors.

On `h2ci`, `ops` can run `server-update` or `freshness --refresh` without `sudo`;
the commands start fixed, root-owned systemd services. `freshness --check` reads
the cached report without refreshing it. The 11:00 Europe/Kyiv cron runs the OS
update, refreshes freshness, then sends the daily Telegram report. It replaces
the morning `dnf-automatic.timer`; Docker and GitLab Runner remain on the guarded
Sunday updater. The daily workflow reports reboot requirements without rebooting.
Investigate failures in `h2ci-server-update.service`, `server-freshness.service`,
or `h2ci-daily-maintenance.service` in the system journal. When intentionally
changing managed stack files, update the reviewed root-owned freshness reference
under `/etc/server-freshness/reference/runner/stacks`; the unprivileged checkout
is not the scheduled service's drift baseline.

On a runner host, preview the update as `ops`.

```bash
sudo bash -c 'cd /root/server-init-config && runner/update.sh --dry-run'
```

To restore the latest backup of repo-managed files, use the runner rollback command.

```bash
sudo bash -c 'cd /root/server-init-config && runner/update.sh --rollback'
```

Exit code `3` means one or more steps were skipped. Check the updater summary before retrying. Causes include active CI jobs and an installed npm cache without a `docker0` IPv4 address.

### Troubleshooting

If bootstrap stops while waiting for cloud-init, run `cloud-init status --long` and inspect `/var/log/cloud-init-output.log` on the VM. Confirm first boot has finished before retrying, including any reboot scheduled by the cloud config.

| Host | Bootstrap log | Guide |
| --- | --- | --- |
| Plain server | `/var/log/server-init-failed.log` | [Troubleshoot a plain server](server/README.md#troubleshooting) |
| Runner host | `/var/log/ci-bootstrap-failed.log` | [Troubleshoot a runner host](runner/README.md#troubleshooting) |

### Runner trust boundary

Attach only trusted projects to the runner. Projects share caches. Runner job isolation applies to IPv4 Docker traffic, and Docker daemon access on the host is root-equivalent. The logging stack's Alloy collector also has direct Docker socket access. Treat its image and configuration as privileged infrastructure. Keep monitoring endpoints private where possible, and use the Cloud Firewall to control any service ports published by Docker. The [runner security notes](runner/README.md#security-notes) cover these settings in more detail.

## Validate changes

Edit the [cloud-init templates for servers](server/cloud-init/templates) or [runners](runner/cloud-init/templates) and regenerate their YAML when inputs change. Regenerate the copy-paste commands when their installer sources change.

```bash
python3 tools/render-cloud-init.py
python3 tools/render-paste-commands.py
tools/ci/lint.sh render
tools/ci/lint.sh unit
```

See the [CI reference](docs/ci.md) for lint tools, Linux/container checks, VM coverage, and local equivalents. Test provisioning on a disposable VM that matches the production OS and architecture before applying code changes to an in-use host.

## More guides

| Guide | What it covers |
| --- | --- |
| [Plain servers](server/README.md) | OS-specific setup, SSH, maintenance, recovery, and optional tooling |
| [Runner hosts](runner/README.md) | GitLab registration, job limits, caching, monitoring, updates, and decommissioning |
| [GitHub Actions runner](runner/docs/github-runner.md) | Optional ephemeral runners for trusted private repositories |
| [Copy-paste installer commands](runner/COMMANDS.md) | Generated commands for setups without a local checkout |
| [Shared files](common/README.md) | Common health, administration, and security tooling |
| [Local AI](server/README.md#local-ai-separate-server) | Optional Ollama and Open WebUI on a separate server |
| [TorrServer](other/torrserver/README.md) and [Lampa stack](other/lampa-stack/README.md) | Standalone stacks with their own installation guides |
