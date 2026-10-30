# common

Files used by both the runner hosts (`../runner/`) and the plain servers (`../server/`).

| File | Purpose |
|---|---|
| `health` | the health report, installed as `/usr/local/bin/health` by `runner/install/host-tools.sh` and `server/install-health.sh` |
| `shell-history.sh` | shell history and fzf settings, installed as `/etc/profile.d/90-shell-history.sh` (the server init scripts embed a copy; `tools/test-cloud-init.py` checks they match) |
| `lib.sh` | helpers sourced by the installers (`log`, `die`, `require_root`, repo root) |
| `admin-tools.sh` | admin packages, shell aliases and tmux config |
| `security-tools.sh`, `kali`, `security-audit-run.sh`, `security/kali/`, `systemd/` | optional security tools for auditing your own servers, see [`server/README.md`](../server/README.md#security-tools) |
