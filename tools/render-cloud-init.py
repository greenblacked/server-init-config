#!/usr/bin/env python3
"""Render cloud-init/*.yaml from cloud-init/templates/*.yaml.in.

Directives (each on its own line):
  @@INCLUDE path@@  insert another template verbatim
  @@FILE path@@     insert a repo file as a YAML block scalar, indented to 6 spaces
  @@BUNDLE name@@   insert "content: |" with the repo subset in BUNDLE_PATHS as a reproducible
                    tar.gz in base64 (for write_files entries with encoding: gz+b64)

Usage: tools/render-cloud-init.py [--check]
  --check  fail if the committed cloud-init files are out of date (for CI / pre-commit)
"""

from __future__ import annotations

import argparse
import base64
import gzip
import io
import logging
import re
import sys
import tarfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
TEMPLATES = ROOT / "cloud-init" / "templates"
TARGETS = {
    "rocky.yaml.in": "cloud-init/rocky.yaml",
    "debian.yaml.in": "cloud-init/debian.yaml",
    "runner-bundle.yaml.in": "gitlab-runner/cloud-init-rocky.yaml",
}
BUNDLE_PATHS = [
    "install/lib.sh",
    "install/host-tools.sh",
    "install/registry-cache.sh",
    "install/monitoring.sh",
    "install/register-runner.sh",
    "scripts/health",
    "scripts/runner-weekly-cleanup.sh",
    "scripts/runner-disk-guard.sh",
    "systemd/runner-weekly-cleanup.service",
    "systemd/runner-weekly-cleanup.timer",
    "systemd/runner-disk-guard.service",
    "systemd/runner-disk-guard.timer",
    "monitoring/docker-compose.yml",
    "monitoring/env.example",
    "monitoring/prometheus",
    "monitoring/grafana",
    "registry-cache",
    "gitlab-runner/setup.sh",
    "gitlab-runner/register.sh",
]
HETZNER_USER_DATA_LIMIT = 32 * 1024
DIRECTIVE = re.compile(r"^@@(INCLUDE|FILE|BUNDLE) (\S+)@@$")
INDENT = " " * 6

log = logging.getLogger("render-cloud-init")


def _bundle_files() -> list[Path]:
    files: list[Path] = []
    for rel in BUNDLE_PATHS:
        src = ROOT / rel
        if src.is_file():
            files.append(src)
        elif src.is_dir():
            files.extend(p for p in sorted(src.rglob("*")) if p.is_file() and ".bak." not in p.name)
        else:
            raise FileNotFoundError(f"bundle path not found: {rel}")
    return sorted(files)


def bundle_b64() -> str:
    """Reproducible tar.gz of BUNDLE_PATHS: fixed owner, mtime and modes, so --check is stable on any checkout."""
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for src in _bundle_files():
            info = tarfile.TarInfo(src.relative_to(ROOT).as_posix())
            data = src.read_bytes()
            info.size = len(data)
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mode = 0o755 if src.suffix == ".sh" or src.name == "health" else 0o644
            tar.addfile(info, io.BytesIO(data))
    packed = gzip.compress(raw.getvalue(), compresslevel=9, mtime=0)
    return base64.b64encode(packed).decode("ascii")


def render(path: Path, depth: int = 0) -> str:
    if depth > 5:
        raise RuntimeError(f"include depth exceeded at {path}")
    out: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        match = DIRECTIVE.match(line.strip())
        if not match:
            out.append(line)
            continue
        kind, rel = match.groups()
        if kind == "BUNDLE":
            encoded = bundle_b64()
            out.append(f"{INDENT[:-2]}content: |")
            out.extend(f"{INDENT}{encoded[i:i + 76]}" for i in range(0, len(encoded), 76))
            continue
        src = ROOT / rel
        if not src.is_file():
            raise FileNotFoundError(f"{path.name}: referenced file not found: {rel}")
        if kind == "INCLUDE":
            out.append(render(src, depth + 1).rstrip("\n"))
        else:
            for content_line in src.read_text(encoding="utf-8").rstrip("\n").splitlines():
                out.append(f"{INDENT}{content_line}" if content_line else "")
    return "\n".join(out) + "\n"


def validate(name: str, text: str) -> None:
    data = yaml.safe_load(text)
    if not isinstance(data, dict) or "write_files" not in data or "runcmd" not in data:
        raise ValueError(f"{name}: rendered YAML lacks write_files or runcmd")
    size = len(text.encode("utf-8"))
    if size > HETZNER_USER_DATA_LIMIT:
        raise ValueError(f"{name}: {size} bytes exceeds Hetzner user-data limit {HETZNER_USER_DATA_LIMIT}")
    log.info("%s: %d bytes, %d files, %d runcmd entries", name, size, len(data["write_files"]), len(data["runcmd"]))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail if committed output is stale")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    stale = False
    for template, target in TARGETS.items():
        text = render(TEMPLATES / template)
        validate(target, text)
        dest = ROOT / target
        if args.check:
            if not dest.is_file() or dest.read_text(encoding="utf-8") != text:
                log.error("%s is out of date, run tools/render-cloud-init.py", dest.relative_to(ROOT))
                stale = True
        else:
            dest.write_text(text, encoding="utf-8")
            log.info("wrote %s", dest.relative_to(ROOT))
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
