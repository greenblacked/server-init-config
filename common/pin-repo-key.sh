#!/usr/bin/env bash
# Usage: pin-repo-key URL FINGERPRINT DEST. Downloads a repository signing key, checks it with gpg in an empty keyring and writes only
# the key with that fingerprint (40 hex digits, spaces allowed) to DEST. On a mismatch nothing is written and the exit code is 1.
set -Eeuo pipefail
if [[ $# -ne 3 || "$1" == "-h" || "$1" == "--help" ]]; then
  echo "Usage: $0 URL FINGERPRINT DEST" >&2
  exit 2
fi
url="$1"
want=$(printf '%s' "$2" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
dest="$3"
[[ "$want" =~ ^[0-9A-F]{40}$ ]] || { echo "pin-repo-key: fingerprint must be 40 hex digits" >&2; exit 2; }
command -v gpg >/dev/null 2>&1 || { echo "pin-repo-key: gpg is not installed" >&2; exit 1; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chmod 0700 "$work"
curl -fsSL --max-time 60 "$url" -o "${work}/key"
export GNUPGHOME="${work}/gnupg"
install -d -m 0700 "$GNUPGHOME"
gpg --batch --quiet --import "${work}/key" 2>/dev/null
if ! gpg --batch --with-colons --list-keys 2>/dev/null \
     | awk -F: '$1 == "pub" { g = 1; next } $1 == "fpr" && g { print $10; g = 0 }' | grep -qx "$want"; then
  echo "pin-repo-key: ${url} has no key with fingerprint ${want}; not installed" >&2
  exit 1
fi
gpg --batch --export --armor "$want" > "${work}/out" 2>/dev/null
[[ -s "${work}/out" ]] || { echo "pin-repo-key: export failed" >&2; exit 1; }
install -D -m 0644 "${work}/out" "$dest"
echo "pin-repo-key: ${dest} installed (${want})"
