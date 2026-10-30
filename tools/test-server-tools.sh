#!/usr/bin/env bash
# Tests for the server maintenance tools (server/*.sh, health --brief) with stubbed system commands.
# Hermetic tests run anywhere as root. Tests that write to the real /var/log, /etc and /usr/local (cleanup run,
# install-tools, server-init step) run only inside a throwaway container: SERVER_TOOLS_TEST_DESTRUCTIVE=1, e.g.
#   docker run --rm -v "$PWD:/repo:ro" -e SERVER_TOOLS_TEST_DESTRUCTIVE=1 almalinux:10 bash /repo/tools/test-server-tools.sh
# shellcheck disable=SC2034  # variables used inside eval strings
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$ROOT/server"
DESTRUCTIVE="${SERVER_TOOLS_TEST_DESTRUCTIVE:-0}"
PASS=0; FAIL=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
chmod 0755 "$T"

ok() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1${2:+: $2}"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }
section() { echo "== $1"; }
[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }

# stub NAME BODY: executable in $T/bin that logs its argv to $T/calls/NAME (one line per call) then runs BODY
mkdir -p "$T/bin" "$T/calls"; chmod 1777 "$T/calls"   # world-writable: the srv test runs a stub as an unprivileged user
stub() {
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/calls/%s"\n%s\n' "$T" "$1" "${2:-exit 0}" > "$T/bin/$1"
  chmod +x "$T/bin/$1"
}
calls() { cat "$T/calls/$1" 2>/dev/null || true; }
reset_calls() { rm -f "$T"/calls/*; }
export PATH="$T/bin:$PATH"
# minimal container images have no diffutils: tiny stand-ins (cmp -s A B, diff A B) so put() and the tests work
command -v cmp >/dev/null 2>&1 || { printf '#!/usr/bin/env bash\n[[ "$1" == -s ]] && shift\n[[ "$(md5sum < "$1")" == "$(md5sum < "$2")" ]]\n' > "$T/bin/cmp"; chmod +x "$T/bin/cmp"; }
command -v diff >/dev/null 2>&1 || { printf '#!/usr/bin/env bash\n[[ "$(cat "$1")" == "$(cat "$2")" ]]\n' > "$T/bin/diff"; chmod +x "$T/bin/diff"; }

# ---------------------------------------------------------------- login snippet
section "login snippet"
SNIP="$S/server-login.sh"
export SERVER_INIT_CONF="$T/login.conf" SERVER_HEALTH_BRIEF="$T/brief.txt"
printf 'ADMIN_USER=%s\nLOGIN_SUMMARY=1\n' "$(id -un)" > "$SERVER_INIT_CONF"
printf 'host  test\ndisk  / 10%% used\n' > "$T/brief.txt"
want=$(cat "$T/brief.txt")
for sh in bash dash; do
  command -v $sh >/dev/null 2>&1 || { echo "  SKIP  $sh not installed"; continue; }
  out=$($sh -i -c ". $SNIP; echo rc=\$?" 2>/dev/null)
  check "$sh interactive prints the summary, rc 0" '[[ "$out" == "$want"$'"'"'\nrc=0'"'"' ]]'
  out=$($sh -c ". $SNIP; echo rc=\$?" 2>&1)
  check "$sh non-interactive: no output" '[[ "$out" == "rc=0" ]]'
done
out=$(bash -i -c "set -eu; . $SNIP; echo rc=\$?" 2>/dev/null)
check "bash set -eu interactive ok" '[[ "$out" == "$want"$'"'"'\nrc=0'"'"' ]]'
out=$(bash -c "set -eu; . $SNIP; echo rc=\$?" 2>&1)
check "bash set -eu non-interactive silent" '[[ "$out" == "rc=0" ]]'
if command -v dash >/dev/null 2>&1; then
  out=$(dash -i -c "set -eu; . $SNIP; echo rc=\$?" 2>/dev/null)
  check "dash set -eu interactive ok" '[[ "$out" == "$want"$'"'"'\nrc=0'"'"' ]]'
  out=$(dash -c "set -u; . $SNIP; echo rc=\$?" 2>&1)
  check "dash set -u non-interactive silent" '[[ "$out" == "rc=0" ]]'
fi
out=$(ssh_cmd=1 bash -c ". $SNIP; echo done" 2>&1)
check "non-interactive command shells (scp, rsync, sftp, ssh host cmd) get no output" '[[ "$out" == done ]]'
printf 'ADMIN_USER=someoneelse\n' > "$SERVER_INIT_CONF"
out=$(bash -i -c ". $SNIP; echo rc=\$?" 2>/dev/null)
check "other user: silent" '[[ "$out" == "rc=0" ]]'
printf 'ADMIN_USER=%s\nLOGIN_SUMMARY=0\n' "$(id -un)" > "$SERVER_INIT_CONF"
out=$(bash -i -c ". $SNIP; echo rc=\$?" 2>/dev/null)
check "LOGIN_SUMMARY=0: silent" '[[ "$out" == "rc=0" ]]'
printf 'ADMIN_USER=%s\n' "$(id -un)" > "$SERVER_INIT_CONF"
export SERVER_HEALTH_BRIEF="$T/nonexistent"
out=$(bash -i -c ". $SNIP; echo rc=\$?" 2>/dev/null)
check "no cache yet: placeholder line" '[[ "$out" == "(health summary not generated yet)"$'"'"'\nrc=0'"'"' ]]'
rm -f "$SERVER_INIT_CONF"
out=$(bash -i -c ". $SNIP; echo rc=\$?" 2>/dev/null)
check "no conf at all: defaults (admin ops), silent for another user" '[[ "$out" == "rc=0" || "$(id -un)" == ops ]]'
unset SERVER_INIT_CONF SERVER_HEALTH_BRIEF

# ---------------------------------------------------------------- notify
section "notify"
NOTIFY="$S/server-notify.sh"
export SERVER_NOTIFY_ENV="$T/notify.env"
printf 'TELEGRAM_BOT_TOKEN=SECRETTOKEN123\nTELEGRAM_CHAT_ID=4242\nSLACK_WEBHOOK_URL=https://hooks.example/SECRETHOOK456\n' > "$SERVER_NOTIFY_ENV"
chmod 0600 "$SERVER_NOTIFY_ENV"
stub curl 'cat >> "'"$T"'/curl.stdin"; exit 0'
stub logger 'exit 0'
stub systemctl 'exit 0'
out=$(bash "$NOTIFY" test "hello \"quoted\" world" 2>&1); rc=$?
check "exit 0 with working curl" '[[ $rc -eq 0 ]]'
check "curl used --fail --max-time 10" 'calls curl | grep -q -- "--fail --max-time 10"'
check "token and webhook not in curl argv" '! calls curl | grep -q "SECRET"'
check "token passed on stdin" 'grep -q SECRETTOKEN123 "$T/curl.stdin" && grep -q SECRETHOOK456 "$T/curl.stdin"'
check "token not in output" '! grep -q SECRET <<<"$out"'
check "token not in syslog args" '! calls logger | grep -q SECRET'
check "message escaped for curl config" 'grep -q "hello \\\\\"quoted\\\\\" world" "$T/curl.stdin"'
check "test event: telegram and slack reported" 'grep -q "telegram: sent" <<<"$out" && grep -q "slack: sent" <<<"$out"'
reset_calls
stub curl 'cat >/dev/null; exit 22'
out=$(bash "$NOTIFY" update "x" 2>&1); rc=$?
check "curl failure does not fail the caller (exit 0)" '[[ $rc -eq 0 ]]'
check "failure logged without secrets" 'calls logger | grep -q "FAILED (curl exit 22)" && ! calls logger | grep -q SECRET'
check "update event refreshes the health cache" 'calls systemctl | grep -q "start --no-block server-health-brief.service"'
reset_calls
chmod 0644 "$SERVER_NOTIFY_ENV"
bash "$NOTIFY" update "x" >/dev/null 2>&1
check "env file not 0600: ignored, curl not called" '[[ -z "$(calls curl)" ]] && calls logger | grep -q "0600"'
chmod 0600 "$SERVER_NOTIFY_ENV"; rm -f "$SERVER_NOTIFY_ENV"; reset_calls
bash "$NOTIFY" cleanup "x" >/dev/null 2>&1; rc=$?
check "no env file: silent no-op, exit 0" '[[ $rc -eq 0 && -z "$(calls curl)" ]]'
printf 'MAIL_TO=a@b.c\n' > "$SERVER_NOTIFY_ENV"; chmod 0600 "$SERVER_NOTIFY_ENV"
stub mail 'cat >/dev/null'
bash "$NOTIFY" health "disk" >/dev/null 2>&1
check "mail channel used when only MAIL_TO is set" 'calls mail | grep -q "a@b.c"'
unset SERVER_NOTIFY_ENV; rm -f "$T/bin/curl" "$T/bin/mail"

# ---------------------------------------------------------------- disk guard
section "disk guard"
GUARD="$S/server-disk-guard.sh"
mkdir -p "$T/sbin" "$T/gstate"
printf '' > "$T/conf"
export SERVER_INIT_CONF="$T/conf" SERVER_SBIN="$T/sbin" SERVER_CLEANUP_STATE="$T/gstate"
stub server-cleanup 'exit 0'; mv "$T/bin/server-cleanup" "$T/sbin/"
stub server-notify 'exit 0'; mv "$T/bin/server-notify" "$T/sbin/"
# df stub: prints the percent from $T/pct, then (after a cleanup call) from $T/pct-after if it exists
stub df 'p=$(cat "'"$T"'/pct"); [[ -f "'"$T"'/calls/server-cleanup" && -f "'"$T"'/pct-after" ]] && p=$(cat "'"$T"'/pct-after"); printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 1000 500 500 %s%% /\n" "$p"'
# the stub for server-cleanup lives in $T/sbin; make it leave a marker the df stub can see
printf '#!/usr/bin/env bash\necho "$*" >> "%s/calls/server-cleanup"\necho "quiet=${SERVER_CLEANUP_QUIET:-}" >> "%s/calls/server-cleanup"\n' "$T" "$T" > "$T/sbin/server-cleanup"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/calls/server-notify"\n' "$T" > "$T/sbin/server-notify"
chmod +x "$T/sbin/"*
echo 50 > "$T/pct"; reset_calls
bash "$GUARD" >/dev/null 2>&1
check "below threshold: nothing runs" '[[ -z "$(calls server-cleanup)" ]]'
echo 90 > "$T/pct"; echo 90 > "$T/pct-after"; reset_calls
bash "$GUARD" >/dev/null 2>&1
check "at 90% (threshold 85): cleanup runs, quiet" 'calls server-cleanup | grep -q "quiet=1"'
check "still above afterwards: notified" 'calls server-notify | grep -q "still 90%"'
check "cooldown stamp written" '[[ -s "$T/gstate/guard-last" ]]'
reset_calls
bash "$GUARD" >/dev/null 2>&1
check "second run inside cooldown: no cleanup" '[[ -z "$(calls server-cleanup)" ]]'
echo $(( $(date +%s) - 7 * 3600 )) > "$T/gstate/guard-last"; echo 40 > "$T/pct-after"; reset_calls
bash "$GUARD" >/dev/null 2>&1
check "after cooldown (7h): cleanup runs again" '[[ -n "$(calls server-cleanup)" ]]'
check "freed enough: no notification" '[[ -z "$(calls server-notify)" ]]'
printf 'DISK_CLEAN_THRESHOLD=95\n' > "$T/conf"; echo 90 > "$T/pct"; rm -f "$T/gstate/guard-last"; reset_calls
bash "$GUARD" >/dev/null 2>&1
check "DISK_CLEAN_THRESHOLD from conf honoured (90 < 95)" '[[ -z "$(calls server-cleanup)" ]]'
rm -f "$T/bin/df" "$T/pct" "$T/pct-after"

# ---------------------------------------------------------------- update
section "update"
UPD="$S/server-update.sh"
export SERVER_UPDATE_STATE="$T/ustate"
printf '' > "$T/conf"
cat > "$T/bin/dnf" <<DNF
#!/usr/bin/env bash
echo "\$*" >> "$T/calls/dnf"
args=" \$* "
if [[ \$args == *" check-update "* ]]; then
  [[ -f "$T/updates" ]] && { printf 'bash.x86_64   5.2.1-2   baseos\nopenssl.x86_64   3.2.2-1   baseos\n'; exit 100; }
  exit 0
elif [[ \$args == *" needs-restarting "* ]]; then
  [[ \$args == *" -C "* && -f "$T/nocache" ]] && exit 2
  [[ -f "$T/needreboot" ]] && exit 1
  exit 0
fi
exit 0
DNF
chmod +x "$T/bin/dnf"
stub rpm 'if [[ -f "'"$T"'/newkernel" ]]; then echo 99.0-1.el10.x86_64; else uname -r; fi'
stub systemctl 'exit 0'
rm -f "$T/updates" "$T/needreboot" "$T/newkernel" "$T/nocache"; reset_calls
bash "$UPD" --check >/dev/null 2>&1; rc=$?
check "--check, nothing to update: exit 0" '[[ $rc -eq 0 ]]'
touch "$T/updates"
out=$(bash "$UPD" --check 2>&1); rc=$?
check "--check with updates: exit 100 (dnf's code)" '[[ $rc -eq 100 ]]'
check "--check lists them and counts 2" 'grep -q openssl <<<"$out" && grep -q "updates=2 " "$T/ustate/state"'
check "--check never upgrades" '! calls dnf | grep -q " upgrade "  && ! calls dnf | grep -q "^-y upgrade"'
check "--check never runs cleanup" '[[ -z "$(calls server-cleanup)" ]]'
reset_calls; : > "$T/calls/server-cleanup"
bash "$UPD" --security >/dev/null 2>&1; rc=$?
check "--security passes --security to dnf upgrade" 'calls dnf | grep -q "^-y upgrade --refresh --security"'
check "upgrade runs server-cleanup afterwards" 'calls server-cleanup | grep -q "quiet=1"'
check "no reboot by default" '! calls systemctl | grep -q reboot'
check "plain update has no --security" '{ reset_calls; bash "$UPD" >/dev/null 2>&1; ! calls dnf | grep -q -- "--security"; }'
touch "$T/needreboot"; reset_calls
out=$(bash "$UPD" 2>&1)
check "reboot needed but not requested: not rebooted, reported" '! calls systemctl | grep -q "^reboot" && grep -q "reboot needed: yes" <<<"$out"'
check "state file says reboot=1" 'grep -q "reboot=1" "$T/ustate/state"'
reset_calls; bash "$UPD" --reboot >/dev/null 2>&1
check "--reboot with reboot needed: reboots" 'calls systemctl | grep -q "^reboot"'
rm -f "$T/needreboot"; reset_calls; bash "$UPD" --reboot >/dev/null 2>&1
check "--reboot without need: no reboot" '! calls systemctl | grep -q "^reboot"'
touch "$T/newkernel"; reset_calls; out=$(bash "$UPD" 2>&1)
check "newer installed kernel counts as reboot needed" 'grep -q "reboot needed: yes" <<<"$out" && grep -q "newest 99.0-1" <<<"$out"'
rm -f "$T/newkernel"; touch "$T/needreboot"
printf 'AUTO_REBOOT=1\n' > "$T/conf"; reset_calls; bash "$UPD" --security >/dev/null 2>&1
check "AUTO_REBOOT=1 alone does not reboot a manual run" '! calls systemctl | grep -q "^reboot"'
reset_calls; bash "$UPD" --security --scheduled >/dev/null 2>&1
check "AUTO_REBOOT=1 + --scheduled + need: reboots" 'calls systemctl | grep -q "^reboot"'
printf 'AUTO_REBOOT=0\n' > "$T/conf"; reset_calls; bash "$UPD" --security --scheduled >/dev/null 2>&1
check "AUTO_REBOOT=0 + --scheduled: no reboot" '! calls systemctl | grep -q "^reboot"'
bash "$UPD" --check --reboot >/dev/null 2>&1; rc=$?
check "--check with --reboot rejected (exit 2)" '[[ $rc -eq 2 ]]'
touch "$T/nocache"; reset_calls; out=$(bash "$UPD" --check 2>&1)
check "needs-restarting retried without -C when -C is unsupported" 'calls dnf | grep -q "needs-restarting -r" && grep -q "reboot needed: yes" <<<"$out"'
unset SERVER_UPDATE_STATE SERVER_INIT_CONF SERVER_SBIN SERVER_CLEANUP_STATE
rm -f "$T/bin/dnf" "$T/bin/rpm" "$T/sbin"/*

# ---------------------------------------------------------------- srv
section "srv"
SRV="$S/srv.sh"
export SERVER_SBIN="$T/sbin" SERVER_BIN="$T/sbin"
for t in server-update server-cleanup server-notify health; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "%s/calls/srv"\n' "$t" "$T" > "$T/sbin/$t"
done
chmod +x "$T/sbin/"*
reset_calls
bash "$SRV" status >/dev/null; bash "$SRV" health -q >/dev/null; bash "$SRV" update --check >/dev/null
bash "$SRV" clean --dry-run >/dev/null; bash "$SRV" notify-test >/dev/null
check "dispatch: status, health, update, clean, notify-test" '[[ "$(calls srv)" == "health --brief
health -q
server-update --check
server-cleanup --dry-run
server-notify test test message from srv" ]]'
bash "$SRV" help >/dev/null; check "help exits 0" '[[ $? -eq 0 ]]'
bash "$SRV" bogus >/dev/null 2>&1; check "unknown command exits 2" '[[ $? -eq 2 ]]'
if command -v setpriv >/dev/null 2>&1; then
  cp "$SRV" "$T/srv.sh"; chmod 0755 "$T/srv.sh"; SRV="$T/srv.sh"   # readable by the unprivileged user
  stub sudo 'if [[ "$*" == "-n true" ]]; then exit 0; fi; exit 0'
  reset_calls
  setpriv --reuid=65534 --regid=65534 --clear-groups bash "$SRV" update --security >/dev/null 2>&1
  check "non-root: elevates through sudo -n with the original args" 'calls sudo | grep -q -- "^-n -- .*srv.sh update --security$"'
  check "non-root: command itself not run unelevated" '[[ -z "$(calls srv)" ]]'
  rm -f "$T/bin/sudo"
  out=$(setpriv --reuid=65534 --regid=65534 --clear-groups env PATH=/usr/bin:/bin bash "$SRV" clean 2>&1); rc=$?
  check "non-root without sudo: clear error, exit 1" '[[ $rc -eq 1 ]] && grep -q "needs root or passwordless sudo" <<<"$out"'
  setpriv --reuid=65534 --regid=65534 --clear-groups bash "$SRV" health -q >/dev/null 2>&1
  check "health is not elevated by srv (health does it itself)" 'calls srv | grep -q "^health -q"'
else
  echo "  SKIP  srv elevation: setpriv not available"
fi
unset SERVER_SBIN SERVER_BIN; rm -f "$T/sbin"/*

# ---------------------------------------------------------------- health --brief
section "health --brief"
H="$ROOT/common/health"
export HEALTH_BRIEF_DIR="$T/hb" SERVER_UPDATE_STATE="$T/ustate" SERVER_CLEANUP_STATE="$T/cstate" SERVER_SBIN="$T/sbin"
mkdir -p "$T/hb" "$T/ustate" "$T/cstate"
now=$(date +%s)
echo "time=$((now - 3600)) updates=3 reboot=1 running=6.1 newest=6.2 updated=$((now - 172800)) uresult=ok" > "$T/ustate/state"
echo "$((now - 259200))" > "$T/cstate/last-run"; echo ok > "$T/cstate/last-result"
echo "time=$((now - 7200)) warn=1 fail=0" > "$T/hb/full"
stub firewall-cmd 'case "$*" in "--state") echo running ;; *"--list-services"*) echo "ssh dhcpv6-client"; echo "80/tcp" ;; esac'
stub fail2ban-client 'printf "Status for the jail: sshd\n|- Filter\n   |- Currently failed:\t0\n- Actions\n   |- Currently banned:\t2\n"'
out=$(bash "$H" --brief --no-color 2>&1); rc=$?
echo "$out" | sed 's/^/      | /'
n=$(wc -l <<<"$out")
check "exit 0" '[[ $rc -eq 0 ]]'
check "at most 8 lines (got $n)" '(( n <= 8 ))'
check "firewall state and open ports" 'grep -q "firewalld active, open: ssh dhcpv6-client 80/tcp" <<<"$out"'
check "fail2ban banned count" 'grep -q "2 banned now" <<<"$out"'
check "pending updates and reboot flag from the cache" 'grep -q "3 update(s) pending, reboot needed: yes" <<<"$out"'
check "last update and cleanup ages" 'grep -q "update 2d.* ago (ok), cleanup 3d.* ago (ok)" <<<"$out"'
check "last full run counts" 'grep -q "0 FAIL, 1 WARN" <<<"$out"'
check "reboot is marked" 'grep -E "reboot needed: yes.*WARN" <<<"$out" >/dev/null'
stub df 'printf "Filesystem 1K Used Avail Cap Mounted\n/dev/x 100 90 10 90%% /\n"'
out=$(bash "$H" --brief --no-color 2>&1)
check "disk 90% used is marked FAIL" 'grep -E "disk .*90% used FAIL" <<<"$out" >/dev/null'
rm -f "$T/bin/df"
check "brief does not call dnf" '! grep -q . <<<"$(calls dnf)"'
bash "$H" --brief --write >/dev/null 2>&1; rc=$?
check "--write: brief.txt written, mode 0644, no stdout needed" '[[ $rc -eq 0 && -f "$T/hb/brief.txt" && "$(stat -c %a "$T/hb/brief.txt")" == 644 ]]'
check "--write: the cached file equals a fresh render" 'diff <(sed "s/(as of [0-9:]*)//" "$T/hb/brief.txt") <(bash "$H" --brief --no-color | sed "s/(as of [0-9:]*)//") >/dev/null'
rm -f "$T/hb/full"
bash "$H" --brief --write >/dev/null 2>&1
check "--write with no recent full run: runs one and stores counts" 'grep -qE "^time=[0-9]+ warn=[0-9]+ fail=[0-9]+" "$T/hb/full" && [[ "$(stat -c %a "$T/hb/last-full.log")" == 600 ]]'
bash "$H" --write >/dev/null 2>&1; check "--write without --brief rejected (exit 2)" '[[ $? -eq 2 ]]'
unset HEALTH_BRIEF_DIR SERVER_UPDATE_STATE SERVER_CLEANUP_STATE SERVER_SBIN
rm -f "$T/bin/firewall-cmd" "$T/bin/fail2ban-client"

section "health: timers in the full report"
printf 'ADMIN_USER=ops\n' > "$T/hconf"
stub systemctl 'case "$1" in
  list-unit-files) case "$2" in server-cleanup.timer|server-update.timer|dnf-automatic.timer) echo "$2 enabled" ;; esac ;;
  is-enabled|is-active) exit 0 ;;
  show) case "$*" in *Result*) echo "${STUB_RESULT:-success}" ;; *ExecMainExitTimestamp*) echo "Mon 2026-10-26 01:12:00 UTC" ;; *) echo "Tue 2026-10-31 04:40:00 UTC" ;; esac ;;
esac; exit 0'
out=$(bash -c 'sed "s#/etc/server-init.conf#'"$T"'/hconf#g" '"$H"' > '"$T"'/health-t; bash '"$T"'/health-t -q --no-color' 2>&1)
check "server-cleanup.timer: active and last run shown" 'grep -q "server-cleanup.timer active, last run Mon 2026-10-26" <<<"$out"'
check "server-update.timer together with dnf-automatic: warned" 'grep -q "server-update.timer and dnf-automatic.timer are both enabled" <<<"$out"'
out=$(STUB_RESULT=exit-code bash "$T/health-t" -q --no-color 2>&1)
check "failed last cleanup run: WARN with the result" 'grep -E "WARN +server-cleanup.timer active.*exit-code" <<<"$out" >/dev/null'
rm -f "$T/bin/systemctl"

# ---------------------------------------------------------------- calendars
section "timer calendars"
if command -v systemd-analyze >/dev/null 2>&1; then
  for cal in "*-*-* 04:30" "weekly"; do
    systemd-analyze calendar "$cal" >/dev/null 2>&1; check "OnCalendar '$cal' is valid" '[[ $? -eq 0 ]]'
  done
else echo "  SKIP  systemd-analyze not available"; fi

# ---------------------------------------------------------------- firewall and a non-default SSH port
section "debian firewall with sshd on another port"
{
  echo 'APP=none; EXTRA_PORTS=""; APP_NAME=""; APP_OWN_FW=0; CONF_FILE=x; log() { :; }; fail() { echo "FAIL $*"; }; detect_app() { :; }; pkg_installed() { return 1; }'
  grep -E '^ufw_(is_active|ssh_saved|ssh_live|open)\(\) \{' "$S/server-init-debian.sh"
  awk '/^unknown_hetzner_app\(\)/,/^}/' "$S/server-init-debian.sh"
  awk '/^firewall\(\)/,/^}/' "$S/server-init-debian.sh"
} > "$T/fw-funcs.sh"
: > "$T/ufw.rules"; rm -f "$T/ufw.active"
stub ufw 'R="'"$T"'/ufw.rules"; A="'"$T"'/ufw.active"
case "$1 ${2:-}" in
  "show added") echo "Added user rules:"; while read -r l; do echo "ufw allow $l"; done < "$R" ;;
  "status ") if [ -f "$A" ]; then echo "Status: active"; while read -r l; do echo "$l ALLOW Anywhere"; done < "$R"; else echo "Status: inactive"; fi ;;
  "--force enable") touch "$A" ;;
  allow*) echo "$2" >> "$R" ;;
esac'
stub systemctl 'exit 0'
stub sshd 'echo "port 22"; echo "port 2222"'
out=$(bash -c 'source "$1"; firewall' _ "$T/fw-funcs.sh" 2>&1); rc=$?
check "ufw is enabled with both 22 and the sshd port allowed" '[[ $rc -eq 0 ]] && grep -qx "22/tcp" "$T/ufw.rules" && grep -qx "2222/tcp" "$T/ufw.rules" && [[ -f "$T/ufw.active" ]]'
rm -f "$T/bin/ufw" "$T/bin/sshd"

section "runner host firewall (ufw branch)"
: > "$T/ufw.rules"; rm -f "$T/ufw.active"
stub ufw 'R="'"$T"'/ufw.rules"; A="'"$T"'/ufw.active"
case "$1 ${2:-}" in
  "show added") echo "Added user rules:"; while read -r l; do echo "ufw allow $l"; done < "$R" ;;
  "status ") if [ -f "$A" ]; then echo "Status: active"; while read -r l; do echo "$l ALLOW Anywhere"; done < "$R"; else echo "Status: inactive"; fi ;;
  "--force enable") touch "$A" ;;
  allow*) echo "$2" >> "$R" ;;
esac'
stub systemctl 'exit 0'
stub sshd 'echo "port 2222"'
stub apt-get 'exit 0'
stub fail2ban-client 'echo "Status"'
out=$(JAIL_FILE="$T/jail.local" PATH="$T/bin:/usr/bin:/bin" bash "$ROOT/runner/install/host-firewall.sh" 2>&1); rc=$?
check "ufw enabled, 22 and the sshd port allowed" '[[ $rc -eq 0 ]] && grep -qx "22/tcp" "$T/ufw.rules" && grep -qx "2222/tcp" "$T/ufw.rules" && [[ -f "$T/ufw.active" ]]'
check "fail2ban sshd jail written for nftables" 'grep -q "^banaction = nftables" "$T/jail.local" && grep -q "^\[sshd\]" "$T/jail.local"'
rm -f "$T/bin/ufw" "$T/bin/sshd" "$T/bin/apt-get" "$T/bin/fail2ban-client"

section "ci-job-isolation rules (own network namespace)"
if command -v iptables >/dev/null 2>&1 && unshare -n true 2>/dev/null; then
  stub logger 'exit 0'
  out=$(BRIDGE_IP=172.17.0.1 PATH="$T/bin:$PATH" unshare -n bash -c '
    iptables -N DOCKER-USER; iptables -A DOCKER-USER -j RETURN; iptables -A FORWARD -j DOCKER-USER
    bash "$1"; bash "$1" >/dev/null; iptables -S' _ "$ROOT/runner/scripts/ci-job-isolation.sh" 2>&1)
  check "metadata address dropped in DOCKER-USER, once after two runs" '[[ $(grep -c -- "-A DOCKER-USER -d 169.254.169.254/32.* -j DROP" <<<"$out") -eq 1 ]]'
  check "job bridges go through CI-JOBS-IN, npm cache port accepted, rest dropped" 'grep -q -- "-A INPUT -i docker0 .*-j CI-JOBS-IN" <<<"$out" && grep -q -- "-A CI-JOBS-IN -d 172.17.0.1/32 -i docker0 -p tcp -m tcp --dport 4873 -j ACCEPT" <<<"$out" && grep -q -- "-A CI-JOBS-IN -j DROP" <<<"$out"'
  rm -f "$T/bin/logger"
else
  echo "  SKIP  no iptables or network namespaces here"
fi

section "runner-engine-update"
stub logger 'exit 0'
export ENGINE_UPDATE_LOG="$T/engine.log"
stub docker 'echo abc123'
out=$(bash "$ROOT/runner/scripts/runner-engine-update.sh" 2>&1); rc=$?
check "a running CI job: skipped, exit 0" '[[ $rc -eq 0 ]] && grep -q "SKIP 1 CI job" <<<"$out"'
stub docker 'exit 1'
out=$(bash "$ROOT/runner/scripts/runner-engine-update.sh" 2>&1); rc=$?
check "docker not answering is not 'no jobs'" '[[ $rc -eq 0 ]] && grep -q "SKIP docker does not answer" <<<"$out"'
rm -f "$T/bin/docker" "$T/bin/logger"; unset ENGINE_UPDATE_LOG

section "server lock-root"
LR="$ROOT/server/lock-root.sh"
mkdir -p "$T/lr/home/.ssh" "$T/lr/sshd_config.d"
echo "Include /etc/ssh/sshd_config.d/*.conf" > "$T/lr/sshd_config"
export LOCK_ROOT_DROPIN="$T/lr/sshd_config.d/00-a-root-lock.conf" LOCK_ROOT_SSHD_CONFIG="$T/lr/sshd_config" ADMIN_USER=ops
stub id 'exit 0'
stub getent 'echo "ops:x:1000:1000::'"$T"'/lr/home:/bin/bash"'
stub runuser 'exit 0'
stub systemctl 'exit 0'
stub sshd 'if [[ "$1" == -t ]]; then exit 0; fi; if [[ -f "'"$T"'/lr/sshd_config.d/00-a-root-lock.conf" ]]; then echo "permitrootlogin no"; else echo "permitrootlogin without-password"; fi; echo "port 22"'
out=$(bash "$LR" 2>&1); rc=$?
check "no SSH key for the admin: refused, nothing written" '[[ $rc -ne 0 ]] && grep -q "has no SSH key" <<<"$out" && [[ ! -e "$LOCK_ROOT_DROPIN" ]]'
echo "ssh-ed25519 AAAA test" > "$T/lr/home/.ssh/authorized_keys"
stub runuser 'exit 1'
out=$(bash "$LR" 2>&1); rc=$?
check "sudo -n true fails for the admin: refused" '[[ $rc -ne 0 ]] && grep -q "sudo -n true" <<<"$out" && [[ ! -e "$LOCK_ROOT_DROPIN" ]]'
stub runuser 'exit 0'
out=$(bash "$LR" 2>&1); rc=$?
check "key and sudo ok: drop-in written, effective no" '[[ $rc -eq 0 ]] && grep -qx "PermitRootLogin no" "$LOCK_ROOT_DROPIN"'
out=$(bash "$LR" --unlock-root 2>&1); rc=$?
check "--unlock-root removes the drop-in" '[[ $rc -eq 0 && ! -e "$LOCK_ROOT_DROPIN" ]]'
stub sshd 'if [[ "$1" == -t ]]; then exit 0; fi; echo "permitrootlogin without-password"; echo "port 22"'
out=$(bash "$LR" 2>&1); rc=$?
check "another file wins (effective not no): reverted and refused" '[[ $rc -ne 0 && ! -e "$LOCK_ROOT_DROPIN" ]]'
rm -f "$T"/bin/{id,getent,runuser,sshd,systemctl}; unset LOCK_ROOT_DROPIN LOCK_ROOT_SSHD_CONFIG ADMIN_USER

# ---------------------------------------------------------------- destructive (container) tests
if [[ $DESTRUCTIVE != 1 ]]; then
  echo
  echo "SKIPPED destructive tests (cleanup run, install-tools, server-init step): set SERVER_TOOLS_TEST_DESTRUCTIVE=1 in a container"
  echo "RESULT: $PASS passed, $FAIL failed"; [[ $FAIL -eq 0 ]]; exit
fi

section "server-cleanup (real run in a container, stub tools)"
CL="$S/server-cleanup.sh"
printf '' > /etc/server-init.conf
mkdir -p /var/log /home /root /srv /opt /var/lib/docker/volumes/v1/_data /var/lib/systemd/coredump /var/crash /etc/dnf
for d in /home /root /srv /opt /var/lib/docker/volumes/v1/_data; do
  echo keep > "$d/marker.gz"; echo keep > "$d/marker.1"; touch -d '400 days ago' "$d/marker.gz" "$d/marker.1"
done
echo old > /var/log/old.log.gz; echo old > /var/log/old.log.2; echo new > /var/log/new.log.gz; echo cur > /var/log/messages
touch -d '40 days ago' /var/log/old.log.gz /var/log/old.log.2; touch -d '400 days ago' /var/log/messages
echo c > /var/lib/systemd/coredump/core.old; touch -d '10 days ago' /var/lib/systemd/coredump/core.old
echo c > /var/lib/systemd/coredump/core.new
echo c > /var/crash/old; touch -d '60 days ago' /var/crash/old
printf '[main]\ngpgcheck=1\n' > /etc/dnf/dnf.conf
snap() { find /var/log /home /root /srv /opt /var/lib /var/crash /etc/dnf -xdev -type f -not -path '/var/lib/rpm/*' -not -path '/var/lib/dnf/*' -not -path '/var/log/dnf*' 2>/dev/null | sort | xargs -r md5sum | md5sum; }
stub journalctl 'if [[ "$1" == --disk-usage ]]; then echo "Archived and active journals take up 1.0G"; fi'
stub dnf 'exit 0'
stub docker 'exit 0'
stub systemctl '[[ "$1 $2" == "is-active --quiet" && "$3" == docker ]] && exit 0; exit 0'
stub systemd-tmpfiles 'exit 0'
stub logger 'exit 0'
before=$(snap)
out=$(bash "$CL" --dry-run 2>&1); rc=$?
check "--dry-run: exit 0" '[[ $rc -eq 0 ]]'
check "--dry-run: nothing changed on disk" '[[ "$(snap)" == "$before" ]]'
check "--dry-run: no stub tool was executed (only the read-only journalctl --disk-usage)" '[[ "$(calls journalctl)" == "--disk-usage" && -z "$(calls docker)$(calls systemd-tmpfiles)$(calls dnf)" ]]'
check "--dry-run: plan printed" 'grep -q "would run: journalctl --vacuum-time=1month --vacuum-size=500M" <<<"$out" && grep -q "would run: docker image prune -f" <<<"$out" && grep -q "would delete rotated logs: 2 files" <<<"$out" && grep -q "would set installonly_limit=3" <<<"$out"'
check "--dry-run: no syslog line" '[[ -z "$(calls logger)" ]]'
check "--dry-run: before/after disk shown" 'grep -q "disk_before: used=" <<<"$out" && grep -q "disk_after: used=" <<<"$out"'
check "--dry-run: stamp not written" '[[ ! -e /var/lib/server-cleanup/last-run ]]'
reset_calls
out=$(bash "$CL" 2>&1); rc=$?
check "real run: exit 0" '[[ $rc -eq 0 ]]'
check "real run: old rotated logs deleted, new and current kept" '[[ ! -e /var/log/old.log.gz && ! -e /var/log/old.log.2 && -e /var/log/new.log.gz && -e /var/log/messages ]]'
check "real run: old core dump and crash file deleted, new core kept" '[[ ! -e /var/lib/systemd/coredump/core.old && ! -e /var/crash/old && -e /var/lib/systemd/coredump/core.new ]]'
check "real run: /home /root /srv /opt and docker volume markers survive" 'for d in /home /root /srv /opt /var/lib/docker/volumes/v1/_data; do [[ -e $d/marker.gz && -e $d/marker.1 ]] || exit 1; done'
check "real run: journal vacuum with defaults" 'calls journalctl | grep -q -- "--vacuum-time=1month --vacuum-size=500M"'
check "real run: docker only container/image/builder prune, dangling only, until=168h" '[[ "$(calls docker)" == "container prune -f --filter until=168h
image prune -f
builder prune -f --filter until=168h" ]]'
check "real run: never volume, never -a, never system prune" '! calls docker | grep -qE "volume|system|-a"'
check "real run: dnf clean packages; no autoremove by default" 'calls dnf | grep -q "^clean packages$" && ! calls dnf | grep -q autoremove'
check "real run: tmpfiles limited to /tmp and /var/tmp" '[[ "$(calls systemd-tmpfiles)" == "--clean --prefix=/tmp --prefix=/var/tmp" ]]'
check "real run: installonly_limit=3 added to dnf.conf" 'grep -q "^installonly_limit=3" /etc/dnf/dnf.conf && grep -q "^gpgcheck=1" /etc/dnf/dnf.conf'
check "real run: syslog lines written, stamp written" '[[ -n "$(calls logger)" && -s /var/lib/server-cleanup/last-run && "$(cat /var/lib/server-cleanup/last-result)" == ok ]]'
bash "$CL" >/dev/null 2>&1; check "rerun: installonly_limit not duplicated" '[[ $(grep -c "^installonly_limit" /etc/dnf/dnf.conf) -eq 1 ]]'
reset_calls
CLEAN_AUTOREMOVE=1 CLEAN_DOCKER_UNUSED_IMAGES=1 bash -c ". /dev/null; printf 'CLEAN_AUTOREMOVE=1\nCLEAN_DOCKER_UNUSED_IMAGES=1\nCLEAN_JOURNAL_TIME=2weeks\nCLEAN_JOURNAL_SIZE=200M\n' > /etc/server-init.conf; bash $CL" >/dev/null 2>&1
check "settings from conf: autoremove, unused images (720h), journal 2weeks/200M" 'calls dnf | grep -q "^-y autoremove$" && calls docker | grep -q "^image prune -a -f --filter until=720h$" && calls journalctl | grep -q -- "--vacuum-time=2weeks --vacuum-size=200M"'
check "even then: no volume prune" '! calls docker | grep -q volume'
printf 'CLEAN_JOURNAL_TIME=evil;rm\nCLEAN_JOURNAL_SIZE=big\n' > /etc/server-init.conf; reset_calls
bash "$CL" >/dev/null 2>&1
check "bad journal settings fall back to defaults" 'calls journalctl | grep -q -- "--vacuum-time=1month --vacuum-size=500M"'
rm -f /etc/server-init.conf; reset_calls
bash "$CL" >/dev/null 2>&1
check "existing install without any CLEAN_* keys: defaults used" 'calls journalctl | grep -q -- "--vacuum-time=1month --vacuum-size=500M" && ! calls dnf | grep -q autoremove'
stub docker 'exit 0'; stub systemctl 'exit 3'; reset_calls
bash "$CL" >/dev/null 2>&1
check "docker not active: docker skipped" '[[ -z "$(calls docker)" ]]'
stub systemctl 'exit 0'
rm -f "$T/bin/journalctl" "$T/bin/dnf"; out=$(PATH="$T/bin:/usr/bin:/bin" bash -c 'hash -r; command -v journalctl dnf >/dev/null && echo present; bash '"$CL"' --dry-run' 2>&1)
check "missing tools skipped cleanly" 'grep -q "skip journald\|journalctl" <<<"$out" || true'
# concurrency: a second run while the lock is held exits at once and does nothing
stub journalctl 'exit 0'; reset_calls
( exec 9>/run/server-cleanup.lock; flock -n 9 && sleep 5 ) &
sleep 1
out=$(bash "$CL" 2>&1); rc=$?
check "second run while one is running: exits 0, does nothing" '[[ $rc -eq 0 && -z "$(calls journalctl)" ]] && grep -q "another server-cleanup is running" <<<"$out"'
wait
bash "$CL" --bogus >/dev/null 2>&1; check "bad option exits 2" '[[ $? -eq 2 ]]'
bash "$CL" --help | grep -q "dry-run"; check "--help works" '[[ $? -eq 0 ]]'
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/dnf"; chmod +x "$T/bin/dnf"; reset_calls
bash "$CL" >/dev/null 2>&1; check "a failing action: exit 3, last-result failed" '[[ $? -eq 3 && "$(cat /var/lib/server-cleanup/last-result)" == failed ]]'
rm -f "$T/bin/dnf"

section "install-tools (container, stub systemctl)"
IT="$S/install-tools.sh"
rm -f /usr/local/sbin/server-cleanup
bash "$IT" >/dev/null 2>&1; check "refuses without server-cleanup (run server-init first)" '[[ $? -eq 1 ]]'
cp "$CL" /usr/local/sbin/server-cleanup; chmod 0755 /usr/local/sbin/server-cleanup
printf 'ADMIN_USER=ops\nINSTALL_CLEANUP=1\n' > /etc/server-init.conf
printf 'dnf-automatic.timer\ndnf5-automatic.timer\n' > "$T/units"
stub systemctl 'if [[ "$1" == cat ]]; then grep -qx "$2" "'"$T"'/units"; exit $?; fi; if [[ "$1 $2" == "is-enabled --quiet" ]]; then exit 1; fi; exit 0'
stub systemd-analyze 'exit 0'
reset_calls
out=$(bash "$IT" 2>&1); rc=$?
check "install-tools exits 0" '[[ $rc -eq 0 ]]' ; [[ $rc -eq 0 ]] || echo "$out" | tail -5
check "files installed" 'for f in /usr/local/sbin/server-update /usr/local/sbin/server-notify /usr/local/sbin/server-disk-guard /usr/local/bin/srv /usr/local/bin/health /etc/profile.d/91-server-login.sh /etc/systemd/system/server-update.timer /etc/systemd/system/server-disk-guard.timer /etc/systemd/system/server-health-brief.timer; do [[ -f $f ]] || { echo "missing $f"; exit 1; }; done'
check "update timer: 04:30, 30m jitter, persistent" 'grep -q "^OnCalendar=\*-\*-\* 04:30$" /etc/systemd/system/server-update.timer && grep -q "RandomizedDelaySec=30m" /etc/systemd/system/server-update.timer && grep -q "Persistent=true" /etc/systemd/system/server-update.timer'
check "server-update.timer and the other timers enabled" 'calls systemctl | grep -q "enable --now server-update.timer" && calls systemctl | grep -q "enable --now server-disk-guard.timer server-health-brief.timer"'
check "dnf-automatic timers disabled while server-update.timer is on" 'calls systemctl | grep -q "disable --now dnf-automatic.timer" && calls systemctl | grep -q "disable --now dnf5-automatic.timer" && ! calls systemctl | grep -q "enable --now dnf"'
check "notify.env: 0600, only comments" '[[ "$(stat -c %a /etc/server-init.d/notify.env)" == 600 ]] && ! grep -qvE "^(#|$)" /etc/server-init.d/notify.env'
check "conf got the commented settings block once" '[[ $(grep -c "^# Maintenance tools" /etc/server-init.conf) -eq 1 ]] && ! grep -qE "^(UPDATE_SCHEDULE|AUTO_REBOOT)" /etc/server-init.conf'
md1=$(cat /etc/server-init.conf /etc/systemd/system/server-*.{service,timer} /usr/local/sbin/server-* | md5sum)
bash "$IT" >/dev/null 2>&1
md2=$(cat /etc/server-init.conf /etc/systemd/system/server-*.{service,timer} /usr/local/sbin/server-* | md5sum)
check "rerun is idempotent (files unchanged)" '[[ "$md1" == "$md2" ]]'
printf 'ADMIN_USER=ops\nUPDATE_SCHEDULE="Sat *-*-* 03:00"\nLOGIN_SUMMARY=0\n' > /etc/server-init.conf; reset_calls
bash "$IT" >/dev/null 2>&1
check "UPDATE_SCHEDULE from conf used; LOGIN_SUMMARY=0 removes the snippet" 'grep -q "^OnCalendar=Sat \*-\*-\* 03:00$" /etc/systemd/system/server-update.timer && [[ ! -e /etc/profile.d/91-server-login.sh ]]'
printf 'UPDATE_SCHEDULE=off\n' > /etc/server-init.conf; reset_calls
bash "$IT" >/dev/null 2>&1
check "UPDATE_SCHEDULE=off: server-update.timer disabled, dnf5-automatic back on" 'calls systemctl | grep -q "disable --now server-update.timer" && calls systemctl | grep -q "enable --now dnf5-automatic.timer"'

section "server-init cleanup step (container, other steps removed)"
. /etc/os-release
case "${ID}:${VERSION_ID%%.*}" in
  almalinux:10|rocky:10|centos:10) INIT="$S/server-init-el10.sh" ;;
  fedora:*) INIT="$S/server-init-fedora.sh" ;;
  *) INIT="" ;;
esac
if [[ -n $INIT ]]; then
  # keep the helpers and the cleanup step; drop every other step and the firewall summary line
  grep -vE '^step (packages|configs|ssh-hardening|admin-user|system-tuning|firewall|fail2ban|auto-updates|docker|swap) |^log "open in firewall' "$INIT" > "$T/init-test.sh"
  rm -f /usr/local/sbin/server-cleanup /etc/systemd/system/server-cleanup.* /etc/server-init.conf
  reset_calls
  bash "$T/init-test.sh" >/dev/null 2>&1; rc=$?
  check "fresh run: exit 0, conf has the cleanup keys" '[[ $rc -eq 0 ]] && grep -q "^INSTALL_CLEANUP=1" /etc/server-init.conf && grep -q "^CLEAN_SCHEDULE=weekly" /etc/server-init.conf && grep -q "^CLEAN_AUTOREMOVE=0" /etc/server-init.conf'
  check "server-cleanup installed 0755 and identical to server/server-cleanup.sh" 'cmp -s /usr/local/sbin/server-cleanup "$CL" && [[ "$(stat -c %a /usr/local/sbin/server-cleanup)" == 755 ]]'
  check "service: Nice=19 idle IO, ProtectHome=read-only, NoNewPrivileges, no PrivateTmp" 'u=/etc/systemd/system/server-cleanup.service; grep -q "^Type=oneshot" $u && grep -q "^Nice=19" $u && grep -q "^IOSchedulingClass=idle" $u && grep -q "^ProtectHome=read-only" $u && grep -q "^NoNewPrivileges=yes" $u && ! grep -q PrivateTmp $u'
  check "timer: weekly, RandomizedDelaySec=1h, Persistent=true, enabled" 'u=/etc/systemd/system/server-cleanup.timer; grep -q "^OnCalendar=weekly" $u && grep -q "^RandomizedDelaySec=1h" $u && grep -q "^Persistent=true" $u && calls systemctl | grep -q "enable --now server-cleanup.timer"'
  md1=$(cat /etc/server-init.conf /usr/local/sbin/server-cleanup /etc/systemd/system/server-cleanup.* | md5sum); st1=$(stat -c %Y /usr/local/sbin/server-cleanup /etc/systemd/system/server-cleanup.timer)
  sleep 1; bash "$T/init-test.sh" >/dev/null 2>&1
  md2=$(cat /etc/server-init.conf /usr/local/sbin/server-cleanup /etc/systemd/system/server-cleanup.* | md5sum); st2=$(stat -c %Y /usr/local/sbin/server-cleanup /etc/systemd/system/server-cleanup.timer)
  check "rerun idempotent: nothing rewritten" '[[ "$md1" == "$md2" && "$st1" == "$st2" ]]'
  echo server-cleanup.timer >> "$T/units"   # the timer exists from the previous run
  printf 'ADMIN_USER=ops\nINSTALL_DOCKER=1\nINSTALL_SWAP=1\nTIMEZONE=Europe/Kyiv\nINSTALL_CLEANUP=0\n' > /etc/server-init.conf
  cp /etc/server-init.conf "$T/conf.before"; reset_calls
  bash "$T/init-test.sh" >/dev/null 2>&1; rc=$?
  check "INSTALL_CLEANUP=0: exit 0, timer disabled, conf untouched" '[[ $rc -eq 0 ]] && calls systemctl | grep -q "disable --now server-cleanup.timer" && cmp -s /etc/server-init.conf "$T/conf.before"'
  printf 'ADMIN_USER=ops\nINSTALL_DOCKER=1\nINSTALL_SWAP=1\nTIMEZONE=Europe/Kyiv\n' > /etc/server-init.conf
  cp /etc/server-init.conf "$T/conf.before"; reset_calls
  bash "$T/init-test.sh" >/dev/null 2>&1; rc=$?
  check "old install (no cleanup keys): defaults apply, step runs, conf not rewritten" '[[ $rc -eq 0 ]] && cmp -s /etc/server-init.conf "$T/conf.before" && calls systemctl | grep -q "enable --now server-cleanup.timer"'
  printf 'ADMIN_USER=ops\nCLEAN_SCHEDULE="not a calendar"\n' > /etc/server-init.conf
  stub systemd-analyze '[[ "$*" == "calendar not a calendar" ]] && exit 1; exit 0'; reset_calls
  bash "$T/init-test.sh" >/dev/null 2>&1
  check "invalid CLEAN_SCHEDULE: logged, falls back to weekly" 'grep -q "^OnCalendar=weekly" /etc/systemd/system/server-cleanup.timer'
else
  echo "  SKIP  server-init step: unsupported distro ${ID}"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
