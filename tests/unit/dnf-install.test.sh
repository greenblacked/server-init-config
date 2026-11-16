# shellcheck shell=bash
# dnf_install() in server/server-init-el10.sh: `dnf -y -q install`, up to 3 attempts, `dnf clean metadata` and a 5 s, then
# 10 s pause in between. dnf retries single downloads itself, but not a mirror that is mid-sync: its repomd.xml can list a
# file it does not serve yet ("Failed to download metadata for repo 'epel' ... all mirrors were already tried without
# success", server-matrix, centos stream10 arm64), which fails the whole packages step. Fresh metadata on the next attempt
# gets past it; a package that really does not exist still fails after the third attempt. The function carries no comment
# of its own because server/cloud-init/server-el10.yaml embeds the script and is close to Hetzner's 32 KiB user-data limit.
# The script runs the installer when sourced, so the real function text is cut out (from "dnf_install() {" to the
# closing "}") and evaluated alone, with dnf and sleep stubbed. Nothing touches the real system.

load_dnf_install() {
  local src
  src=$(awk '/^dnf_install\(\) \{/,/^}/' "$REPO/server/server-init-el10.sh")
  [[ -n "$src" ]] || { echo "dnf_install() not found in server/server-init-el10.sh" >&2; return 1; }
  eval "$src"
  # Stubs: dnf fails the install while $T/fails is above 0, and records every call; sleep only records.
  dnf() {
    echo "dnf $*" >> "$T/calls"
    if [[ "$*" == *" install "* ]]; then
      local n; n=$(cat "$T/fails")
      if (( n > 0 )); then echo $((n - 1)) > "$T/fails"; return 7; fi
    fi
    return 0
  }
  sleep() { echo "sleep $*" >> "$T/calls"; }
  : > "$T/calls"
}

test_dnf_install_first_try_runs_once() {
  load_dnf_install
  echo 0 > "$T/fails"
  dnf_install sudo curl
  assert_eq "$(cat "$T/calls")" "dnf -y -q install sudo curl"
}

test_dnf_install_retries_with_fresh_metadata() {
  load_dnf_install
  echo 2 > "$T/fails"
  dnf_install epel-release
  assert_eq "$(cat "$T/calls")" "dnf -y -q install epel-release
dnf -q clean metadata
sleep 5
dnf -y -q install epel-release
dnf -q clean metadata
sleep 10
dnf -y -q install epel-release"
}

test_dnf_install_gives_up_after_three_attempts() {
  load_dnf_install
  echo 5 > "$T/fails"
  local rc=0
  dnf_install no-such-package || rc=$?
  assert_eq "$rc" 1 "exit status"
  assert_eq "$(grep -c ' install ' "$T/calls")" 3 "install attempts"
  assert_eq "$(grep -c '^sleep' "$T/calls")" 2 "no sleep after the last attempt"
}
