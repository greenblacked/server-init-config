# shellcheck shell=bash
# Tests for runner/scripts/github-runner-ctl with stubbed curl and docker (no network, no Docker; real openssl and jq).
# Sourced by run.sh; $T is a private empty directory, $REPO the repository root.
#   curl stub    answers from fixtures written by fx METHOD PATH CODE BODY [ETAG]; anything else is a 404 and shows up as MISSING in curl.log
#   docker stub  logs every call; "ps -a" prints $T/ps.txt, "network ls" prints $T/nets.txt, "inspect" prints $T/inspect.txt
# The secrets of the tests are fake markers (TESTTOKEN, JITSECRETMARKER, the throwaway key); no test output may contain them.
CTL="$REPO/runner/scripts/github-runner-ctl"
TOKEN=ghs_TESTTOKEN123XYZ
REPOTOKEN=ghs_REPOTOKEN456XYZ
JITMARK=JITSECRETMARKER9876

fxkey() { printf '%s %s' "$1" "$2" | md5sum | cut -c1-32; }
# fx METHOD PATH CODE BODY [ETAG]
fx() {
  local k; k=$(fxkey "$1" "$2")
  printf '%s' "$3" > "$T/fx/$k.code"; printf '%s' "$4" > "$T/fx/$k.body"
  if [[ -n "${5:-}" ]]; then printf '%s' "$5" > "$T/fx/$k.etag"; fi
}
repo_json() { # NAME PRIVATE VISIBILITY ARCHIVED [OWNER]
  printf '{"full_name":"%s/%s","owner":{"login":"%s"},"private":%s,"visibility":"%s","archived":%s,"disabled":false}' "${5:-octo}" "$1" "${5:-octo}" "$2" "$3" "$4"
}
repos_fx() { # repo_json... : the installation's repository list (one page)
  local IFS=,; fx GET '/installation/repositories?per_page=100&page=1' 200 "{\"total_count\":$#,\"repositories\":[$*]}" "${ETAG:-}"
}
runners_fx() { fx GET "/repos/octo/$1/actions/runners?per_page=100" 200 "$2"; } # NAME JSON
none_runners_for() { local r; for r in "$@"; do runners_fx "$r" '{"total_count":0,"runners":[]}'; done; }
queued_fx() { # REPO RUN_ID JOBS_JSON [EVENT] [HEAD_REPO]
  local ev=${4:-push} head=${5:-octo/$1}
  fx GET "/repos/octo/$1/actions/runs?status=queued&per_page=50&page=1" 200 "{\"workflow_runs\":[{\"id\":$2,\"event\":\"$ev\",\"repository\":{\"full_name\":\"octo/$1\"},\"head_repository\":{\"full_name\":\"$head\"}}]}"
  fx GET "/repos/octo/$1/actions/runs?status=in_progress&per_page=50&page=1" 200 '{"workflow_runs":[]}'
  fx GET "/repos/octo/$1/actions/runs/$2/jobs?filter=latest&per_page=100&page=1" 200 "$3"
}
job_json() { # ID STATUS RUNNER_ID LABELS(json array)
  printf '{"id":%s,"status":"%s","runner_id":%s,"labels":%s}' "$1" "$2" "$3" "$4"
}
jit_fx() { fx POST "/repos/octo/$1/actions/runners/generate-jitconfig" 201 "{\"runner\":{\"id\":$2,\"name\":\"x\"},\"encoded_jit_config\":\"$JITMARK\"}"; }
calls_to() { if [[ -f "$T/log/curl.log" ]]; then grep -c "$1" "$T/log/curl.log" || true; else echo 0; fi; }
host_prefix() { printf 'ghr-%s-' "$(hostname -s | tr -c 'A-Za-z0-9-\n' '-' | cut -c1-30)"; }

setup_ctl() {
  mkdir -p "$T/bin" "$T/fx" "$T/log" "$T/state"
  openssl genrsa -out "$T/app.pem" 2048 2>/dev/null; chmod 0600 "$T/app.pem"
  local runner_img buildkit_img
  runner_img=$(sed -n 's/^GHR_RUNNER_IMAGE="\(.*\)"$/\1/p' "$REPO/common/lib.sh")
  buildkit_img=$(sed -n 's/^GHR_BUILDKIT_IMAGE="\(.*\)"$/\1/p' "$REPO/common/lib.sh")
  cat > "$T/config.env" <<EOF
GH_OWNER=octo
GH_APP_CLIENT_ID=Iv1.testclient
GH_INSTALLATION_ID=42
GH_LABELS=self-hosted,linux,arm64,hetzner
GH_RUNNER_GROUP_ID=1
GH_MAX_JOBS=1
GH_EXCLUDE_REPOS=
GH_RUNNER_IMAGE=$runner_img
GH_BUILDKIT_IMAGE=$buildkit_img
GH_KEY_FILE=$T/app.pem
EOF
  cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
method=GET hdrf="" outf="" url="" ifnone="" auth="" data=""
while (( $# )); do
  case "$1" in
    -X) method=$2; shift ;;
    -D) hdrf=$2; shift ;;
    -o) outf=$2; shift ;;
    -w|-m|--connect-timeout) shift ;;
    -H) case "$2" in If-None-Match:*) ifnone=${2#If-None-Match: } ;; esac; shift ;;
    --data-binary) data=${2#@}; shift ;;
    -K) cfg=$(cat); auth=$(sed -n 's/^header = "Authorization: Bearer \(.*\)"$/\1/p' <<<"$cfg"); shift ;;
    http*) url=$1 ;;
  esac
  shift
done
path=${url#https://api.github.com}
# a token request for one repository (body has "repositories") is a different fixture from the installation-wide one
if [[ -n "$data" && "$path" == */access_tokens ]] && grep -q repositories "$data"; then path="${path}#repo"; fi
key=$(printf '%s %s' "$method" "$path" | md5sum | cut -c1-32)
code=404; body='{"message":"Not Found (no fixture)"}'; etag=""
if [[ -f "$GHR_TEST_FX/$key.code" ]]; then
  code=$(<"$GHR_TEST_FX/$key.code"); body=$(<"$GHR_TEST_FX/$key.body")
  [[ -f "$GHR_TEST_FX/$key.etag" ]] && etag=$(<"$GHR_TEST_FX/$key.etag")
  if [[ -n "$etag" && "$ifnone" == "$etag" ]]; then code=304; body=""; fi
else
  echo "MISSING $method $path" >> "$GHR_TEST_LOG/curl.log"
fi
[[ -n "$data" ]] && cp "$data" "$GHR_TEST_LOG/request.$key"
[[ -n "$auth" ]] && printf '%s' "$auth" > "$GHR_TEST_LOG/auth.$key"
echo "$method $path $code${auth:+ auth}${ifnone:+ if-none-match}" >> "$GHR_TEST_LOG/curl.log"
{ printf 'HTTP/2 %s\r\n' "$code"; [[ -n "$etag" ]] && printf 'etag: %s\r\n' "$etag"
  [[ -f "$GHR_TEST_FX/$key.hdr" ]] && cat "$GHR_TEST_FX/$key.hdr"
  printf 'x-ratelimit-remaining: %s\r\nx-ratelimit-limit: 5000\r\nx-ratelimit-reset: 1\r\n\r\n' "${GHR_TEST_RL:-4999}"; } > "$hdrf"
printf '%s' "$body" > "$outf"
printf '%s' "$code"
STUB
  cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GHR_TEST_LOG/docker.log"
case "$1" in
  info) exit 0 ;;
  image) [[ "$2" == inspect ]] && { echo "2026-10-20T00:00:00Z"; exit 0; } ;;
  ps) [[ -f "$GHR_TEST_LOG/docker-down" ]] && exit 1
      [[ "$2" == -a && -f "$GHR_TEST_LOG/ps.txt" ]] && cat "$GHR_TEST_LOG/ps.txt" ;;
  network) [[ "$2" == ls && -f "$GHR_TEST_LOG/docker-down" ]] && exit 1
           [[ "$2" == ls && -f "$GHR_TEST_LOG/nets.txt" ]] && cat "$GHR_TEST_LOG/nets.txt"
           [[ "$2" == inspect && -f "$GHR_TEST_LOG/bridge.txt" ]] && cat "$GHR_TEST_LOG/bridge.txt"
           # a range listed in overlap.txt is "taken by another network"
           if [[ "$2" == create && -f "$GHR_TEST_LOG/overlap.txt" ]] && grep -qFx -- "$4" "$GHR_TEST_LOG/overlap.txt"; then echo "Error response from daemon: Pool overlaps with other one on this address space" >&2; exit 1; fi
           if [[ "$2" == create ]]; then echo "$4" >> "$GHR_TEST_LOG/created-subnets.txt"; fi ;;
  inspect) if [[ -f "$GHR_TEST_LOG/inspect.txt" ]]; then cat "$GHR_TEST_LOG/inspect.txt"; else echo "0 false"; fi ;;
  logs) if [[ -f "$GHR_TEST_LOG/logs.txt" ]]; then cat "$GHR_TEST_LOG/logs.txt"; else echo "stub runner log line"; fi ;;
  run) n=$(ls "$GHR_TEST_LOG"/run.* 2>/dev/null | wc -l); printf '%s\n' "$@" > "$GHR_TEST_LOG/run.$n" ;;
