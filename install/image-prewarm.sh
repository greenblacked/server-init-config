#!/usr/bin/env bash
# Daily pre-pull of all tags of the CI images in a GitLab Container Registry.
# Needs a project deploy token with read_registry scope.
set -Eeuo pipefail
# shellcheck source=install/lib.sh
source "$(dirname "$0")/lib.sh"

CRANE_VERSION="${CRANE_VERSION:-v0.20.2}"
CONF=/etc/ci-prewarm.conf
REPOS="${REPOS:-mirror/alpine mirror/node mirror/playwright mirror/snyk mirror/sonar-scanner-cli docker}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<USAGE
Usage: $0
Asks for the full path of one image (copy icon in Container Registry) and a deploy token.
Env: REPOS (space separated, relative to the project registry), CRANE_VERSION
USAGE
  exit 0
fi
require_root

case "$(uname -m)" in
  aarch64) arch=arm64 ;;
  x86_64)  arch=x86_64 ;;
  *) die "unsupported arch $(uname -m)" ;;
esac

if ! command -v crane >/dev/null; then
  log "installing crane ${CRANE_VERSION}"
  tmp=$(mktemp -d)
  base="https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}"
  tarball="go-containerregistry_Linux_${arch}.tar.gz"
  curl -fsSL -o "$tmp/$tarball" "$base/$tarball"
  curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt"
  (cd "$tmp" && grep " ${tarball}\$" checksums.txt | sha256sum -c -) || { rm -rf "$tmp"; die "crane checksum mismatch"; }
  tar -xzf "$tmp/$tarball" -C "$tmp" crane
  install -m 0755 "$tmp/crane" /usr/local/bin/crane
  rm -rf "$tmp"
  restorecon_if /usr/local/bin/crane
fi

first_repo="${REPOS%% *}"
read -rp "Paste the full path of ${first_repo} (copy icon in Container Registry): " ref
ref="${ref%%:*}"
[[ "$ref" == registry.gitlab.com/*/"${first_repo}" ]] || die "expected registry.gitlab.com/.../${first_repo}, got: $ref"
BASE="${ref%/"${first_repo}"}"
# /etc/ci-prewarm.conf is sourced as root: accept only plain registry path characters.
path_re='^[A-Za-z0-9._/-]+$'
[[ "$BASE" =~ $path_re ]] || die "registry path contains unexpected characters: $BASE"
read -ra repo_list <<<"$REPOS"
for r in "${repo_list[@]}"; do [[ "$r" =~ $path_re ]] || die "REPOS entry contains unexpected characters: $r"; done

read -rp "Deploy token username (gitlab+deploy-token-...): " dt_user
read -rsp "Deploy token: " dt_token; echo
[[ "$dt_user" == gitlab+deploy-token-* ]] || die "unexpected deploy token username"
printf '%s' "$dt_token" | docker login registry.gitlab.com -u "$dt_user" --password-stdin >/dev/null
unset dt_token
chmod 600 /root/.docker/config.json
crane ls "$BASE/$first_repo" >/dev/null || die "cannot list $BASE/$first_repo with this token"

{
  printf 'BASE=%q\n' "$BASE"
  printf 'REPOS=(%s)\n' "$(printf '%q ' "${repo_list[@]}")"
} > "$CONF"
chmod 644 "$CONF"

install -m 0755 "$REPO_ROOT/scripts/ci-image-prewarm.sh" /usr/local/bin/ci-image-prewarm.sh
restorecon_if /usr/local/bin/ci-image-prewarm.sh
for u in ci-image-prewarm.service ci-image-prewarm.timer; do
  install -m 0644 "$REPO_ROOT/systemd/$u" "/etc/systemd/system/$u"
  restorecon_if "/etc/systemd/system/$u"
done
systemctl daemon-reload
systemctl enable --now ci-image-prewarm.timer

log "first prewarm run (playwright images are large, this can take minutes)"
systemctl start ci-image-prewarm.service || true
journalctl -t ci-image-prewarm --since "-30min" --no-pager -o cat | grep -E 'OK|NO ARM|FAIL|summary' | sed -E 's/^[0-9T:-]+ //'
log "NO ARM lines: re-mirror those tags with crane copy (see ci/mirror-images.yml)"
