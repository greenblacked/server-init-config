# shellcheck shell=bash
# Unit tests for the secret hiding helpers in tools/ci/lib.sh. The fake secrets below are made up.
export CI_OUT="$UNIT_TMP/ci-out"
# shellcheck source=../../tools/ci/lib.sh
source "$REPO/tools/ci/lib.sh"

HIDDEN_PW='    [line hidden: it may hold a secret]'

test_redact_hides_credential_lines() {
  local l
  for l in 'Generated password: hunter2hunter2' 'ADMIN_PASSWORD=abc' 'token=ghp_fake123' 'API Token: x' 'client_secret: y' \
           'PrivateKey = AAAA' 'Private key: BBBB' 'PresharedKey=CCCC' 'preshared key: DDDD' 'PASSWORD=upper'; do
    assert_eq "$(printf '%s\n' "$l" | ci_redact)" "$HIDDEN_PW" "$l"
  done
}

test_redact_hides_device_key_urls() {
  local l
  for l in 'plugin: http://127.0.0.1:9118/on/js/abcDEF123' 'https://x.example/online/js/KEY1' 'src=/sisi/js/KEY2'; do
    assert_eq "$(printf '%s\n' "$l" | ci_redact)" '    [line hidden: it may hold a device key]' "$l"
  done
}

test_redact_passes_normal_lines() {
  local in=$'step: firewall\nok: fail2ban sshd jail\n  PASS  health --brief (0)\nURL http://127.0.0.1:9118/ready'
  assert_eq "$(printf '%s\n' "$in" | ci_redact)" "$in"
}

test_redact_keeps_safe_check_lines() {
  local l
  for l in '  FAIL  sshd: password login still on' '  FAIL  sshd: password login on' '  PASS  sshd: passwordauthentication no' \
           '  PASS  sshd: root by key only' '  FAIL  sshd: permitrootlogin is not prohibit-password (permitrootlogin yes)' \
           '  PASS  admin has passwordless sudo' '  FAIL  deploy has passwordless sudo' '  PASS  install printed the admin web password once' \
           '  FAIL  no admin password in the install output' '  FAIL  rerun replaced the password' '  PASS  public: wrong password is 401 (401)' \
           '  WARN  sshd: Password login still on' '::error::sshd: password login still on' '::warning::sshd: passwordauthentication no' \
           '  FAIL  sshd: password login is off' '::error::sshd: password login is off' '  PASS  sshd: password login is off'; do
    assert_eq "$(printf '%s\n' "$l" | ci_redact)" "$l" "$l"
  done
}

test_redact_hides_safe_phrase_lines_that_embed_a_secret() {
  local l b64='QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5'
  for l in '  FAIL  sshd: password login still on password=hunter2' '  FAIL  sshd: password login still on, token=abc' \
           '  FAIL  sshd: password login still on secret: abc' '  PASS  sshd: passwordauthentication no key=abc' \
           '  FAIL  rerun replaced the password: hunter2' '  FAIL  rerun replaced the password=hunter2' \
           '  FAIL  user: bob sshd: password login still on' '  FAIL  username=bob sshd: password login on' \
           '  FAIL  sshd: password login still on password: hunter2' '::error::sshd: password login still on password: hunter2' \
           '  FAIL  sshd: password login on /lite/events?token=abc' '  FAIL  sshd: password login on PrivateKey = abc' \
           '  FAIL  sshd: password login on PresharedKey: abc' '  FAIL  sshd: password login on -----BEGIN OPENSSH PRIVATE KEY-----' \
           "  FAIL  sshd: password login on $b64" "  FAIL  sshd: password login on http://h/on/js/abc" \
           '  FAIL  rerun replaced the password with XyZ12345abcdeFGHijkl' '  FAIL  sshd: password login still on pass: hunter2' \
           '  FAIL  sshd: password login still on passwd=hunter2' '  FAIL  sshd: password login still on pwd: hunter2' \
           '  FAIL  sshd: password login still on Authorization: Basic YWRtaW46aHVudGVyMg==' '  FAIL  sshd: password login on https://admin:hunter2@h/x' \
           '  FAIL  public: wrong password is 401 (got 200, want 401) -u admin:XyZ12345abcdeFGHijkl' \
           '::error::rerun replaced the password hunter2 changed' '  FAIL  sshd: password login on (Xy12abCDef34ghIJkl56mnOP)' \
           '  FAIL  rerun replaced the password (a1b2c3d4e5f6g7h8i9j0k1l2)' '  FAIL  sshd: password login still on (pass: hunter2)'; do
    out=$(printf '%s\n' "$l" | ci_redact)
    [[ "$out" == '    [line hidden: it may hold a '@(secret|device key)']' ]] || { echo "    not hidden: $l -> $out" >&2; return 1; }
  done
}

