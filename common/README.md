# Shared files

Used by both the runner hosts ([../runner/](../runner/README.md)) and the plain servers ([../server/](../server/README.md)). Nothing here is run directly from a laptop; the bootstraps copy it to `/root/server-init-config/common` on the server, and the component installers use it from there.

| File | Purpose | Installed as |
|---|---|---|
| `health` | the health report (about 52 KB, so it is not in any Cloud config) | `/usr/local/bin/health`, by `runner/install/host-tools.sh` or `server/install-health.sh` |
| `shell-history.sh` | 100000-line shared history with timestamps, `Ctrl+R` and `Ctrl+T` with fzf | `/etc/profile.d/90-shell-history.sh` on runner hosts; the server init scripts embed a copy (`tools/test-cloud-init.py` checks that the copies match) |
| `lib.sh` | helpers sourced by the installers: `log`, `die`, `require_root`, the repo root, the sudo `secure_path` drop-in `/etc/sudoers.d/50-secure-path` | sourced, not installed |
| `admin-tools.sh` | admin packages (htop, btop, ncdu, iotop, mtr, tcpdump, skopeo, mc, fd, rg, fzf and others), the runner aliases `health`, `runner-logs`, `runner-errors`, `runner-jobs`, `runner-metrics`, `dfd`, `dstats`, tmux config | `/etc/profile.d/ci-runner.sh`, `~/.tmux.conf`; run by `runner/setup.sh --packages` |
| `security-tools.sh`, `kali`, `security-audit-run.sh`, `security/kali/`, `systemd/` | optional security tools for auditing your own hosts and the weekly audit timer | `/usr/local/bin`, `/etc/systemd/system`; see [../server/README.md](../server/README.md#security-tools) |

Run on the server as `ops` from any directory; the copy under `/root` is not readable for `ops`, so the command is wrapped in `sudo bash -c`:

```bash
sudo bash -c 'cd /root/server-init-config && common/admin-tools.sh'
```

That reinstalls the admin tools and rewrites the aliases; it is safe to rerun.

Security tools are for hosts you own or are authorized to test. Scanning or attacking third-party systems violates Hetzner's terms.

Shell scripts here are checked with `shellcheck -S warning` and `bash -n`; change `health` or `shell-history.sh` here and nowhere else.