esac
exit 0
STUB
  chmod +x "$T/bin/curl" "$T/bin/docker"
  export PATH="$T/bin:$PATH" GHR_CONFIG="$T/config.env" GHR_STATE_DIR="$T/state" GHR_TEST_FX="$T/fx" GHR_TEST_LOG="$T/log"
  local exp; exp=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
  fx POST /app/installations/42/access_tokens 201 "{\"token\":\"$TOKEN\",\"expires_at\":\"$exp\"}"
  fx POST '/app/installations/42/access_tokens#repo' 201 "{\"token\":\"$REPOTOKEN\",\"expires_at\":\"$exp\"}"
}

# run the controller once; output (stderr merged) in $T/out, exit code in $RC
ctl_once() { RC=0; bash "$CTL" once > "$T/out" 2>&1 || RC=$?; }
no_secrets_in() {
  local f
  for f in "$@"; do
    if grep -qF -e "$TOKEN" -e "$REPOTOKEN" -e "$JITMARK" -e "$(sed -n 2p "$T/app.pem")" "$f"; then echo "    a secret is in $f" >&2; return 1; fi
  done
}

# ---- configuration -------------------------------------------------------------------------------------------------------------
test_help_needs_no_config() {
  GHR_CONFIG=/nonexistent assert_ok "--help" bash "$CTL" --help
  GHR_CONFIG=/nonexistent bash "$CTL" --help | grep -q "Usage: github-runner-ctl" || return 1
  assert_fail "unknown mode" bash "$CTL" frobnicate
}

