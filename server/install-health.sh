#!/usr/bin/env bash
# Install the `health` report on a general server. Run from a repo checkout: sudo server/install-health.sh
# Installs common/health to /usr/local/bin/health and a sudoers drop-in so `sudo health` finds it
# (RHEL-family sudo resets PATH to a secure_path without /usr/local/bin). Safe to rerun.
set -Eeuo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: sudo $0   installs common/health to /usr/local/bin/health and the sudo secure_path drop-in"
  exit 0
fi
[[ $EUID -eq 0 ]] || { echo "ERROR: run as root: sudo $0" >&2; exit 1; }

src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/common/health"
[[ -f "$src" ]] || { echo "ERROR: $src not found; run this from a checkout of the repo" >&2; exit 1; }
bash -n "$src" || { echo "ERROR: $src has a syntax error" >&2; exit 1; }

install -m 0755 "$src" /usr/local/bin/health
if command -v restorecon >/dev/null 2>&1; then restorecon /usr/local/bin/health || true; fi

drop=/etc/sudoers.d/50-secure-path
# Add the drop-in only when no sudoers file already puts /usr/local/bin in secure_path.
if command -v visudo >/dev/null 2>&1 \
   && ! grep -rhsE '^[[:space:]]*Defaults[[:space:]]+secure_path[[:space:]]*=.*/usr/local/bin' /etc/sudoers /etc/sudoers.d 2>/dev/null | grep -q . \
   && grep -rhsE '^[[:space:]]*Defaults[[:space:]]+secure_path' /etc/sudoers /etc/sudoers.d 2>/dev/null | grep -q .; then
  tmp=$(mktemp)
  printf 'Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"\n' > "$tmp"
  if visudo -cqf "$tmp"; then
    install -d -m 0750 /etc/sudoers.d
    install -m 0440 -o root -g root "$tmp" "$drop"
    echo "sudo secure_path now includes /usr/local/bin ($drop)"
  else
    echo "WARN: generated sudoers drop-in is invalid; secure_path left as it was" >&2
  fi
  rm -f "$tmp"
fi

echo "OK: installed /usr/local/bin/health. Run: health   (or: health -q)"
