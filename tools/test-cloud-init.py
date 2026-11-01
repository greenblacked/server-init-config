#!/usr/bin/env python3
"""Test the generated cloud-init files before pasting them into Hetzner.

Checks per file:
  - cloud-init schema (when the cloud-init CLI is installed)
  - YAML parses, size under Hetzner's 32 KiB user-data limit
  - every runcmd entry parses as shell (sh -n)
  - embedded files: JSON parses, TOML parses, shell files pass bash -n, sshd drop-ins pass sshd -t
  - lockout guard: no setting that can lock you out (root login off, AllowUsers/AllowGroups, Port, ListenAddress)
  - live SSH test (root, with sshd and ssh-keygen available): a throwaway sshd with the drop-in on a
    high port accepts root with a key and refuses a password

Usage: tools/test-cloud-init.py [FILE ...]   (default: every generated cloud-init file)
"""

from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import tomllib
import yaml

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_FILES = ["runner/cloud-init/rocky-clean.yaml", "runner/cloud-init/rocky.yaml", "runner/cloud-init/rocky-x86.yaml", "runner/cloud-init/debian.yaml",
                 "runner/cloud-init/debian-x86.yaml", "server/cloud-init/server-fedora.yaml", "server/cloud-init/server-el10.yaml",
                 "server/cloud-init/server-debian.yaml", "server/cloud-init/server-opensuse.yaml"]
SHELL_HISTORY = ROOT / "common" / "shell-history.sh"
SERVER_CLEANUP = ROOT / "server" / "server-cleanup.sh"
SERVER_SCRIPTS = ["server/server-init-el10.sh", "server/server-init-fedora.sh"]
CLEANUP_SCRIPTS = SERVER_SCRIPTS + ["server/server-init-opensuse.sh"]
SHELL_SCRIPTS = SERVER_SCRIPTS + ["server/server-init-debian.sh", "server/server-init-opensuse.sh"]
LIMIT = 32 * 1024
LOCKOUT = ("permitrootlogin no", "allowusers", "allowgroups", "port ", "listenaddress")

# Vendor repo keys are pinned by fingerprint. Docker signs deb and rpm repositories with different keys, so a URL
# must never be paired with the other family's fingerprint.
PINNED_KEYS = {
    "download.docker.com/linux/rhel/gpg": "060A61C51B558A7F742B77AAC52FEB6B621E9F35",
    "download.docker.com/linux/centos/gpg": "060A61C51B558A7F742B77AAC52FEB6B621E9F35",
    "download.docker.com/linux/fedora/gpg": "060A61C51B558A7F742B77AAC52FEB6B621E9F35",
    "download.docker.com/linux/debian/gpg": "9DC858229FC7DD38854AE2D88D81803C0EBFCD88",
    "download.docker.com/linux/ubuntu/gpg": "9DC858229FC7DD38854AE2D88D81803C0EBFCD88",
    "packages.gitlab.com/runner/gitlab-runner/gpgkey": "F6403F6544A38863DAA0B6E03F01618A51312F3F",
    "packages.gitlab.com/gpgkey/runner/49F16C5CC3A0F81F.pub.gpg": "931DA69CFA3AFEBBC97DAA8C6C57C29C6BA75A4E",
}
PIN_CALL = re.compile(r"pin[-_]repo[-_]key[\"',\s]+\"?(https://[^\s\"',]+)(?:/gpg\"?)?[\"',\s]+\"?([0-9A-Fa-f]{40})\b")

failures: list[str] = []