test_config_validation_rejects_bad_values() {
  setup_ctl
  local bad key val
  for bad in 'GH_OWNER=bad owner' 'GH_OWNER=-lead' 'GH_APP_CLIENT_ID=a' 'GH_INSTALLATION_ID=12x' 'GH_RUNNER_GROUP_ID=one' 'GH_MAX_JOBS=0' 'GH_MAX_JOBS=abc' \
             'GH_POLL_INTERVAL=5' 'GH_POLL_INTERVAL=99999' 'GH_IDLE_TIMEOUT=10' 'GH_MAX_RUNTIME=10' 'GH_LABELS=self-hosted,linux' 'GH_LABELS=hetzner' \
             'GH_LABELS=self-hosted,bad label' 'GH_EXCLUDE_REPOS=a b/c/d' 'GH_RUNNER_IMAGE=ghcr.io/x/y:1' 'GH_RUNNER_IMAGE=ghcr.io/x/y@sha256:abc' \
             'GH_BUILDKIT_IMAGE=example.org/bk:rootless' 'GH_JOB_MEMORY=lots' 'GH_JOB_CPUS=-1' 'GH_JIT_PASS=file' 'GH_ALLOW_FORK_RUNS=2' 'GH_KEY_FILE=relative.pem' \
             'GH_API_URL=http://api.github.com' 'GH_API_URL=https://api.github.com/' 'GH_JOB_SUBNET_POOL=8.8.8.0/24' 'GH_JOB_SUBNET_POOL=10.0.0.1/24' \
             'GH_JOB_SUBNET_POOL=10.0.0.0/28' 'GH_JOB_SUBNET_POOL=10.0.0.0/8' 'GH_JOB_SUBNET_POOL=10.0.300.0/24' 'GH_JOB_SUBNET_POOL=' 'GH_JOB_SUBNET_POOL=pool'; do
    key=${bad%%=*}; val=${bad#*=}
    cp "$T/config.env" "$T/config.bad"; grep -v "^${key}=" "$T/config.bad" > "$T/config.env"; printf '%s=%s\n' "$key" "$val" >> "$T/config.env"
    ctl_once
    assert_eq "$RC" 2 "exit code for ${bad}"
    grep -q "event=config_invalid" "$T/out" || { echo "    no config_invalid for ${bad}: $(head -3 "$T/out")" >&2; return 1; }
    cp "$T/config.bad" "$T/config.env"
  done
  assert_eq "$(calls_to .)" 0 "an invalid config never reaches the network"
}

test_config_unparsable_line_and_unknown_key() {
  setup_ctl
  echo 'echo hacked > /tmp/ghr-hacked' >> "$T/config.env"
  ctl_once; assert_eq "$RC" 2
  assert_fail "a config line is never executed" test -e /tmp/ghr-hacked
  sed -i '$d' "$T/config.env"; echo 'GH_FUTURE_KEY=1' >> "$T/config.env"
  repos_fx; none_runners_for
  ctl_once
  grep -q "event=config_unknown_key key=GH_FUTURE_KEY" "$T/out" || return 1
}

test_config_accepts_quoted_values_and_comments() {
  setup_ctl
  { echo '# comment'; echo ''; echo 'GH_EXCLUDE_REPOS="one,octo/two"'; echo 'GH_LABELS="self-hosted,linux,arm64,hetzner"'; } >> "$T/config.env"
  repos_fx "$(repo_json a true private false)"; none_runners_for a
  fx GET '/repos/octo/a/actions/runs?status=queued&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  fx GET '/repos/octo/a/actions/runs?status=in_progress&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  ctl_once; assert_eq "$RC" 0
}

# ---- JWT --------------------------------------------------------------------------------------------------------------------------
b64url_decode() { local s=${1//-/+}; s=${s//_//}; while (( ${#s} % 4 )); do s+="="; done; printf '%s' "$s" | base64 -d; }

test_jwt_claims_and_signature() {
  setup_ctl
  repos_fx; none_runners_for
  ctl_once
  local jwt h p sig
  jwt=$(cat "$T/log/auth.$(fxkey POST /app/installations/42/access_tokens)")
  IFS=. read -r h p sig <<<"$jwt"
  assert_eq "$(b64url_decode "$h" | jq -cS .)" '{"alg":"RS256","typ":"JWT"}' "header"
  local now iat exp
  now=$(date +%s); iat=$(b64url_decode "$p" | jq -r .iat); exp=$(b64url_decode "$p" | jq -r .exp)
  assert_eq "$(b64url_decode "$p" | jq -r .iss)" Iv1.testclient "iss is the client id"
  (( iat >= now - 70 && iat <= now - 50 )) || { echo "    iat ${iat} is not now-60 (now ${now})" >&2; return 1; }
  (( exp > now && exp - now <= 600 )) || { echo "    exp ${exp} is not within 10 minutes" >&2; return 1; }
  assert_eq "$(b64url_decode "$p" | jq -r 'keys | join(",")')" "exp,iat,iss" "only the three claims"
  openssl rsa -in "$T/app.pem" -pubout -out "$T/pub.pem" 2>/dev/null
  b64url_decode "$sig" > "$T/sig.bin"
  printf '%s' "$h.$p" | openssl dgst -sha256 -verify "$T/pub.pem" -signature "$T/sig.bin" >/dev/null || { echo "    signature does not verify" >&2; return 1; }
}

test_jwt_failure_with_a_bad_key_is_logged_without_the_key() {
  setup_ctl
  echo "not a key" > "$T/app.pem"
  ctl_once
  assert_eq "$RC" 1
  grep -q "event=jwt_failed" "$T/out" || { cat "$T/out" >&2; return 1; }
}

test_installation_id_is_discovered_when_not_configured() {
  setup_ctl
  sed -i '/^GH_INSTALLATION_ID=/d' "$T/config.env"
  fx GET /users/octo/installation 200 '{"id":42}'
  repos_fx; none_runners_for
  ctl_once; assert_eq "$RC" 0
  grep -q "event=installation_discovered installation=42" "$T/out" || return 1
  assert_eq "$(calls_to 'GET /users/octo/installation 200 auth')" 1
}

# ---- which repositories are served -------------------------------------------------------------------------------------------------
repos_matrix() {
  repos_fx "$(repo_json ok true private false)" "$(repo_json pub false public false)" "$(repo_json arch true private true)" \
           "$(repo_json inter true internal false)" "$(repo_json skipme true private false)" "$(repo_json stranger true private false other)" \
           '{"full_name":"octo/nofields","owner":{"login":"octo"},"private":true}'
  none_runners_for ok pub arch inter skipme nofields
}

test_only_private_unarchived_unexcluded_repositories_are_served() {
  setup_ctl
  echo 'GH_EXCLUDE_REPOS=skipme' >> "$T/config.env"
  repos_matrix
  local k
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","linux","arm64","hetzner"]')]}"
  jit_fx ok 555
  # a queued job in every refused repository would be taken if the repository were served
  for k in pub arch inter skipme nofields; do
    queued_fx "$k" 8 "{\"jobs\":[$(job_json 80 queued null '["self-hosted","hetzner"]')]}"
    jit_fx "$k" 556
  done
  ctl_once; assert_eq "$RC" 0
  assert_eq "$(calls_to 'POST /repos/octo/ok/actions/runners/generate-jitconfig')" 1 "the private repository gets a runner"
  assert_eq "$(calls_to 'generate-jitconfig')" 1 "no other repository gets one"
  assert_eq "$(calls_to '/repos/octo/\(pub\|arch\|inter\|skipme\|nofields\)/actions/runs')" 0 "refused repositories are not even polled for runs"
  assert_eq "$(jq -r '"\(.served) \(.skipped)"' "$T/state/status.json")" "1 6" "status counts"
}

test_self_test_lists_repositories_and_starts_nothing() {
  setup_ctl
  echo 'GH_EXCLUDE_REPOS=skipme' >> "$T/config.env"
  repos_matrix
  fx GET /app 200 '{"name":"Hetzner runner","slug":"hetzner-runner","permissions":{"administration":"write","actions":"read","metadata":"read"},"events":[]}'
  jit_fx ok 555
  local rc=0
  bash "$CTL" self-test > "$T/out" 2>&1 || rc=$?
  assert_eq "$rc" 0
  grep -q "SERVE  octo/ok (private)" "$T/out" || { cat "$T/out" >&2; return 1; }
  grep -q "SKIP   octo/pub (public)" "$T/out" || return 1
  grep -q "SKIP   octo/arch (archived)" "$T/out" || return 1
  grep -q "SKIP   octo/inter (visibility-internal)" "$T/out" || return 1
  grep -q "SKIP   octo/skipme (excluded)" "$T/out" || return 1
  grep -q "SKIP   other/stranger (other-owner)" "$T/out" || return 1
  grep -q "SKIP   octo/nofields (visibility-unknown)" "$T/out" || return 1
  assert_eq "$(calls_to 'generate-jitconfig')" 0 "self-test creates no runner"
  assert_eq "$(calls_to 'DELETE')" 0 "self-test deletes nothing"
  assert_fail "self-test starts no container" test -f "$T/log/docker.log"
  no_secrets_in "$T/out"
}

test_self_test_fails_when_the_app_lacks_a_permission() {
  setup_ctl
  repos_fx "$(repo_json ok true private false)"
  fx GET /app 200 '{"name":"n","slug":"s","permissions":{"administration":"read","actions":"read","metadata":"read"}}'
  local rc=0
  bash "$CTL" self-test > "$T/out" 2>&1 || rc=$?
  assert_eq "$rc" 1
  grep -q "FAIL  permission administration: read (needs write)" "$T/out" || { cat "$T/out" >&2; return 1; }
}

# ---- runners that must not exist -----------------------------------------------------------------------------------------------------
test_runners_of_a_repository_turned_public_archived_or_excluded_are_deleted() {
  setup_ctl
  echo 'GH_EXCLUDE_REPOS=skipme' >> "$T/config.env"
  local p; p=$(host_prefix)
  repos_fx "$(repo_json ok true private false)" "$(repo_json pub false public false)" "$(repo_json arch true private true)" "$(repo_json skipme true private false)"
  runners_fx ok '{"runners":[]}'
  local r
  for r in pub arch skipme; do
    runners_fx "$r" "{\"runners\":[{\"id\":9$RANDOM,\"name\":\"${p}111\",\"status\":\"online\",\"busy\":false},{\"id\":8$RANDOM,\"name\":\"someone-elses-runner\",\"status\":\"online\",\"busy\":false}]}"
  done
  # known ids make the assertions exact
  runners_fx pub "{\"runners\":[{\"id\":901,\"name\":\"${p}111\",\"status\":\"online\",\"busy\":false},{\"id\":902,\"name\":\"someone-elses-runner\",\"status\":\"online\",\"busy\":false}]}"
  runners_fx arch "{\"runners\":[{\"id\":911,\"name\":\"${p}222\",\"status\":\"offline\",\"busy\":false}]}"
  runners_fx skipme "{\"runners\":[{\"id\":921,\"name\":\"${p}333\",\"status\":\"online\",\"busy\":true}]}"
  fx DELETE /repos/octo/pub/actions/runners/901 204 ''
  fx DELETE /repos/octo/arch/actions/runners/911 204 ''
  fx DELETE /repos/octo/skipme/actions/runners/921 204 ''
  fx GET '/repos/octo/ok/actions/runs?status=queued&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  fx GET '/repos/octo/ok/actions/runs?status=in_progress&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  ctl_once; assert_eq "$RC" 0
  assert_eq "$(calls_to 'DELETE /repos/octo/pub/actions/runners/901 204')" 1 "public repo: our runner deleted"
  assert_eq "$(calls_to 'DELETE /repos/octo/arch/actions/runners/911 204')" 1 "archived repo: our runner deleted"
  assert_eq "$(calls_to 'DELETE /repos/octo/skipme/actions/runners/921 204')" 1 "excluded repo: our runner deleted"
  assert_eq "$(calls_to 'DELETE /repos/octo/pub/actions/runners/902')" 0 "a runner that is not ours is never touched"
  grep -q "event=runner_deleted repo=octo/pub runner=901 reason=repo_not_served" "$T/out" || { cat "$T/out" >&2; return 1; }
}

test_orphan_runner_of_a_served_repository_is_deleted_but_a_pod_runner_is_kept() {
  setup_ctl
  local p now; p=$(host_prefix); now=$(date +%s)
  repos_fx "$(repo_json ok true private false)"
  runners_fx ok "{\"runners\":[{\"id\":31,\"name\":\"${p}a\",\"status\":\"offline\",\"busy\":false},{\"id\":32,\"name\":\"${p}b\",\"status\":\"online\",\"busy\":false},{\"id\":33,\"name\":\"${p}c\",\"status\":\"online\",\"busy\":true}]}"
  fx DELETE /repos/octo/ok/actions/runners/31 204 ''
  fx DELETE /repos/octo/ok/actions/runners/32 204 ''
  # runner 33 belongs to a running pod of this host
  echo "ghr-${now}-aaaaaa-runner|running|runner|${now}-aaaaaa|octo/ok|33|${now}" > "$T/log/ps.txt"
  fx GET /repos/octo/ok/actions/runners/33 200 '{"id":33,"busy":true}'
  ctl_once; assert_eq "$RC" 0
  assert_eq "$(calls_to 'DELETE /repos/octo/ok/actions/runners/31 204')" 1 "offline orphan deleted"
  assert_eq "$(calls_to 'DELETE /repos/octo/ok/actions/runners/32 204')" 1 "idle orphan deleted"
  assert_eq "$(calls_to 'DELETE /repos/octo/ok/actions/runners/33')" 0 "the runner of a live pod is kept"
}

# ---- capacity and job matching ------------------------------------------------------------------------------------------------------------
test_max_jobs_is_respected() {
  setup_ctl
  local now; now=$(date +%s)
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"; jit_fx ok 555
  echo "ghr-${now}-aaaaaa-runner|running|runner|${now}-aaaaaa|octo/ok|600|${now}" > "$T/log/ps.txt"
  fx GET /repos/octo/ok/actions/runners/600 200 '{"id":600,"busy":true}'
  ctl_once; assert_eq "$RC" 0
  assert_eq "$(calls_to 'generate-jitconfig')" 0 "one pod runs and GH_MAX_JOBS=1: no second runner"
  assert_eq "$(calls_to 'status=queued')" 0 "a full host does not poll for work (saves quota)"
}

test_one_pod_per_queued_job_up_to_max_jobs() {
  setup_ctl
  echo 'GH_MAX_JOBS=2' >> "$T/config.env"
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]'),$(job_json 71 queued null '["self-hosted","hetzner"]'),$(job_json 72 queued null '["self-hosted","hetzner"]')]}"
  jit_fx ok 555
  ctl_once; assert_eq "$RC" 0
  assert_eq "$(calls_to 'POST /repos/octo/ok/actions/runners/generate-jitconfig')" 2 "three queued jobs, two slots"
}

test_an_idle_pod_covers_a_queued_job() {
  setup_ctl
  echo 'GH_MAX_JOBS=3' >> "$T/config.env"
  local now; now=$(date +%s)
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"; jit_fx ok 555
  echo "ghr-${now}-aaaaaa-runner|running|runner|${now}-aaaaaa|octo/ok|600|${now}" > "$T/log/ps.txt"
  fx GET /repos/octo/ok/actions/runners/600 200 '{"id":600,"busy":false}'
  ctl_once; assert_eq "$RC" 0
  assert_eq "$(calls_to 'generate-jitconfig')" 0 "a runner that waits for a job is not duplicated"
}

test_label_matching() {
  setup_ctl
  echo 'GH_MAX_JOBS=20' >> "$T/config.env"
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[
    $(job_json 1 queued null '["self-hosted","linux"]'),
    $(job_json 2 queued null '["self-hosted","hetzner","gpu"]'),
    $(job_json 3 queued null '["ubuntu-latest"]'),
    $(job_json 4 queued null '["Self-Hosted","HETZNER"]'),
    $(job_json 5 in_progress 9 '["self-hosted","hetzner"]'),
    $(job_json 6 queued 9 '["self-hosted","hetzner"]'),
    $(job_json 7 queued null '["self-hosted","linux","arm64","hetzner"]'),
    $(job_json 8 queued null '[]'),
    $(job_json 9 queued null '["self-hosted","x64","hetzner"]')
  ]}"
  jit_fx ok 555
  ctl_once; assert_eq "$RC" 0
  # taken: 4 (case-insensitive subset with the custom label) and 7 (all our labels). Not taken: no custom label, an extra label we do not
  # have, a hosted-runner job, a job that is not queued or already has a runner, no labels, another architecture.
  assert_eq "$(calls_to 'POST /repos/octo/ok/actions/runners/generate-jitconfig')" 2
  grep -q 'job=4' "$T/out" && grep -q 'job=7' "$T/out" || { cat "$T/out" >&2; return 1; }
}

test_fork_pull_request_runs_are_skipped_unless_allowed() {
  setup_ctl
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}" pull_request stranger/ok; jit_fx ok 555
  ctl_once; assert_eq "$RC" 0
  assert_eq "$(calls_to 'generate-jitconfig')" 0 "a pull request from a fork does not get a runner"
  assert_eq "$(calls_to 'actions/runs/7/jobs')" 0 "its jobs are not even read"
  rm -f "$T/log/curl.log"; echo 'GH_ALLOW_FORK_RUNS=1' >> "$T/config.env"
  ctl_once; assert_eq "$(calls_to 'generate-jitconfig')" 1 "allowed on request"
  # a pull request from the same repository is normal work
  rm -f "$T/log/curl.log" "$T/log/run."* "$T/log/docker.log"; sed -i '/^GH_ALLOW_FORK_RUNS=/d' "$T/config.env"
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}" pull_request octo/ok
  ctl_once; assert_eq "$(calls_to 'generate-jitconfig')" 1 "same-repository pull request"
}

