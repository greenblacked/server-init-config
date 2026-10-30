#!/usr/bin/env python3
"""Render runner/COMMANDS.md: self-contained copy-paste blocks, one per component.

Each block recreates the files it needs under /root/server-init-config with heredocs and runs the
installer, so it works on a server that has no copy of the repo. Interactive installers run on the
last line of their block, so the terminal (not the rest of the paste) answers their prompts.

Usage: tools/render-paste-commands.py [--check]
  --check  fail if the committed COMMANDS.md is out of date
"""

from __future__ import annotations

import argparse
import logging
import shlex
import sys
from dataclasses import dataclass, field
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "runner" / "COMMANDS.md"
INIT = ROOT / "runner" / "cloud-init" / "rocky-clean.yaml"
DEST = "/root/server-init-config"
DELIM = "__SIC_EOF__"

log = logging.getLogger("render-paste-commands")


@dataclass
class Block:
    anchor: str
    title: str
    note: str
    files: list[str]
    run: list[str] = field(default_factory=list)
    interactive: list[str] = field(default_factory=list)
    skip: frozenset[str] = frozenset()


# Never copied onto the runner host: the separate AI server installs it (its compose file is not embedded either).
EXCLUDE = {"server/install-ai.sh", "common/README.md"}


def expand(paths: list[str]) -> list[str]:
    out: list[str] = []
    for rel in paths:
        p = ROOT / rel
        if p.is_dir():
            out.extend(sorted(f.relative_to(ROOT).as_posix() for f in p.rglob("*") if f.is_file() and ".bak." not in f.name))
        elif p.is_file():
            out.append(rel)
        else:
            raise FileNotFoundError(rel)
    seen: set[str] = set(EXCLUDE)
    return [f for f in out if not (f in seen or seen.add(f))]


TOOLS = ["runner/install/host-tools.sh", "common/health", "runner/scripts/runner-weekly-cleanup.sh", "runner/scripts/runner-disk-guard.sh",
         "runner/systemd/runner-weekly-cleanup.service", "runner/systemd/runner-weekly-cleanup.timer",
         "runner/systemd/runner-disk-guard.service", "runner/systemd/runner-disk-guard.timer",
         "runner/scripts/runner-engine-update.sh", "runner/scripts/ci-job-isolation.sh", "runner/systemd/runner-engine-update.service",
         "runner/systemd/runner-engine-update.timer", "runner/systemd/ci-job-isolation.service", "common/sysctl-hardening.conf"]
REGISTRY = ["runner/install/registry-cache.sh", "runner/stacks/registry-cache"]
MONITORING = ["runner/install/monitoring.sh", "runner/stacks/monitoring/docker-compose.yml", "runner/stacks/monitoring/env.example",
              "runner/stacks/monitoring/prometheus", "runner/stacks/monitoring/grafana"]
LOGGING = ["runner/install/logging.sh", "runner/stacks/logging"]
NPM = ["runner/install/npm-cache.sh", "runner/stacks/npm-cache"]
PREWARM = ["runner/install/image-prewarm.sh", "runner/scripts/ci-image-prewarm.sh",
           "runner/systemd/ci-image-prewarm.service", "runner/systemd/ci-image-prewarm.timer"]
# Optional security tooling: has its own block, left out of the update and everything-at-once blocks to keep them small.
SECURITY = ["common/security-tools.sh", "common/kali", "common/security-audit-run.sh", "common/security/kali/Dockerfile",
            "common/systemd/security-audit.service", "common/systemd/security-audit.timer",
            "common/systemd/security-freshclam.service", "common/systemd/security-freshclam.timer"]
EVERYTHING = ["runner/install", "runner/scripts", "runner/systemd", "runner/stacks", "common"]