def check(ok: bool, name: str, detail: str = "") -> None:
    print(f"  {'PASS' if ok else 'FAIL'}  {name}{(': ' + detail) if detail and not ok else ''}")
    if not ok:
        failures.append(name)


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, check=False, **kw)


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def live_ssh_test(dropin: str, tag: str) -> None:
    if os.geteuid() != 0 or not all(shutil.which(b) for b in ("sshd", "ssh", "ssh-keygen")):
        print(f"  SKIP  {tag}: live SSH test needs root, sshd, ssh and ssh-keygen")
        return
    sshd = shutil.which("sshd")
    with tempfile.TemporaryDirectory() as t:
        d = Path(t)
        os.chmod(d, 0o700)
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(d / "hostkey")])
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(d / "userkey")])
        (d / "authorized_keys").write_text((d / "userkey.pub").read_text())
        os.chmod(d / "authorized_keys", 0o600)
        (d / "dropin.conf").write_text(dropin)
        port = free_port()
        (d / "sshd_config").write_text(
            f"Include {d}/dropin.conf\n"
            f"Port {port}\nListenAddress 127.0.0.1\nHostKey {d}/hostkey\n"
            f"AuthorizedKeysFile {d}/authorized_keys\nPidFile {d}/sshd.pid\nUsePAM no\nStrictModes no\n"
        )
        Path("/run/sshd").mkdir(exist_ok=True)
        r = run([sshd, "-t", "-f", str(d / "sshd_config")])
        check(r.returncode == 0, f"{tag}: sshd -t with the drop-in", r.stderr.strip())
        if r.returncode:
            return
        eff = run([sshd, "-T", "-f", str(d / "sshd_config"), "-C", "user=root,host=x,addr=127.0.0.1"]).stdout
        check("permitrootlogin without-password" in eff or "permitrootlogin prohibit-password" in eff,
              f"{tag}: effective PermitRootLogin keeps root by key")
        check("passwordauthentication no" in eff, f"{tag}: effective PasswordAuthentication no")
        proc = subprocess.Popen([sshd, "-D", "-f", str(d / "sshd_config"), "-E", str(d / "sshd.log")])
        try:
            time.sleep(1)
            base = ["ssh", "-p", str(port), "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                    "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR"]
            r = run([*base, "-i", str(d / "userkey"), "root@127.0.0.1", "echo ok"], timeout=20)
            check(r.returncode == 0 and r.stdout.strip() == "ok", f"{tag}: root logs in with the key", r.stderr.strip())
            r = run([*base, "-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password",
                     "root@127.0.0.1", "true"], timeout=20)
            check(r.returncode != 0, f"{tag}: password login refused")
        finally:
            proc.terminate()
            proc.wait(timeout=10)


def check_pinned_keys(label: str, text: str) -> None:
    """Every pin-repo-key call must pair a known URL with the fingerprint that URL serves."""
    for url, fp in re.findall(PIN_CALL, text):
        key = url.removeprefix("https://").replace("${DOCKER_DIST}", "rhel")   # centos serves the same rpm key
        want = PINNED_KEYS.get(key)
        check(want is not None and want == fp.upper(), f"{label}: key {key} pinned to its own fingerprint",
              f"got {fp}, expected {want}")


def test_file(rel: str) -> None:
    path = ROOT / rel
    print(f"== {rel}")
    raw = path.read_bytes()
    check(len(raw) <= LIMIT, "size under 32 KiB", f"{len(raw)} bytes")
    if shutil.which("cloud-init"):
        r = run(["cloud-init", "schema", "--config-file", str(path)])
        check(r.returncode == 0, "cloud-init schema", (r.stdout + r.stderr).strip()[-300:])
    else:
        print("  SKIP  cloud-init schema: cloud-init CLI not installed")
    data = yaml.safe_load(raw)
    check(raw.startswith(b"#cloud-config\n"), "starts with #cloud-config")

    for i, cmd in enumerate(data.get("runcmd", [])):
        script = cmd if isinstance(cmd, str) else (cmd[2] if cmd[:2] == ["sh", "-c"] else " ".join(map(str, cmd)))
        r = run(["sh", "-n", "-c", script])
        check(r.returncode == 0, f"runcmd[{i}] parses", r.stderr.strip())
        if "enabled=1" in script and "yum.repos.d" in script:
            # a repo is switched on only by the command that pins its keys, so a failed pin leaves it disabled
            check(re.search(r"pin-repo-key [^;|]*&& sed ", script) is not None, f"runcmd[{i}]: repo enabled only after pin-repo-key succeeded")

    for f in data.get("write_files", []):
        p, content = f["path"], f.get("content", "")
        if p.endswith(".json"):
            try:
                json.loads(content)
                check(True, f"{p} is valid JSON")
            except ValueError as e:
                check(False, f"{p} is valid JSON", str(e))
        elif p.endswith(".toml"):
            try:
                tomllib.loads(content)
                check(True, f"{p} is valid TOML")
            except tomllib.TOMLDecodeError as e:
                check(False, f"{p} is valid TOML", str(e))
        elif p.endswith(".sh") or content.startswith(("#!/usr/bin/env bash", "#!/bin/bash")):
            r = run(["bash", "-n"], input=content)
            check(r.returncode == 0, f"{p} passes bash -n", r.stderr.strip())
        if p == "/etc/profile.d/90-shell-history.sh":
            check(content == SHELL_HISTORY.read_text(), f"{p} equals common/shell-history.sh")
        if p == "/usr/local/sbin/server-init.sh":
            src = {"server/cloud-init/server-el10.yaml": "server-init-el10.sh", "server/cloud-init/server-fedora.yaml": "server-init-fedora.sh"}.get(rel)
            if src:
                check(content == (ROOT / "server" / src).read_text(), f"{p} equals server/{src}")
        if p.startswith("/etc/yum.repos.d/"):
            # write_files runs before the package: step; an enabled repo whose gpgkey file is not there yet makes every dnf call fail
            keys = re.findall(r"file://(\S+)", " ".join(line for line in content.splitlines() if line.startswith("gpgkey=")))
            written = {g["path"] for g in data.get("write_files", [])}
            check("enabled=0" in content or all(k in written for k in keys), f"{p}: disabled until its key files exist", ", ".join(keys))
        if p.startswith("/etc/ssh/sshd_config.d/"):
            lower = [line.strip().lower() for line in content.splitlines() if line.strip() and not line.lstrip().startswith("#")]
            bad = [line for line in lower if line.startswith(LOCKOUT)]
            check(not bad, f"{p}: nothing that can lock you out", ", ".join(bad))
            live_ssh_test(content, p)

    text = raw.decode()
    check_pinned_keys(rel, text)
    for word in ("--lock-root", "setenforce 1", "server-users"):
        if rel == "runner/cloud-init/rocky-clean.yaml":
            check(word not in text, f"clean init does not contain '{word}'")


def test_shell_history_copies() -> None:
    """server/*.sh must stay self-contained, so they embed common/shell-history.sh: the copies must match."""
    print("== shell history copies")
    want = SHELL_HISTORY.read_text()
    for rel in SHELL_SCRIPTS:
        text = (ROOT / rel).read_text()
        m = re.search(r"put /etc/profile\.d/90-server-shell\.sh 0644 <<'EOF'\n(.*?)\nEOF\n", text, re.S)
        check(bool(m) and m.group(1) + "\n" == want, f"{rel} embeds common/shell-history.sh unchanged")
    r = run(["bash", "-n", str(SHELL_HISTORY)])
    check(r.returncode == 0, "common/shell-history.sh passes bash -n", r.stderr.strip())


def test_server_cleanup_copies() -> None:
    """server/*.sh embed server/server-cleanup.sh (they must stay self-contained): the copies must match."""
    print("== server-cleanup copies")
    want = SERVER_CLEANUP.read_text()
    for rel in CLEANUP_SCRIPTS:
        text = (ROOT / rel).read_text()
        m = re.search(r"put /usr/local/sbin/server-cleanup 0755 <<'EOF'\n(.*?)\nEOF\n", text, re.S)
        check(bool(m) and m.group(1) + "\n" == want, f"{rel} embeds server/server-cleanup.sh unchanged")
    for name in ("server-cleanup", "server-update", "server-notify", "server-disk-guard", "srv", "install-tools"):
        r = run(["bash", "-n", str(ROOT / "server" / f"{name}.sh")])
        check(r.returncode == 0, f"server/{name}.sh passes bash -n", r.stderr.strip())
    if shutil.which("dash"):
        r = run(["dash", "-n", str(ROOT / "server" / "server-login.sh")])
        check(r.returncode == 0, "server/server-login.sh passes dash -n", r.stderr.strip())


def test_no_restic() -> None:
    """The owner removed restic: it must not be installed or documented anywhere in the tracked files."""
    r = run(["git", "grep", "-il", "restic", "--", ".", ":!tools/test-cloud-init.py"], cwd=ROOT)
    check(r.returncode == 1, "restic appears nowhere in the tracked files", r.stdout.strip())


def main() -> int:
    files = sys.argv[1:] or DEFAULT_FILES
    for rel in files:
        test_file(rel)
    if not sys.argv[1:]:
        test_shell_history_copies()
        test_server_cleanup_copies()
        test_no_restic()
    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s)")
        for name in failures:
            print(f"  - {name}")
        return 1
    print("ALL PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