# ---- the pod ------------------------------------------------------------------------------------------------------------------------------
test_pod_is_locked_down_and_the_jit_config_is_not_in_argv() {
  setup_ctl
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"; jit_fx ok 555
  ctl_once; assert_eq "$RC" 0
  local bk=$T/log/run.0 rn=$T/log/run.1 net
  [[ -f $bk && -f $rn ]] || { cat "$T/log/docker.log" >&2; return 1; }
  grep -qx -- "--name" "$bk" || return 1
  local all; all=$(cat "$bk" "$rn")
  grep -q 'privileged' <<<"$all" && { echo "    --privileged found" >&2; return 1; }
  grep -q 'docker.sock' <<<"$all" && { echo "    docker socket found" >&2; return 1; }
  # runner container
  grep -qx -- '--user' "$rn" && grep -qx '1001:1001' "$rn" || return 1
  grep -qx 'no-new-privileges' "$rn" && grep -qx 'ALL' "$rn" && grep -qx -- '--cap-drop' "$rn" || return 1
  grep -qx -- '--pids-limit' "$rn" && grep -qx -- '--cgroup-parent' "$rn" && grep -qx 'ci-jobs.slice' "$rn" || return 1
  grep -qx -- '--cpus' "$rn" && grep -qx '1.5' "$rn" && grep -qx '1536m' "$rn" || return 1
  grep -qx 'io.server-init.github-runner=job' "$rn" || return 1
  grep -qx 'io.server-init.github-runner.repo=octo/ok' "$rn" || return 1
  grep -qx 'io.server-init.github-runner.run-id=7' "$rn" || return 1
  grep -qx 'io.server-init.github-runner.runner-id=555' "$rn" || return 1
  grep -q '^--rm$' "$rn" && { echo "    runner must not be --rm (its exit code is read)" >&2; return 1; }
  # buildkit sidecar
  grep -qx -- '--rm' "$bk" && grep -qx 'seccomp=unconfined' "$bk" && grep -qx 'systempaths=unconfined' "$bk" || return 1
  grep -qx -- '--tlscacert' "$bk" && grep -qx -- '--tlskey' "$bk" && grep -qx 'tcp://0.0.0.0:1234' "$bk" || return 1
  grep -qx 'buildkitd' "$bk" || return 1
  grep -q ':ro' "$bk" && grep -q 'tls-srv' "$bk" && ! grep -q 'tls-cli' "$bk" || { echo "    sidecar mounts" >&2; return 1; }
  grep -q 'tls-cli' "$rn" && ! grep -q 'tls-srv' "$rn" || { echo "    runner mounts" >&2; return 1; }
  # same network, default bridge naming: no custom bridge name, not internal
  net=$(grep -E '^network create' "$T/log/docker.log")
  grep -q 'com.docker.network.bridge.name' <<<"$net" && { echo "    custom bridge name" >&2; return 1; }
  grep -q -- '--internal' <<<"$net" && { echo "    internal network" >&2; return 1; }
  # the entry runs the Listener itself (run.sh would hide its exit code) and reads the JIT config from the mounted file
  grep -q 'exec ./bin/Runner.Listener run' "$rn" || { echo "    entry does not exec Runner.Listener" >&2; return 1; }
  grep -qE '(^|[^.])run\.sh' "$rn" && { echo "    entry still uses run.sh" >&2; return 1; }
  grep -q 'ACTIONS_RUNNER_INPUT_JITCONFIG=\$J' "$rn" && grep -q 'cat /run/ghr-jit/config' "$rn" || return 1
  # secrets: the JIT config is in a file below a 0700 directory, never in argv or in the output
  no_secrets_in "$T/out" "$bk" "$rn" "$T/log/docker.log"
  assert_eq "$(stat -c %a "$T/state/jobs")" 700
  local jit; jit=$(ls "$T"/state/jobs/*/jit/config)
  assert_eq "$(cat "$jit")" "$JITMARK" "the JIT config is in the file"
  assert_eq "$(jq -r '.labels | join(",")' "$T/log/request.$(fxkey POST /repos/octo/ok/actions/runners/generate-jitconfig)")" "self-hosted,linux,arm64,hetzner"
  assert_eq "$(jq -r '.runner_group_id' "$T/log/request.$(fxkey POST /repos/octo/ok/actions/runners/generate-jitconfig)")" 1
  [[ ! -e $(dirname "$jit")/../ca ]] || { echo "    CA key directory left behind" >&2; return 1; }
}

test_buildkit_can_be_switched_off() {
  setup_ctl
  echo 'GH_BUILDKIT=0' >> "$T/config.env"
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"; jit_fx ok 555
  ctl_once; assert_eq "$RC" 0
  assert_eq "$(ls "$T"/log/run.* | wc -l)" 1 "only the runner container"
  assert_fail "no certificates" ls "$T"/state/jobs/*/tls-srv
}

test_jit_failure_422_names_the_group_variable_and_cleans_up() {
  setup_ctl
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"
  fx POST /repos/octo/ok/actions/runners/generate-jitconfig 422 '{"message":"Validation Failed"}'
  ctl_once
  grep -q "event=jit_failed" "$T/out" && grep -q "GH_RUNNER_GROUP_ID" "$T/out" || { cat "$T/out" >&2; return 1; }
  assert_fail "no container started" test -f "$T/log/run.0"
  assert_eq "$(ls "$T"/state/jobs | wc -l)" 0 "pod directory removed"
  assert_eq "$RC" 1 "a failed poll is reported"
}

test_pod_start_failure_removes_the_runner_and_everything_else() {
  setup_ctl
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"; jit_fx ok 555
  fx DELETE /repos/octo/ok/actions/runners/555 204 ''
  # docker run fails for the runner container
  cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GHR_TEST_LOG/docker.log"
case "$1" in
  run) [[ "$*" == *--user* ]] && exit 1 ;;
esac
exit 0
STUB
  ctl_once
  grep -q "event=pod_start_failed.*step=runner" "$T/out" || { cat "$T/out" >&2; return 1; }
  assert_eq "$(calls_to 'DELETE /repos/octo/ok/actions/runners/555 204')" 1 "the JIT runner is deleted again"
  grep -q '^network rm ghr-' "$T/log/docker.log" || return 1
  assert_eq "$(ls "$T"/state/jobs | wc -l)" 0
}

# ---- life cycle of pods -------------------------------------------------------------------------------------------------------------------
test_exit_code_4_means_the_pinned_image_is_too_old() {
  setup_ctl
  local now; now=$(date +%s)
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  fx GET '/repos/octo/ok/actions/runs?status=queued&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  fx GET '/repos/octo/ok/actions/runs?status=in_progress&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  echo "ghr-$((now - 1000))-aaaaaa-runner|exited|runner|$((now - 1000))-aaaaaa|octo/ok|600|$((now - 1000))" > "$T/log/ps.txt"
  echo "4 false" > "$T/log/inspect.txt"
  fx DELETE /repos/octo/ok/actions/runners/600 404 '{}'
  mkdir -p "$T/state/jobs/$((now - 1000))-aaaaaa"
  ctl_once
  grep -q "event=runner_update_required.*exit=4.*Bump GHR_RUNNER_IMAGE" "$T/out" || { cat "$T/out" >&2; return 1; }
  assert_eq "$(jq -r .update_required "$T/state/status.json")" true
  assert_eq "$(jq -r .consecutive_failures "$T/state/status.json")" 1
  grep -q "^rm -f ghr-$((now - 1000))-aaaaaa-runner" "$T/log/docker.log" || { cat "$T/log/docker.log" >&2; return 1; }
  assert_fail "pod directory removed" test -e "$T/state/jobs/$((now - 1000))-aaaaaa"
  # a later clean exit clears the flag
  echo "0 false" > "$T/log/inspect.txt"
  ctl_once
  assert_eq "$(jq -r .update_required "$T/state/status.json")" false
  assert_eq "$(jq -r .consecutive_failures "$T/state/status.json")" 0
}