BLOCKS = [
    Block("users", "Users: admin, service accounts, SSH hardening",
          "Creates the admin user `ops` with sudo without password and the keys from "
          "root, the service accounts `gitlab-runner` (the runner service then runs as it) and `monitoring` (runs the "
          "monitoring and logging containers), and the SSH drop-in: keys only, only the `ssh-users` group. Root keeps SSH by key "
          "until the [Lock root SSH](#lock-root) block. Run it first; safe to rerun.",
          ["runner/install/users.sh"], run=["runner/install/users.sh"]),
    Block("packages", "Admin tools: htop, btop, ncdu, iotop and others",
          "htop, btop, ncdu, iotop, mtr, nano, vim, rsync, wget, unzip, bash-completion, skopeo, dig, lsof, "
          "sysstat (`sar`), tcpdump, traceroute, nc, jq, git, tmux, mc, fd, rg, fzf, plus the shell aliases, shell history with fzf Ctrl+R and tmux config. "
          "For a server created with an older init; safe to rerun.",
          ["common/admin-tools.sh", "common/shell-history.sh"], run=["common/admin-tools.sh"]),
    Block("tools", "Health, cleanup, job isolation, engine updates",
          "Installs `/usr/local/bin/health` and the cleanup: weekly run on Monday 03:30 (Docker images, build cache, "
          "runner caches, old builds, packages, journal, temp files) plus the disk guard, which runs an emergency "
          "cleanup every 30 minutes when the disk is 85% full. Also the job isolation (CI jobs cannot reach the cloud metadata "
          "address or services on the host) and the Sunday 04:30 upgrade of Docker CE and GitLab Runner, which runs only while no job runs. "
          "Also the kernel hardening (sysctl) and no core dumps. Ends with a dry run of the cleanup.",
          TOOLS, run=["runner/install/host-tools.sh"]),
    Block("firewall", "Host firewall and fail2ban",
          "firewalld on Rocky, ufw on Debian, with SSH (22 and the port sshd listens on) allowed and everything else closed, plus the fail2ban sshd jail "
          "(5 tries in 10 minutes, 1 hour ban). The firewall starts only after SSH is in the saved rules and stops again if SSH is not allowed. "
          "Open the same ports in the Hetzner Cloud Firewall. If Docker was already running on Rocky, docker0 is moved into the firewalld docker zone, so Docker needs no restart.",
          ["runner/install/host-firewall.sh"], run=["runner/install/host-firewall.sh"]),
    Block("security", "Security tools: audit, network, scan",
          "Optional. Tools to test and audit your own server; use them only on systems you own or are authorized to test. "
          "Default: lynis, OpenSCAP, auditd (small ruleset), ssh-audit, testssl.sh, nmap and other network tools, and trivy, gitleaks, "
          "hadolint, cosign, osv-scanner, trufflehog, dockle as release binaries at pinned versions, checked against the checksums file of the same release. Options for the installer "
          "(`sudo bash /root/server-init-config/common/security-tools.sh --help`; `/root` is not readable by `ops`): `--aide`, `--clamav`, `--rkhunter`, `--chkrootkit`, "
          "`--grype`, `--syft`, `--k8s`, `--kali`, `--audit-timer`.",
          SECURITY, run=["common/security-tools.sh"]),
    Block("register", "Register the runner",
          "Asks for the `glrt-` token (GitLab: Settings > CI/CD > Runners > New runner). Change `DESCRIPTION` if you like.",
          ["runner/install/register-runner.sh", "runner/install/job-limits.sh"], interactive=["sudo DESCRIPTION=hetzner-cax11 bash {d}/runner/install/register-runner.sh"]),
    Block("job-limits", "Per-job limits",
          "Adds memory 1536m (no swap), 1.5 CPUs and 256 MB /dev/shm per job, smaller limits for `services:` containers, and a `ci-jobs.slice` (4096 processes, 3 GB memory for all jobs together) to `[runners.docker]` in `config.toml` (a backup is made, values you set yourself are kept). "
          "Needs a registered runner. Change them with `JOB_MEMORY`, `JOB_CPUS`, `JOB_SHM_SIZE`, `JOBS_TASKS_MAX`, `JOBS_MEMORY_MAX` on the last line.",
          ["runner/install/job-limits.sh"], run=["runner/install/job-limits.sh"]),
    Block("registry-cache", "Docker Hub pull-through cache",
          "Cache on `127.0.0.1:5000`, set as the Docker mirror. Restarts Docker: run it while no jobs are running.",
          REGISTRY, run=["runner/install/registry-cache.sh"]),
    Block("monitoring", "Monitoring: Prometheus, node_exporter, Grafana",
          "All on `127.0.0.1`. Grafana password: `sudo grep GF_SECURITY_ADMIN_PASSWORD /opt/monitoring/.env`.",
          MONITORING, run=["runner/install/monitoring.sh"]),
    Block("logging", "Logging: Loki + Grafana Alloy",
          "Container logs (not CI jobs) and the journal, 7 days. Run after monitoring so Grafana gets the Loki datasource.",
          LOGGING, run=["runner/install/logging.sh"]),
    Block("npm-cache", "npm cache (Verdaccio)",
          "Needs a registered runner. Points `npm` and `yarn` in jobs at the cache. Run it while no jobs are running. Verdaccio binds to the docker0 IP: if it changes (`bip` in daemon.json), rerun this block or `runner/install/update.sh`.",
          NPM, run=["runner/install/npm-cache.sh"]),
    Block("shared-cache", "Shared cache /srv/ci-cache",
          "Needs a registered runner. Mounts `/srv/ci-cache` into every job for npm and Sonar. Trusted projects only.",
          ["runner/install/shared-cache.sh"], run=["runner/install/shared-cache.sh"]),
    Block("prewarm", "Image prewarm",
          "Asks for the path of one image (copy icon in Container Registry) and a deploy token with `read_registry`.",
          PREWARM, interactive=["sudo bash {d}/runner/install/image-prewarm.sh"]),
    Block("grafana-domain", "Grafana on a domain (HTTPS via Caddy)",
          "First: A record to the server IP, ports 80/443 open in the Hetzner Firewall. "
          "Replace `grafana.example.com` and `you@example.com` on the last line with your domain and email.",
          ["runner/install/grafana-domain.sh", "runner/stacks/monitoring/caddy/Caddyfile.tmpl"],
          interactive=["sudo DOMAIN=grafana.example.com ACME_EMAIL=you@example.com bash {d}/runner/install/grafana-domain.sh"]),
    Block("selinux", "SELinux enforcing",
          "Switches SELinux to enforcing now and after reboot, then restarts and checks Docker and the runner. Refuses to run while CI jobs are running.",
          ["runner/install/selinux-enforcing.sh"], run=["runner/install/selinux-enforcing.sh"]),
    Block("lock-root", "Lock root SSH",
          "Only after this works from your laptop: `ssh ops@SERVER_IP 'sudo -n true && echo ok'`. Sets "
          "`PermitRootLogin no`. Refuses to run while the admin has no SSH key. Undo, from a "
          "session that is still open: `sudo bash /root/server-init-config/runner/install/users.sh --unlock-root`.",
          ["runner/install/users.sh", "runner/install/lock-root.sh"], run=["runner/install/lock-root.sh"]),
    Block("update", "Update everything installed",
          "Writes the current repo files and runs `update.sh`: syncs what is installed, backs up and restores on failure. "
          "Add `--dry-run` to the last line to preview, `--os` to upgrade packages too.",
          EVERYTHING, interactive=["sudo bash {d}/runner/install/update.sh"], skip=frozenset(SECURITY)),
    Block("all", "Everything at once",
          "Users, admin tools, host tools, Docker Hub cache, monitoring and logging are installed first; the last line asks for the "
          "runner token and then sets up the npm and shared caches. Root SSH stays open: lock it with the Lock root SSH block "
          "after the admin login works.",
          EVERYTHING,
          run=["runner/install/users.sh", "common/admin-tools.sh", "runner/install/host-tools.sh", "runner/install/host-firewall.sh", "runner/install/registry-cache.sh", "runner/install/monitoring.sh", "runner/install/logging.sh"],
          interactive=[("sudo DESCRIPTION=hetzner-cax11 bash {d}/runner/install/register-runner.sh && "
                        "sudo bash {d}/runner/install/npm-cache.sh && sudo bash {d}/runner/install/shared-cache.sh && "
                        "sudo /usr/local/bin/health -q")],
          skip=frozenset(SECURITY)),
]


