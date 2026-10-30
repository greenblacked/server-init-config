# General servers (not runners)

Base setup for a fresh Hetzner server: SSH keys only, admin user `ops` with sudo, firewalld with only SSH open,
fail2ban for SSH, daily automatic security updates (no auto-reboot), Docker Engine + Compose, swap when there is
none, sysctl tuning, journald limit, chrony and admin tools (including `mc`, `fd`, `rg`, `fzf`). Root keeps key login on port 22, so the setup cannot
lock you out. Every step is checked before it changes anything, so reruns are safe; a failed step is logged to
`/var/log/server-init-failed.log` and the next step still runs.

Shell: 100000-line history with timestamps, shared between sessions; `Ctrl+R` searches it with fzf and `Ctrl+T` finds files
(`/etc/profile.d/90-server-shell.sh`, interactive bash only; log in again to get it). The text is the same as
`scripts/shell-history.sh`; `tools/test-cloud-init.py` checks that they match.

| Script | OS |
|---|---|
| `server-init-fedora.sh` | Fedora 44 |
| `server-init-el10.sh` | CentOS Stream 10, Rocky Linux 10, AlmaLinux 10 |

Both run on x86_64 and ARM64. The script refuses to run on an OS it is not written for.

## Run it

From your laptop, in this repo (pick the script for the server's OS):

```bash
scp server/server-init-el10.sh root@SERVER_IP:/usr/local/sbin/server-init.sh
```

```bash
ssh root@SERVER_IP 'chmod 0755 /usr/local/sbin/server-init.sh && ADMIN_USER=ops EXTRA_PORTS="" /usr/local/sbin/server-init.sh'
```

Or paste it on the server as root, without a copy of the repo:

```bash
cat > /usr/local/sbin/server-init.sh <<'SERVERINIT'
# paste the content of server/server-init-el10.sh (or -fedora.sh) here
SERVERINIT
chmod 0755 /usr/local/sbin/server-init.sh && /usr/local/sbin/server-init.sh
```

Settings are saved to `/etc/server-init.conf` on the first run (`ADMIN_USER`, `EXTRA_PORTS` such as
`"80/tcp 443/tcp"`, `INSTALL_DOCKER`, `INSTALL_SWAP`, `TIMEZONE`). Edit the file and rerun
`/usr/local/sbin/server-init.sh` to change them.

## Cloud config (new servers)

| File | OS |
|---|---|
| `cloud-init/server-fedora.yaml` | Fedora 44 |
| `cloud-init/server-el10.yaml` | CentOS Stream 10, Rocky Linux 10, AlmaLinux 10 |

Paste the file for the server's OS into Hetzner Console, **Cloud config**, when you create the server. It is
user-data for cloud-init, not shell commands: never paste it into a terminal. If you need ports or other
settings, edit the `/etc/server-init.conf` block at the top of the file first. The file embeds the script, so it
is generated (`tools/render-cloud-init.py`) and must not be edited except for that block. After the first boot:

```bash
ssh root@SERVER_IP 'cloud-init status --wait'
```

Then run the commands under [Check](#check).

## Check

```bash
cat /var/log/server-init-failed.log 2>/dev/null || echo no-failures
```

```bash
systemctl is-active firewalld fail2ban chronyd docker; firewall-cmd --list-services; firewall-cmd --list-ports; fail2ban-client status sshd | tail -3; systemctl list-timers '*automatic*' --no-pager | head -3; swapon --show
```

From a second terminal, before you log out:

```bash
ssh ops@SERVER_IP 'sudo -n true && echo sudo-ok'
```

## Security tools

Tools to test and audit **your own** servers. Use them only against systems you own or are authorized to test. On Hetzner,
scanning or attacking third-party systems violates their terms: check Hetzner's current policy before you run anything
against a host that is not yours.

```bash
sudo install/security-tools.sh                  # default: --audit --network --scan
sudo install/security-tools.sh --audit --network --scan --kali
sudo install/security-tools.sh --aide --clamav  # opt-in tools; --help lists all and what they cost
```

| Group | Installs |
|---|---|
| `--audit` | lynis, OpenSCAP (EL/Fedora, evaluation only), auditd with a small ruleset, ssh-audit, testssl.sh |
| `--network` | nmap, tcpdump, tshark, iperf3, socat, ncat, whois, dig, lsof, mtr, traceroute, iftop, nethogs, bmon |
| `--scan` | trivy, gitleaks, hadolint, cosign, osv-scanner, trufflehog, dockle: pinned release binaries, SHA256 checked, a mismatch is refused |
| opt-in | `--aide`, `--clamav` (no clamd), `--rkhunter`, `--chkrootkit`, `--arp-scan`, `--grype`, `--syft`, `--k8s` (kubescape, kube-bench) |
| `--kali` | the `kali` command: Kali Linux in a Docker container, built on first use (2-3 GB); needs Docker |
| `--audit-timer` | weekly lynis, oscap, aide and rkhunter reports in `/var/log/security-audit` (idle priority) |

It supports CentOS Stream/Rocky/AlmaLinux 10, Fedora 44, Debian 13 and Ubuntu 26.04, skips what a release does not
package and never fails the run for a missing optional tool. A failed checksum is the exception: that tool is not
installed and the script exits non-zero. Versions are variables at the top of the script.

```bash
sudo lynis audit system                                # hardening report, index in /var/log/lynis-report.dat
sudo oscap xccdf eval --profile xccdf_org.ssgproject.content_profile_standard --report /tmp/oscap.html \
  /usr/share/xml/scap/ssg/content/ssg-rl10-ds.xml      # ssg-almalinux10-ds.xml, ssg-cs10-ds.xml, ssg-fedora-ds.xml; never --remediate
sudo rkhunter --check --sk                             # with --rkhunter
sudo aide --config /etc/security-tools/aide.conf --check   # with --aide
sudo clamscan -r -i /srv                               # with --clamav (needs ~1.2 GB RAM while it runs)
ssh-audit your-host                                    # SSH algorithms and known weaknesses
testssl your-site.example.com:443                      # TLS configuration
nmap -sV your-host                                     # open ports and versions
sudo tshark -i eth0 -c 100 -f 'port 53'                # capture; iftop and nethogs show live traffic
trivy image IMAGE                                      # image CVEs; trivy fs . for a project folder
gitleaks detect -s .                                   # secrets in a repo and its history
trufflehog git file://. --only-verified                # secrets, verified ones only
osv-scanner scan source -r .                           # dependency CVEs
hadolint Dockerfile                                    # Dockerfile lint
dockle IMAGE                                           # image best practices (CIS Docker)
cosign verify --key cosign.pub IMAGE                   # signature check (key or --certificate-identity options)
kubescape scan                                         # with --k8s, against a cluster you own
kube-bench run                                         # with --k8s, run on a node of your own cluster
kali                                                   # shell in the Kali container; then: nmap -sV your-host, nikto -h your-site
```

`kali` runs with `--rm`, on the Docker bridge network (`kali --host-net` for the host network) and without the Docker
socket; files in `/home/kali` live in the volume `kali-home`. `kali update` rebuilds the image, `kali remove` deletes
image and volume. auditd rules only cover the paths that exist when the script runs: rerun it after installing Docker or the runner.

## Health report

`health` gives a one-command status report: system, disk and memory, security, firewall and open ports, fail2ban,
automatic updates, pending reboot, SSH settings, services, Docker and containers, and (only when installed) lynis, rkhunter, AIDE, ClamAV and auditd status. Install it once from a checkout
of this repo on the server:

```bash
sudo server/install-health.sh
```

Then, as your admin user (`ops`), no `sudo` needed:

```bash
health -q
```

`-q` skips the slow checks; `health` without it runs everything. It re-runs itself through passwordless sudo
when you are not root; without sudo rights it still runs and skips only the root-only checks. On a plain server
the GitLab Runner checks are skipped; they run only when a runner is registered (or with `--profile runner`).
It is not embedded in the Cloud config files: it is about 30 KB and Hetzner's user-data limit is 32 KiB.

## Notes

- Ports published by Docker (`-p 8080:80`) bypass firewalld. Bind to `127.0.0.1:8080:80` unless the port should be public.
- fail2ban bans an IP for 1 hour after 5 failed SSH logins in 10 minutes. An SSH agent that offers many keys can
  trip it; use `IdentitiesOnly yes` for the server in `~/.ssh/config`. To unban from the Hetzner web console:
  `fail2ban-client set sshd unbanip YOUR_IP`.
- Security updates are installed daily, but the server never reboots by itself; kernel updates apply after your next reboot.