test_redact_ignores_forged_marker_character() {
  # a control character in the input must not let a secret slip past the rule (it is dropped before the line is looked at)
  assert_eq "$(printf '  FAIL  pass\001word=x\n' | ci_redact)" "$HIDDEN_PW"
  assert_eq "$(printf '  FAIL  sshd: pass\001word login on token=x\n' | ci_redact)" "$HIDDEN_PW"
}

test_redact_is_case_insensitive() {
  assert_eq "$(echo 'PaSsWoRd=x' | ci_redact)" "$HIDDEN_PW"
}

test_redact_hides_wireguard_block_and_qr() {
  local in out
  in=$'before\n[Interface]\nPrivateKey = FAKEKEY\nAddress = 10.8.0.2/32\n[Peer]\nPresharedKey = FAKEPSK\nPersistentKeepalive = 25\n█▀▀▀█ ▄▀█\n█ ███ █▄▀\n▀▀▀▀▀ ▀▀▀\nafter the qr'
  out=$(printf '%s\n' "$in" | ci_redact)
  assert_eq "$out" $'before\n    [WireGuard client config and QR code hidden]\nafter the qr'
  [[ "$out" != *FAKE* ]]
}

test_redact_file_rewrites_in_place() {
  printf 'ok line\npassword: p\n' > "$T/log"
  ci_redact_file "$T/log"
  assert_eq "$(cat "$T/log")" $'ok line\n'"$HIDDEN_PW"
  assert_eq "$(ls "$T" | wc -l)" 1 "no stray files"
}

test_mask_prints_add_mask_only_on_github() {
  assert_eq "$(GITHUB_ACTIONS=true ci_mask s3cr3t)" "::add-mask::s3cr3t"
  assert_eq "$(GITHUB_ACTIONS=true ci_mask '' )" "" "empty values are not masked"
  assert_eq "$(GITHUB_ACTIONS='' ci_mask s3cr3t)" "" "silent outside GitHub Actions"
  GITHUB_ACTIONS=true ci_mask a b > "$T/m"
  assert_eq "$(wc -l < "$T/m")" 2
}

test_run_redacts_log_and_console_and_keeps_exit_code() {
  local rc=0 out
  out=$(ci_run "$T/run.log" 10 sh -c 'echo visible; echo "password: topsecret"; exit 3') || rc=$?
  assert_eq "$rc" 3 "exit code of the command"
  assert_eq "$(cat "$T/run.log")" $'visible\n'"$HIDDEN_PW"
  assert_eq "$out" $'visible\n'"$HIDDEN_PW" "console shows the redacted view"
}

test_run_success_returns_zero_and_removes_raw_file() {
  mkdir "$T/tmp"
  TMPDIR="$T/tmp" ci_run "$T/run.log" 0 echo fine
  assert_eq "$(cat "$T/run.log")" fine
  assert_eq "$(ls -A "$T/tmp" | wc -l)" 0 "raw output removed"
}

test_run_keep_raw_leaves_raw_file() {
  mkdir "$T/tmp"
  TMPDIR="$T/tmp" CI_KEEP_RAW=1 ci_run "$T/run.log" 0 echo "token=zzz"
  assert_eq "$(cat "$CI_RAW")" "token=zzz"
  assert_eq "$(cat "$T/run.log")" "$HIDDEN_PW"
}

test_run_tail_limits_console_lines() {
  local out
  out=$(ci_run "$T/run.log" 2 sh -c 'echo a; echo b; echo c')
  assert_eq "$out" $'b\nc'
  assert_eq "$(wc -l < "$T/run.log")" 3
}