def file_heredoc(rel: str) -> list[str]:
    text = (ROOT / rel).read_text(encoding="utf-8")
    if any(line in (DELIM, "INSTALL") for line in text.splitlines()):
        raise ValueError(f"{rel} contains a heredoc delimiter line ({DELIM} or INSTALL)")
    mode = "755" if rel.endswith(".sh") or rel == "common/health" else "644"
    return [f'install -d "$R/{Path(rel).parent.as_posix()}"',
            f"cat > \"$R/{rel}\" <<'{DELIM}'", text.rstrip("\n"), DELIM, f'chmod {mode} "$R/{rel}"']


def render_block(b: Block) -> str:
    files = [f for f in expand(["common/lib.sh", *b.files]) if f not in b.skip]
    lines = ["sudo bash <<'INSTALL'", "set -Eeuo pipefail", f"R={DEST}", ""]
    for rel in files:
        lines += file_heredoc(rel) + [""]
    lines.append(f'echo "files written to $R: {len(files)}"')
    for script in b.run:
        lines.append(f'bash "$R/{script}" </dev/null')
    lines.append("INSTALL")
    lines += [cmd.format(d=DEST) for cmd in b.interactive]
    body = "\n".join(lines)
    if "````" in body:
        raise ValueError(f"block {b.anchor} contains a 4-backtick fence")
    return f'<a id="{b.anchor}"></a>\n## {b.title}\n\n{b.note}\n\n````bash\n{body}\n````\n'