test_a_quick_runner_failure_pauses_new_pods() {
  setup_ctl
  local now; now=$(date +%s)
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"; jit_fx ok 555
  echo "ghr-${now}-aaaaaa-runner|exited|runner|${now}-aaaaaa|octo/ok|600|$((now - 20))" > "$T/log/ps.txt"
  echo "1 false" > "$T/log/inspect.txt"
  ctl_once
  grep -q "event=pod_start_paused" "$T/out" || { cat "$T/out" >&2; return 1; }
  assert_eq "$(calls_to 'generate-jitconfig')" 0 "no new runner during the pause"
  (( $(jq -r .backoff_until "$T/state/status.json") > now )) || return 1
}

test_idle_pod_is_killed_after_the_idle_timeout_and_its_runner_deleted() {
  setup_ctl
  local now; now=$(date +%s)
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  fx GET '/repos/octo/ok/actions/runs?status=queued&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  fx GET '/repos/octo/ok/actions/runs?status=in_progress&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  echo "ghr-$((now - 700))-aaaaaa-runner|running|runner|$((now - 700))-aaaaaa|octo/ok|600|$((now - 700))" > "$T/log/ps.txt"
  fx GET /repos/octo/ok/actions/runners/600 200 '{"id":600,"busy":false}'
  fx DELETE /repos/octo/ok/actions/runners/600 204 ''
  ctl_once
  grep -q "event=pod_killed.*reason=idle_timeout" "$T/out" || { cat "$T/out" >&2; return 1; }
  grep -q "^kill ghr-$((now - 700))-aaaaaa-runner" "$T/log/docker.log" || return 1
  assert_eq "$(calls_to 'DELETE /repos/octo/ok/actions/runners/600 204')" 1
}

test_busy_pod_is_not_killed_even_when_old() {
  setup_ctl
  local now; now=$(date +%s)
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  echo "ghr-$((now - 700))-aaaaaa-runner|running|runner|$((now - 700))-aaaaaa|octo/ok|600|$((now - 700))" > "$T/log/ps.txt"
  fx GET /repos/octo/ok/actions/runners/600 200 '{"id":600,"busy":true}'
  ctl_once; assert_eq "$RC" 0
  assert_fail "not killed" grep -q '^kill' "$T/log/docker.log"
  grep -q "event=job_started" "$T/out" || return 1
  test -e "$T/state/jobs/$((now - 700))-aaaaaa/busy" || return 1
}

test_unknown_busy_state_does_not_kill() {
  setup_ctl
  local now; now=$(date +%s)
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  echo "ghr-$((now - 700))-aaaaaa-runner|running|runner|$((now - 700))-aaaaaa|octo/ok|600|$((now - 700))" > "$T/log/ps.txt"
  fx GET /repos/octo/ok/actions/runners/600 502 '{"message":"Bad Gateway"}'
  ctl_once
  assert_fail "GitHub errors are not 'idle'" grep -q '^kill' "$T/log/docker.log"
}

test_pod_beyond_max_runtime_is_killed() {
  setup_ctl
  local now; now=$(date +%s)
  echo 'GH_MAX_RUNTIME=600' >> "$T/config.env"
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  echo "ghr-$((now - 5000))-aaaaaa-runner|running|runner|$((now - 5000))-aaaaaa|octo/ok|600|$((now - 5000))" > "$T/log/ps.txt"
  fx DELETE /repos/octo/ok/actions/runners/600 422 '{"message":"Runner is busy"}'
  ctl_once
  grep -q "event=pod_killed.*reason=max_runtime" "$T/out" || { cat "$T/out" >&2; return 1; }
}

test_leftover_network_and_directory_without_a_pod_are_removed() {
  setup_ctl
  local now; now=$(date +%s)
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  fx GET '/repos/octo/ok/actions/runs?status=queued&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  fx GET '/repos/octo/ok/actions/runs?status=in_progress&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  echo "${now}-bbbbbb|10.213.0.0/28" > "$T/log/nets.txt"
  mkdir -p "$T/state/jobs/${now}-bbbbbb/jit" "$T/state/jobs/${now}-cccccc/jit" "$T/state/jobs/not-a-pod"
  echo secret > "$T/state/jobs/${now}-cccccc/jit/config"
  ctl_once; assert_eq "$RC" 0
  grep -q "^network rm ghr-${now}-bbbbbb" "$T/log/docker.log" || { cat "$T/log/docker.log" >&2; return 1; }
  assert_fail "leftover directory removed" test -e "$T/state/jobs/${now}-cccccc"
  test -d "$T/state/jobs/not-a-pod" || { echo "    a directory that is not a pod id was removed" >&2; return 1; }
}

test_running_pod_is_adopted_after_a_controller_restart() {
  setup_ctl
  local now; now=$(date +%s)
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  echo "ghr-${now}-aaaaaa-runner|running|runner|${now}-aaaaaa|octo/ok|600|${now}
ghr-${now}-aaaaaa-buildkitd|running|buildkit|${now}-aaaaaa|octo/ok||${now}" > "$T/log/ps.txt"
  fx GET /repos/octo/ok/actions/runners/600 200 '{"id":600,"busy":true}'
  ctl_once; assert_eq "$RC" 0
  assert_eq "$(jq -r .active_pods "$T/state/status.json")" 1
  assert_fail "nothing removed" grep -qE '^(rm|kill|network rm)' "$T/log/docker.log"
}

# ---- API behavior, status, secrets ----------------------------------------------------------------------------------------------------------
test_conditional_requests_are_sent_and_304_is_served_from_the_cache() {
  setup_ctl
  ETAG='W/"abc"' repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"
  fx GET '/repos/octo/ok/actions/runs?status=queued&per_page=50&page=1' 200 '{"workflow_runs":[]}' 'W/"q1"'
  ctl_once; assert_eq "$RC" 0
  rm -f "$T/log/curl.log"
  ctl_once; assert_eq "$RC" 0
  grep -q 'GET /installation/repositories?per_page=100&page=1 304 auth if-none-match' "$T/log/curl.log" || { cat "$T/log/curl.log" >&2; return 1; }
  grep -q 'actions/runs?status=queued&per_page=50&page=1 304' "$T/log/curl.log" || return 1
  grep -q '^MISSING' "$T/log/curl.log" && { cat "$T/log/curl.log" >&2; return 1; }
  assert_eq "$(jq -r .served "$T/state/status.json")" 1 "a 304 still yields the repository list"
}

test_the_token_is_cached_between_polls() {
  setup_ctl
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  fx GET '/repos/octo/ok/actions/runs?status=queued&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  fx GET '/repos/octo/ok/actions/runs?status=in_progress&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  # two polls in one process
  bash -c 'source "$1"; common_start; init_dirs; STARTED_AT=0; tick; tick' _ "$CTL" > "$T/out" 2>&1
  assert_eq "$(calls_to 'POST /app/installations/42/access_tokens 201')" 1 "one installation token for two polls"
  assert_eq "$(calls_to 'POST /app/installations/42/access_tokens#repo 201')" 1 "and one token for the repository, used by both polls"
}

test_status_file_for_health() {
  setup_ctl
  repos_fx "$(repo_json ok true private false)" "$(repo_json pub false public false)"; none_runners_for ok pub
  fx GET '/repos/octo/ok/actions/runs?status=queued&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  fx GET '/repos/octo/ok/actions/runs?status=in_progress&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  GHR_TEST_RL=4321 ctl_once; assert_eq "$RC" 0
  local s="$T/state/status.json" now; now=$(date +%s)
  assert_eq "$(jq -r '.rate_remaining' "$s")" 4321
  assert_eq "$(jq -r '.rate_limit' "$s")" 5000
  assert_eq "$(jq -r '"\(.served) \(.skipped) \(.active_pods) \(.max_jobs) \(.update_required)"' "$s")" "1 1 0 1 false"
  (( $(jq -r .last_poll_ok "$s") >= now - 5 )) || return 1
  (( $(jq -r .last_token_ok "$s") >= now - 5 )) || return 1
  assert_eq "$(jq -r .installation "$s")" 42
  assert_eq "$(stat -c %a "$s")" 644
}

test_failed_poll_is_recorded_and_the_last_ok_time_stays() {
  setup_ctl
  fx POST /app/installations/42/access_tokens 401 '{"message":"Bad credentials"}'
  ctl_once; assert_eq "$RC" 1
  assert_eq "$(jq -r .last_poll_ok "$T/state/status.json")" 0
  jq -r .last_error "$T/state/status.json" | grep -q "token_failed: http 401 Bad credentials" || { cat "$T/state/status.json" >&2; return 1; }
  grep -q "level=error event=token_failed" "$T/out" || return 1
}

test_low_rate_limit_stops_discovery_but_still_manages_pods() {
  setup_ctl
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"; jit_fx ok 555
  GHR_TEST_RL=50 ctl_once
  grep -q "event=discovery_paused reason=rate_limit" "$T/out" || { cat "$T/out" >&2; return 1; }
  assert_eq "$(calls_to 'generate-jitconfig')" 0
}

test_nothing_secret_reaches_the_output_or_the_process_arguments() {
  setup_ctl
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"; jit_fx ok 555
  ctl_once; assert_eq "$RC" 0
  no_secrets_in "$T/out" "$T/log/docker.log" "$T/log/curl.log" "$T"/log/run.*
  # the authorization header is passed on stdin (curl -K -), never as an argument
  grep -q "Authorization" "$T/log/curl.log" && { echo "    a header is in the curl arguments log" >&2; return 1; }
  # nothing but the pod's own files holds the JIT config
  assert_eq "$(grep -rl "$JITMARK" "$T/state" | wc -l)" 1
  assert_eq "$(grep -rl "$TOKEN" "$T/state" | wc -l)" 0 "the installation token is only in memory"
}

