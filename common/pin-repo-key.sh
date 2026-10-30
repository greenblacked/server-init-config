#!/usr/bin/env bash
# Download a package repository signing key and install it only if it has the expected fingerprint.
# Usage: pin-repo-key URL FINGERPRINT DEST
# The fingerprint is the 40 hex digits of the primary key (spaces allowed). The file is checked with gpg in an empty
# keyring; only the key with that fingerprint is written to DEST (anything else in the download is dropped).
# On a mismatch nothing is written and the exit code is 1, so the repository is never trusted with a swapped key.
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
