#!/usr/bin/env bash
# Install the pinned lint tools: actionlint and hadolint as release binaries with a SHA-256 check, and the distro
# packages shellcheck, yamllint, python3-yaml. Needs sudo. Used by .github/workflows/lint.yml; safe to run locally on Debian/Ubuntu.
# The checksums are fixed here on purpose: a new version means a reviewed change of the version AND the hash.
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

ACTIONLINT_VERSION=1.7.12
ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8   # actionlint_1.7.12_linux_amd64.tar.gz
HADOLINT_VERSION=2.15.1
HADOLINT_SHA256=c7187db94eeeeca956519a6af171adc31453941a1e777961f6e680f697c8c507      # hadolint-linux-x86_64
BIN="${BIN_DIR:-/usr/local/bin}"

[[ "$(uname -m)" == x86_64 ]] || die "the pinned lint binaries are for x86_64"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

if ! need actionlint || [[ "$(actionlint --version 2>/dev/null | head -1)" != "$ACTIONLINT_VERSION" ]]; then
  curl -fsSL --retry 3 -o "$tmp/al.tgz" "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"
  echo "${ACTIONLINT_SHA256}  $tmp/al.tgz" | sha256sum -c -
  tar -xzf "$tmp/al.tgz" -C "$tmp" actionlint
  $SUDO install -m 0755 "$tmp/actionlint" "$BIN/actionlint"
fi
if ! need hadolint || ! hadolint --version | grep -q "v\?${HADOLINT_VERSION}"; then
  curl -fsSL --retry 3 -o "$tmp/hadolint" "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-linux-x86_64"
  echo "${HADOLINT_SHA256}  $tmp/hadolint" | sha256sum -c -
  $SUDO install -m 0755 "$tmp/hadolint" "$BIN/hadolint"
fi
if need apt-get; then
  $SUDO apt-get update -q
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -q shellcheck yamllint python3-yaml
fi
actionlint --version | head -1
hadolint --version
shellcheck --version | sed -n 2p
yamllint --version