test_error_text_from_github_is_scrubbed_of_the_token() {
  setup_ctl
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"
  fx POST /repos/octo/ok/actions/runners/generate-jitconfig 500 "{\"message\":\"boom $TOKEN\"}"
  ctl_once
  grep -q "event=jit_failed" "$T/out" || return 1
  no_secrets_in "$T/out"
}

# ---- certificates -----------------------------------------------------------------------------------------------------------------------
test_ephemeral_tls_for_buildkit() {
  # shellcheck source=/dev/null
  source "$CTL"
  local d="$T/pod"
  install -d "$d"
  gen_tls "$d"
  assert_fail "the CA key is gone" test -e "$d/ca"
  assert_ok "server cert verifies against the CA" openssl verify -CAfile "$d/tls-srv/ca.pem" "$d/tls-srv/cert.pem"
  assert_ok "client cert verifies against the same CA" openssl verify -CAfile "$d/tls-cli/ca.pem" "$d/tls-cli/cert.pem"
  openssl x509 -in "$d/tls-srv/cert.pem" -noout -ext subjectAltName | grep -q 'DNS:buildkitd' || return 1
  openssl x509 -in "$d/tls-srv/cert.pem" -noout -ext extendedKeyUsage | grep -q 'TLS Web Server' || return 1
  openssl x509 -in "$d/tls-cli/cert.pem" -noout -ext extendedKeyUsage | grep -q 'TLS Web Client' || return 1
  # each side holds only its own key
  assert_eq "$(ls "$d/tls-srv" | sort | tr '\n' ' ')" "ca.pem cert.pem key.pem "
  assert_eq "$(ls "$d/tls-cli" | sort | tr '\n' ' ')" "ca.pem cert.pem key.pem "
  ! cmp -s "$d/tls-srv/key.pem" "$d/tls-cli/key.pem" || return 1
  # the validity is days, not years
  openssl x509 -in "$d/tls-srv/cert.pem" -noout -checkend $((3 * 86400)) >/dev/null && return 1
  return 0
}

# ---- pod networks: the dedicated pool -----------------------------------------------------------------------------------------------------
queue_one() { # a repository with one queued job for us
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"; jit_fx ok 555
}

test_pod_network_gets_the_first_free_range_of_the_pool() {
  setup_ctl
  queue_one
  ctl_once; assert_eq "$RC" 0
  assert_eq "$(cat "$T/log/created-subnets.txt")" "10.213.0.0/28" "first /28 of the default pool"
  grep -qE '^network create --subnet 10.213.0.0/28 --label io.server-init.github-runner.subnet=10.213.0.0/28 ' "$T/log/docker.log" || { grep '^network create' "$T/log/docker.log" >&2; return 1; }
  grep -q 'event=pod_started.* subnet=10.213.0.0/28' "$T/out" || return 1
}

test_ranges_in_use_are_not_reused_and_a_released_range_is_taken_again() {
  setup_ctl
  local now; now=$(date +%s)
  # two pods exist (their networks carry the subnet label); GH_MAX_JOBS=3 leaves room for a third
  echo 'GH_MAX_JOBS=3' >> "$T/config.env"
  queue_one
  printf '%s\n' "${now}-aaaaaa|10.213.0.0/28" "${now}-bbbbbb|10.213.0.16/28" > "$T/log/nets.txt"
  printf '%s\n' "ghr-${now}-aaaaaa-runner|running|runner|${now}-aaaaaa|octo/other|601|${now}" "ghr-${now}-bbbbbb-runner|running|runner|${now}-bbbbbb|octo/other|602|${now}" > "$T/log/ps.txt"
  fx GET /repos/octo/other/actions/runners/601 200 '{"busy":true}'; fx GET /repos/octo/other/actions/runners/602 200 '{"busy":true}'
  ctl_once; assert_eq "$RC" 0
  assert_eq "$(cat "$T/log/created-subnets.txt")" "10.213.0.32/28" "no reuse while in use"
  # pod a ends: its network is gone, the range is free and the lowest one again
  rm -f "$T/log/created-subnets.txt" "$T/log/run."* "$T/log/curl.log"
  printf '%s\n' "${now}-bbbbbb|10.213.0.16/28" > "$T/log/nets.txt"
  printf '%s\n' "ghr-${now}-bbbbbb-runner|running|runner|${now}-bbbbbb|octo/other|602|${now}" > "$T/log/ps.txt"
  ctl_once
  assert_eq "$(cat "$T/log/created-subnets.txt")" "10.213.0.0/28" "released range reused"
}

test_pool_exhaustion_is_a_clear_error_and_the_job_stays_queued() {
  setup_ctl
  local now; now=$(date +%s)
  # a /27 pool holds two /28 ranges
  { echo 'GH_JOB_SUBNET_POOL=10.213.0.0/27'; echo 'GH_MAX_JOBS=5'; } >> "$T/config.env"
  queue_one
  printf '%s\n' "${now}-aaaaaa|10.213.0.0/28" "${now}-bbbbbb|10.213.0.16/28" > "$T/log/nets.txt"
  printf '%s\n' "ghr-${now}-aaaaaa-runner|running|runner|${now}-aaaaaa|octo/other|601|${now}" "ghr-${now}-bbbbbb-runner|running|runner|${now}-bbbbbb|octo/other|602|${now}" > "$T/log/ps.txt"
  fx GET /repos/octo/other/actions/runners/601 200 '{"busy":true}'; fx GET /repos/octo/other/actions/runners/602 200 '{"busy":true}'
  ctl_once
  grep -q 'level=error event=subnet_pool_exhausted pool=10.213.0.0/27 slots=2' "$T/out" || { cat "$T/out" >&2; return 1; }
  assert_eq "$(calls_to 'generate-jitconfig')" 0 "no runner is created on GitHub's side, so the job stays queued"
  assert_fail "no container" test -f "$T/log/run.0"
}

test_a_range_taken_by_another_network_is_skipped() {
  setup_ctl
  queue_one
  echo "10.213.0.0/28" > "$T/log/overlap.txt"
  ctl_once; assert_eq "$RC" 0
  assert_eq "$(cat "$T/log/created-subnets.txt")" "10.213.0.16/28"
  grep -q 'event=subnet_taken subnet=10.213.0.0/28' "$T/out" || return 1
}