def render_base() -> str:
    data = yaml.safe_load(INIT.read_text(encoding="utf-8"))
    lines = ["sudo bash <<'INSTALL'", "set -Eeuo pipefail", "dnf -y -q upgrade --refresh",
             "dnf -y -q install " + " ".join(data["packages"]), ""]
    for f in data["write_files"]:
        path, content = f["path"], f["content"].rstrip("\n")
        if any(line in (DELIM, "INSTALL") for line in content.splitlines()):
            raise ValueError(f"{path} contains a heredoc delimiter line")
        qpath = shlex.quote(path)
        if f.get("append"):
            for line in content.splitlines():
                q = shlex.quote(line)
                lines.append(f"grep -qxF -- {q} {qpath} 2>/dev/null || echo {q} >> {qpath}")
            lines.append("")
            continue
        lines += [f'install -d "$(dirname {qpath})"', f"cat > {qpath} <<'{DELIM}'", content, DELIM]
        if "permissions" in f:
            lines.append(f"chmod {f['permissions'][-3:]} {shlex.quote(path)}")
        lines.append("")
    for cmd in data["runcmd"]:
        line = cmd if isinstance(cmd, str) else shlex.join(str(c) for c in cmd)
        if "--lock-root" in line:
            continue  # pasted on a live server: lock root only after the admin login is tested
        lines.append(line)
    lines += ["", "systemctl is-active docker gitlab-runner", "INSTALL"]
    return ('<a id="base"></a>\n## Base host: Docker, GitLab Runner, tools\n\n'
            "The same steps as `rocky-clean.yaml`, for a Rocky server created without it. Skip this if you used the init. "
            "Paste it as root (that is how a server without the init is reached). It does not create the `ops` admin: "
            "paste the [Users](#users) block next. Root SSH stays open until the [Lock root SSH](#lock-root) block.\n\n"
            "````bash\n" + "\n".join(lines) + "\n````\n")


def render() -> str:
    toc = ["- [Base host](#base) (only if the server was created without the init)"]
    toc += [f"- [{b.title}](#{b.anchor})" for b in BLOCKS]
    head = f"""# Copy-paste commands

Generated by tools/render-paste-commands.py from the repo files. Do not edit by hand.

Each block is self-contained: paste it into an SSH session on the server as the admin user (`ops`); the
blocks use `sudo`. Before the users block has run, paste as root, which works too. A block writes the files it needs to
`{DEST}` and runs the installer, which checks its own result at the end. Use the blocks in the order below and skip
what you don't need. Long blocks paste best into a plain terminal or tmux; if a paste breaks off, just paste the
whole block again, the installers are safe to rerun or tell you the component is already installed.

{chr(10).join(toc)}

"""
    return head + render_base() + "\n" + "\n".join(render_block(b) for b in BLOCKS)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail if committed output is stale")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    text = render()
    if args.check:
        if not OUT.is_file() or OUT.read_text(encoding="utf-8") != text:
            log.error("%s is out of date, run tools/render-paste-commands.py", OUT.relative_to(ROOT))
            return 1
        log.info("%s is up to date", OUT.relative_to(ROOT))
        return 0
    OUT.write_text(text, encoding="utf-8")
    log.info("wrote %s: %d bytes, %d blocks", OUT.relative_to(ROOT), len(text.encode()), len(BLOCKS) + 1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
