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
| Runner host | Rocky Linux 10 | [rocky-clean.yaml](runner/cloud-init/rocky-clean.yaml) (recommended) or [rocky.yaml](runner/cloud-init/rocky.yaml) for ARM64, [rocky-x86.yaml](runner/cloud-init/rocky-x86.yaml) for x86-64 | `runner/bootstrap.sh` |
| Runner host | Debian 13 | [debian.yaml](runner/cloud-init/debian.yaml) for ARM64, [debian-x86.yaml](runner/cloud-init/debian-x86.yaml) for x86-64 | `runner/bootstrap.sh` |

See the [plain-server guide](server/README.md) for OS differences and [Hetzner Apps behavior](server/README.md#hetzner-apps-images). The [runner guide](runner/README.md#which-init-file) explains what each image configures on first boot, including SELinux on Rocky.

## Provision a host

Create the VM with your SSH public key. Restrict inbound TCP 22 in the Hetzner Cloud Firewall to your management IP or network. Add application ports only where the workload requires them.

Run these commands from your workstation. Replace `SERVER_IP` with the new server's address and verify its SSH host-key fingerprint through the provider console before accepting it.

```bash
git clone https://github.com/greenblacked/server-init-config.git
cd server-init-config
ssh root@SERVER_IP true
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

Verify the runner is online in GitLab and run the [smoke job](runner/ci/smoke.yml) from a trusted project. Match its tags to the registered runner, including the x86 tag when appropriate, and confirm the job log reports the expected runner and architecture. See the [runner setup guide](runner/README.md#build-one) for the full sequence.

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
| Apply changes | Review the [update procedure](server/README.md#update) and the existing `/etc/server-init.conf` before rerunning bootstrap. | Follow the [runner update procedure](runner/README.md#update). Preview with `runner/update.sh --dry-run` from the on-host copy at `/root/server-init-config`. Exit 3 means CI-affecting work was deferred because jobs were active. |
| Recover | Open the Hetzner console if SSH is unavailable. See [plain-server rollback](server/README.md#roll-back) for restoring settings or disabling maintenance timers. | `runner/update.sh --rollback` restores files backed up by the updater. Review the [runner update procedure](runner/README.md#update) for its scope. |
| Diagnose bootstrap failures | Read `/var/log/server-init-failed.log` and the [troubleshooting guide](server/README.md#troubleshooting). | Read `/var/log/ci-bootstrap-failed.log` and the [troubleshooting guide](runner/README.md#troubleshooting). |

When using the streamed copy, update it from your workstation. `runner/update.sh --pull` requires a Git clone on the host. Before changing a production machine, record the deployed commit and make sure backups cover the persistent data and configuration you need to recover.

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