test_npm_cache_is_passed_to_the_runner_only_when_installed() {
  setup_ctl
  queue_one
  # the docker0 address comes from "docker network inspect bridge" (no netlink in the unit), not from ip(8) and not from a variable
  echo 172.17.0.1 > "$T/log/bridge.txt"; export GHR_NPM_DIR="$T/npm-cache"
  ctl_once; assert_eq "$RC" 0
  assert_fail "not installed: nothing passed" grep -q 'NPM_CONFIG_REGISTRY' "$T/log/run.1"
  rm -rf "$T/log/run."* "$T/state/jobs"/*; mkdir -p "$T/npm-cache"; : > "$T/npm-cache/docker-compose.yml"
  queue_one
  ctl_once; assert_eq "$RC" 0
  grep -qx 'NPM_CONFIG_REGISTRY=http://172.17.0.1:4873/' "$T/log/run.1" || { cat "$T/log/run.1" >&2; return 1; }
  grep -qx 'YARN_NPM_REGISTRY_SERVER=http://172.17.0.1:4873/' "$T/log/run.1" || return 1
  grep -qx 'YARN_UNSAFE_HTTP_WHITELIST=172.17.0.1' "$T/log/run.1" || return 1
  assert_fail "the sidecar gets no registry" grep -q 'NPM_CONFIG_REGISTRY' "$T/log/run.0"
}

# ---- tokens, exit codes, assigned job, failures (review follow-ups) ---------------------------------------------------------------------------
test_tokens_are_scoped_to_what_each_call_needs() {
  setup_ctl
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"; jit_fx ok 555
  ctl_once; assert_eq "$RC" 0
  local main; main=$(fxkey POST /app/installations/42/access_tokens)
  assert_eq "$(jq -cS . "$T/log/request.$main")" '{"permissions":{"actions":"read"}}' "the installation-wide token only reads Actions"
  local repo; repo=$(fxkey POST '/app/installations/42/access_tokens#repo')
  assert_eq "$(jq -cS . "$T/log/request.$repo")" '{"permissions":{"administration":"write"},"repositories":["ok"]}' "the runner token is for one repository, Administration only"
  assert_eq "$(cat "$T/log/auth.$(fxkey GET '/repos/octo/ok/actions/runs?status=queued&per_page=50&page=1')")" "$TOKEN" "listing runs uses the read token"
  assert_eq "$(cat "$T/log/auth.$(fxkey GET '/installation/repositories?per_page=100&page=1')")" "$TOKEN"
  assert_eq "$(cat "$T/log/auth.$(fxkey POST /repos/octo/ok/actions/runners/generate-jitconfig)")" "$REPOTOKEN" "creating a runner uses the repository token"
  assert_eq "$(cat "$T/log/auth.$(fxkey GET '/repos/octo/ok/actions/runners?per_page=100')")" "$REPOTOKEN" "so does listing runners"
  no_secrets_in "$T/out" "$T/log/docker.log"
}

test_failed_repo_token_is_an_error_without_a_runner() {
  setup_ctl
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"; jit_fx ok 555
  fx POST '/app/installations/42/access_tokens#repo' 422 '{"message":"permissions are not granted"}'
  ctl_once
  grep -q 'event=token_failed.*repo=octo/ok.*scope=administration' "$T/out" || { cat "$T/out" >&2; return 1; }
  assert_eq "$(calls_to 'generate-jitconfig')" 0
  assert_fail "no container" test -f "$T/log/run.0"
}

test_exit_code_zero_within_two_minutes_without_a_job_is_a_failure() {
  setup_ctl
  local now; now=$(date +%s)
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"; jit_fx ok 555
  echo "ghr-${now}-aaaaaa-runner|exited|runner|${now}-aaaaaa|octo/ok|600|$((now - 30))" > "$T/log/ps.txt"
  echo "0 false" > "$T/log/inspect.txt"
  printf 'Listener failed to connect\nretrying\n' > "$T/log/logs.txt"
  ctl_once
  grep -q 'event=runner_failed.*exit=0.*job_taken=0.*why="exited after' "$T/out" || { cat "$T/out" >&2; return 1; }
  grep -q 'event=runner_log.*Listener failed to connect' "$T/out" || return 1
  grep -q 'event=pod_start_paused' "$T/out" || return 1
  assert_eq "$(calls_to 'generate-jitconfig')" 0 "no new pod during the pause"
  assert_eq "$(jq -r .consecutive_failures "$T/state/status.json")" 1
}

test_exit_code_zero_after_a_job_is_a_normal_end() {
  setup_ctl
  local now; now=$(date +%s)
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  fx GET '/repos/octo/ok/actions/runs?status=queued&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  fx GET '/repos/octo/ok/actions/runs?status=in_progress&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  echo "0 false" > "$T/log/inspect.txt"
  # a job shorter than a poll: the runner log says it ran one
  echo "ghr-${now}-aaaaaa-runner|exited|runner|${now}-aaaaaa|octo/ok|600|$((now - 30))" > "$T/log/ps.txt"
  echo "2026-11-05 12:00:00Z: Running job: build" > "$T/log/logs.txt"
  ctl_once
  grep -q 'event=job_finished' "$T/out" && ! grep -q 'event=runner_failed' "$T/out" || { cat "$T/out" >&2; return 1; }
  # a job the poll saw (busy marker)
  rm -f "$T/log/logs.txt" "$T/log/docker.log"
  mkdir -p "$T/state/jobs/${now}-bbbbbb"; echo "$now" > "$T/state/jobs/${now}-bbbbbb/busy"
  echo "ghr-${now}-bbbbbb-runner|exited|runner|${now}-bbbbbb|octo/ok|601|$((now - 30))" > "$T/log/ps.txt"
  ctl_once
  grep -q 'event=job_finished pod='"${now}-bbbbbb" "$T/out" || { cat "$T/out" >&2; return 1; }
  assert_eq "$(jq -r .consecutive_failures "$T/state/status.json")" 0
}

test_update_codes_are_failures_even_after_a_long_run() {
  setup_ctl
  local now; now=$(date +%s)
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  fx GET '/repos/octo/ok/actions/runs?status=queued&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  fx GET '/repos/octo/ok/actions/runs?status=in_progress&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  echo "ghr-$((now - 900))-aaaaaa-runner|exited|runner|$((now - 900))-aaaaaa|octo/ok|600|$((now - 900))" > "$T/log/ps.txt"
  echo "3 false" > "$T/log/inspect.txt"
  ctl_once
  grep -q 'event=runner_update_required.*exit=3' "$T/out" || return 1
  assert_eq "$(jq -r .update_required "$T/state/status.json")" true
  assert_fail "a long run is no quick failure: no pause" grep -q 'event=pod_start_paused' "$T/out"
}

# a busy pod whose job is looked up: assigned_fx REPO RUN_ID JOB_JSON [EVENT] [HEAD_REPO]
assigned_fx() {
  local ev=${4:-push} head=${5:-octo/$1}
  fx GET "/repos/octo/$1/actions/runs?status=in_progress&per_page=50&page=1" 200 "{\"workflow_runs\":[{\"id\":$2,\"event\":\"$ev\",\"repository\":{\"full_name\":\"octo/$1\"},\"head_repository\":{\"full_name\":\"$head\"}}]}"
  fx GET "/repos/octo/$1/actions/runs/$2/jobs?filter=latest&per_page=100&page=1" 200 "$3"
}
busy_pod_fixture() { # a running pod with runner 600 that GitHub reports busy
  local now; now=$(date +%s)
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  echo "ghr-${now}-aaaaaa-runner|running|runner|${now}-aaaaaa|octo/ok|600|${now}" > "$T/log/ps.txt"
  fx GET /repos/octo/ok/actions/runners/600 200 '{"id":600,"busy":true}'
  fx DELETE /repos/octo/ok/actions/runners/600 204 ''
  POD="${now}-aaaaaa"
}
job_with_runner() { # ID LABELS
  printf '{"jobs":[{"id":%s,"status":"in_progress","runner_id":600,"labels":%s}]}' "$1" "$2"
}

test_a_pod_that_got_a_fork_pull_request_is_killed() {
  setup_ctl; busy_pod_fixture
  assigned_fx ok 7 "$(job_with_runner 70 '["self-hosted","hetzner"]')" pull_request stranger/ok
  ctl_once; assert_eq "$RC" 0
  grep -q 'event=job_rejected pod='"$POD"' repo=octo/ok run=7 reason=fork' "$T/out" || { cat "$T/out" >&2; return 1; }
  grep -q "^kill ghr-${POD}-runner" "$T/log/docker.log" || return 1
  assert_eq "$(calls_to 'DELETE /repos/octo/ok/actions/runners/600 204')" 1
}

test_a_pod_that_got_foreign_labels_is_killed() {
  setup_ctl; busy_pod_fixture
  assigned_fx ok 7 "$(job_with_runner 70 '["self-hosted","gpu"]')"
  ctl_once
  grep -q 'event=job_rejected.*reason=labels' "$T/out" || { cat "$T/out" >&2; return 1; }
  grep -q "^kill ghr-${POD}-runner" "$T/log/docker.log" || return 1
}

test_a_pod_with_a_matching_job_is_accepted_once() {
  setup_ctl; busy_pod_fixture
  assigned_fx ok 7 "$(job_with_runner 70 '["self-hosted","linux","arm64","hetzner"]')" push
  ctl_once
  grep -q 'event=job_accepted' "$T/out" || { cat "$T/out" >&2; return 1; }
  assert_fail "not killed" grep -q '^kill' "$T/log/docker.log"
  test -e "$T/state/jobs/$POD/verified" || return 1
  rm -f "$T/log/curl.log"; ctl_once
  assert_eq "$(calls_to 'status=in_progress')" 0 "a verified job is not looked up again"
}

test_fork_pull_request_is_accepted_when_allowed() {
  setup_ctl; busy_pod_fixture
  echo 'GH_ALLOW_FORK_RUNS=1' >> "$T/config.env"
  assigned_fx ok 7 "$(job_with_runner 70 '["self-hosted","hetzner"]')" pull_request stranger/ok
  ctl_once
  grep -q 'event=job_accepted' "$T/out" || { cat "$T/out" >&2; return 1; }
}

test_a_job_that_is_not_visible_yet_is_looked_up_again() {
  setup_ctl; busy_pod_fixture
  assigned_fx ok 7 '{"jobs":[]}'
  ctl_once
  assert_fail "nothing decided, nothing killed" grep -qE 'job_accepted|job_rejected|^kill' "$T/out" "$T/log/docker.log"
  assert_eq "$(cat "$T/state/jobs/$POD/verify-tries")" 1
  assert_fail "not marked verified" test -e "$T/state/jobs/$POD/verified"
}

test_docker_not_answering_is_not_no_pods() {
  setup_ctl
  local now; now=$(date +%s)
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"; jit_fx ok 555
  echo "ghr-$((now - 900))-aaaaaa-runner|exited|runner|$((now - 900))-aaaaaa|octo/ok|600|$((now - 900))" > "$T/log/ps.txt"
  mkdir -p "$T/state/jobs/$((now - 900))-aaaaaa"; : > "$T/state/jobs/$((now - 900))-aaaaaa/busy"
  : > "$T/log/docker-down"
  ctl_once; assert_eq "$RC" 1
  grep -q 'event=docker_unreachable' "$T/out" || { cat "$T/out" >&2; return 1; }
  assert_fail "nothing removed, killed or started" grep -qE '^(rm|kill|network rm|run|network create)' "$T/log/docker.log"
  assert_eq "$(calls_to 'generate-jitconfig')" 0 "no runner is created on a poll where docker does not answer"
  assert_eq "$(calls_to 'DELETE')" 0 "and none is deleted"
  test -d "$T/state/jobs/$((now - 900))-aaaaaa" || { echo "    pod directory was removed" >&2; return 1; }
  jq -r .last_error "$T/state/status.json" | grep -q 'docker does not answer' || return 1
}

test_rate_limit_pause_still_finishes_and_limits_pods_without_a_request() {
  setup_ctl
  echo 'GH_MAX_RUNTIME=600' >> "$T/config.env"
  local now; now=$(date +%s)
  printf '%s\n' "ghr-$((now - 1000))-aaaaaa-runner|exited|runner|$((now - 1000))-aaaaaa|octo/ok|600|$((now - 1000))" \
                "ghr-$((now - 5000))-bbbbbb-runner|running|runner|$((now - 5000))-bbbbbb|octo/ok|601|$((now - 5000))" > "$T/log/ps.txt"
  echo "0 false" > "$T/log/inspect.txt"
  bash -c 'source "$1"; common_start; init_dirs; STARTED_AT=0; PAUSE_UNTIL=$(( $(date +%s) + 600 )); tick' _ "$CTL" > "$T/out" 2>&1
  grep -q 'event=poll_paused' "$T/out" || { cat "$T/out" >&2; return 1; }
  grep -q "^rm -f ghr-$((now - 1000))-aaaaaa-runner" "$T/log/docker.log" || { cat "$T/log/docker.log" >&2; return 1; }
  grep -q "^kill ghr-$((now - 5000))-bbbbbb-runner" "$T/log/docker.log" || return 1
  assert_eq "$(calls_to .)" 0 "not one request to GitHub while it asked us to wait"
}

test_a_forbidden_runs_listing_is_a_warning_not_a_failed_poll() {
  setup_ctl
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  fx GET '/repos/octo/ok/actions/runs?status=queued&per_page=50&page=1' 403 '{"message":"Resource not accessible by integration"}'
  ctl_once; assert_eq "$RC" 0
  grep -q 'event=runs_denied repo=octo/ok' "$T/out" || { cat "$T/out" >&2; return 1; }
  assert_eq "$(jq -r .last_error "$T/state/status.json")" null
}

test_start_failure_shows_docker_error_and_backs_off() {
  setup_ctl
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  queued_fx ok 7 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"; jit_fx ok 555
  fx DELETE /repos/octo/ok/actions/runners/555 204 ''
  cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GHR_TEST_LOG/docker.log"
case "$1" in
  run) [[ "$*" == *--user* ]] && { echo "docker: Error response from daemon: no space left on device" >&2; exit 125; } ;;
esac
exit 0
STUB
  ctl_once
  grep -q 'event=pod_start_failed.*step=runner.*detail="docker: Error response from daemon: no space left' "$T/out" || { cat "$T/out" >&2; return 1; }
  grep -q 'event=pod_start_paused seconds=30 after_start_failures=1' "$T/out" || return 1
  (( $(jq -r .backoff_until "$T/state/status.json") > $(date +%s) )) || return 1
  rm -f "$T/log/curl.log" "$T/out"; ctl_once
  grep -q 'event=discovery_paused reason=backoff' "$T/out" || return 1
  assert_eq "$(calls_to 'generate-jitconfig')" 0 "no second attempt during the pause"
}

test_etag_cache_entries_not_used_for_a_day_are_pruned() {
  setup_ctl
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  fx GET '/repos/octo/ok/actions/runs?status=queued&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  fx GET '/repos/octo/ok/actions/runs?status=in_progress&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  mkdir -p "$T/state/cache"; echo '{}' > "$T/state/cache/old.json"; echo '{}' > "$T/state/cache/fresh.json"
  touch -d '3 days ago' "$T/state/cache/old.json"
  ctl_once; assert_eq "$RC" 0
  assert_fail "old entry pruned" test -e "$T/state/cache/old.json"
  test -e "$T/state/cache/fresh.json" || return 1
}

test_a_second_controller_on_the_same_state_is_refused() {
  setup_ctl
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  mkdir -p "$T/state"
  flock "$T/state/ctl.lock" sleep 3 & local holder=$!
  sleep 0.5
  ctl_once
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  assert_eq "$RC" 1
  grep -q 'event=already_running' "$T/out" || { cat "$T/out" >&2; return 1; }
  assert_eq "$(calls_to .)" 0 "the second instance did nothing"
}

test_jobs_directory_must_be_private_and_owned_by_the_controller_user() {
  setup_ctl
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  mkdir -p "$T/state/jobs"; chmod 0755 "$T/state/jobs"
  fx GET '/repos/octo/ok/actions/runs?status=queued&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  fx GET '/repos/octo/ok/actions/runs?status=in_progress&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  ctl_once; assert_eq "$RC" 0
  assert_eq "$(stat -c %a "$T/state/jobs")" 700 "a too open directory is tightened"
  chown 65534 "$T/state/jobs"
  ctl_once; assert_eq "$RC" 1
  grep -q 'event=jobs_dir_unsafe' "$T/out" || { cat "$T/out" >&2; return 1; }
}

test_a_container_without_a_runner_id_label_does_not_crash_the_loop() {
  setup_ctl
  local now; now=$(date +%s)
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  echo "ghr-${now}-aaaaaa-runner|running|runner|${now}-aaaaaa|octo/ok||${now}" > "$T/log/ps.txt"
  ctl_once; assert_eq "$RC" 0
  assert_eq "$(jq -r .active_pods "$T/state/status.json")" 1
  assert_fail "never killed or deleted on a missing id" grep -qE '^kill|DELETE' "$T/log/docker.log" "$T/log/curl.log"
}

test_repository_and_job_lists_are_followed_across_pages() {
  setup_ctl
  echo 'GH_MAX_JOBS=5' >> "$T/config.env"
  local k
  fx GET '/installation/repositories?per_page=100&page=1' 200 "{\"repositories\":[$(repo_json ok true private false)]}"
  k=$(fxkey GET '/installation/repositories?per_page=100&page=1'); printf 'link: <https://api.github.com/installation/repositories?per_page=100&page=2>; rel="next"\r\n' > "$T/fx/$k.hdr"
  fx GET '/installation/repositories?per_page=100&page=2' 200 "{\"repositories\":[$(repo_json two true private false)]}"
  none_runners_for ok two
  fx GET '/repos/octo/two/actions/runs?status=queued&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  fx GET '/repos/octo/two/actions/runs?status=in_progress&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  fx GET '/repos/octo/ok/actions/runs?status=in_progress&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  fx GET '/repos/octo/ok/actions/runs?status=queued&per_page=50&page=1' 200 '{"workflow_runs":[{"id":7,"event":"push","repository":{"full_name":"octo/ok"},"head_repository":{"full_name":"octo/ok"}}]}'
  k=$(fxkey GET '/repos/octo/ok/actions/runs?status=queued&per_page=50&page=1'); printf 'link: <https://api.github.com/x?page=2>; rel="next"\r\n' > "$T/fx/$k.hdr"
  fx GET '/repos/octo/ok/actions/runs?status=queued&per_page=50&page=2' 200 '{"workflow_runs":[{"id":8,"event":"push","repository":{"full_name":"octo/ok"},"head_repository":{"full_name":"octo/ok"}}]}'
  fx GET '/repos/octo/ok/actions/runs/7/jobs?filter=latest&per_page=100&page=1' 200 "{\"jobs\":[$(job_json 70 queued null '["self-hosted","hetzner"]')]}"
  fx GET '/repos/octo/ok/actions/runs/8/jobs?filter=latest&per_page=100&page=1' 200 "{\"jobs\":[$(job_json 80 queued null '["self-hosted","hetzner"]')]}"
  jit_fx ok 555
  ctl_once; assert_eq "$RC" 0
  assert_eq "$(jq -r .served "$T/state/status.json")" 2 "repositories of both pages"
  assert_eq "$(calls_to 'POST /repos/octo/ok/actions/runners/generate-jitconfig')" 2 "runs of both pages"
}

test_idle_timeout_defaults_to_five_minutes() {
  setup_ctl
  local now; now=$(date +%s)
  repos_fx "$(repo_json ok true private false)"; none_runners_for ok
  fx GET '/repos/octo/ok/actions/runs?status=queued&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  fx GET '/repos/octo/ok/actions/runs?status=in_progress&per_page=50&page=1' 200 '{"workflow_runs":[]}'
  echo "ghr-$((now - 400))-aaaaaa-runner|running|runner|$((now - 400))-aaaaaa|octo/ok|600|$((now - 400))" > "$T/log/ps.txt"
  fx GET /repos/octo/ok/actions/runners/600 200 '{"id":600,"busy":false}'
  fx DELETE /repos/octo/ok/actions/runners/600 204 ''
  ctl_once
  grep -q "event=pod_killed.*reason=idle_timeout" "$T/out" || { cat "$T/out" >&2; return 1; }
}

test_npm_registry_is_not_passed_when_the_bridge_address_is_unknown() {
  setup_ctl
  queue_one
  export GHR_NPM_DIR="$T/npm-cache"; mkdir -p "$GHR_NPM_DIR"; : > "$GHR_NPM_DIR/docker-compose.yml"
  ctl_once; assert_eq "$RC" 0
  grep -q 'event=npm_cache_unavailable' "$T/out" || return 1
  assert_fail "no registry variable" grep -q 'NPM_CONFIG_REGISTRY' "$T/log/run.1"
}
