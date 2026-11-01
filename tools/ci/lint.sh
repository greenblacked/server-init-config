#!/usr/bin/env bash
# Static checks of the repo, the same ones lint.yml runs. Usage: tools/ci/lint.sh [CHECK ...]   (default: all)
#   shell        shellcheck -S warning + bash -n on every shell file (found by shebang or *.sh)
#   render       tools/render-cloud-init.py --check, tools/render-paste-commands.py --check
#   cloud-init   tools/test-cloud-init.py (with the cloud-init CLI: schema check; as root with sshd: live SSH test)
#   server-tools tools/test-server-tools.sh, destructive tests inside a throwaway container (needs Docker)
#   yaml         yamllint (relaxed, .yamllint.yml)
#   dockerfiles  hadolint on every Dockerfile
#   compose      docker compose config on every compose file, with generated test .env files
#   actionlint   actionlint on .github/workflows
#   pins         tools/ci/check-pins.sh: workflow actions pinned to a commit SHA, top-level permissions
#   unit         tests/unit/run.sh, fast unit tests of the shell helpers (temp dirs only, no root)
# Locally a missing tool is skipped with a note; in CI it fails.
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
cd "$CI_ROOT"

shell_files() {
  git ls-files | while IFS= read -r f; do
    [[ -f "$f" && ! -L "$f" ]] || continue
    case "$f" in
      *.sh) echo "$f"; continue ;;
    esac
    case "$(head -n1 "$f" 2>/dev/null | head -c 120 | tr -d '\0')" in
      '#!'*bash* | '#!'*/sh | '#!'*/sh\ * | '#!'*env\ sh*) echo "$f" ;;
    esac
  done | sort -u
}

check_shell() {
  group "shellcheck and bash -n"
  need_or_skip shellcheck || { endgroup; return 0; }
  local files f sc_fail=0 n_fail=0
  mapfile -t files < <(shell_files)
  log "${#files[@]} shell files"
  # -x follows `source` directives; files without a shebang (profile.d snippets) are read as bash unless they say otherwise.
  for f in "${files[@]}"; do
    if head -n1 "$f" | grep -q '^#!'; then
      shellcheck -x -S warning "$f" || sc_fail=$((sc_fail + 1))
    else
      shellcheck -x -S warning -s bash "$f" || sc_fail=$((sc_fail + 1))
    fi
    # bash -n only for bash files; POSIX sh files are parsed with dash when it exists.
    if head -n1 "$f" | grep -q 'bash'; then bash -n "$f" || n_fail=$((n_fail + 1))
    elif head -n1 "$f" | grep -q 'sh' && need dash; then dash -n "$f" || n_fail=$((n_fail + 1))
    fi
  done
  endgroup
  (( sc_fail == 0 )) && pass "shellcheck -S warning: ${#files[@]} files clean" || fail "shellcheck found problems in ${sc_fail} file(s)"
  (( n_fail == 0 )) && pass "bash -n / dash -n: all files parse" || fail "syntax errors in ${n_fail} file(s)"
}

check_render() {
  group "generated files are current"
  python3 tools/render-cloud-init.py --check && pass "render-cloud-init --check" || fail "render-cloud-init --check (run tools/render-cloud-init.py and commit)"
  python3 tools/render-paste-commands.py --check && pass "render-paste-commands --check" || fail "render-paste-commands --check (run tools/render-paste-commands.py and commit)"
  endgroup
}

check_cloud_init() {
  group "tools/test-cloud-init.py"
  if need cloud-init; then pass "cloud-init CLI present: schema check runs ($(cloud-init --version 2>&1 | head -1))"
  elif in_ci; then fail "cloud-init CLI missing in CI: the schema check would be skipped"
  else warn "cloud-init CLI missing: schema check is skipped by the test"; fi
  # The live SSH test needs root, sshd and ssh-keygen; on a runner that is sudo.
  local py=python3
  if [[ $EUID -ne 0 ]] && need sudo && need sshd; then py="sudo -E env PATH=$PATH python3"; fi
  # shellcheck disable=SC2086
  if $py tools/test-cloud-init.py | tee "$CI_OUT/test-cloud-init.log" | tail -15; then pass "test-cloud-init.py"; else fail "test-cloud-init.py"; fi
  # The test prints "SKIP" when the CLI, root or sshd is missing. In CI that would silently drop the checks this job exists for.
  if grep -q '^  SKIP  ' "$CI_OUT/test-cloud-init.log"; then
    grep -m5 '^  SKIP  ' "$CI_OUT/test-cloud-init.log"
    if in_ci; then fail "test-cloud-init.py skipped checks in CI (schema or live SSH)"; else warn "some checks were skipped (needs the cloud-init CLI, root and sshd)"; fi
  else
    pass "no check skipped: schema validated by the cloud-init CLI, live SSH test ran"
  fi
  endgroup
}

check_server_tools() {
  group "tools/test-server-tools.sh (hermetic)"
  # Hermetic part on the host as root, destructive part in a container: it writes to /etc, /usr/local and /var/log.
  if $SUDO tools/test-server-tools.sh > "$CI_OUT/test-server-tools-host.log" 2>&1; then pass "test-server-tools.sh (hermetic, host)"; else tail -30 "$CI_OUT/test-server-tools-host.log"; fail "test-server-tools.sh (hermetic, host)"; fi
  endgroup
  group "tools/test-server-tools.sh (destructive, in containers)"
  if need_or_skip docker; then
    local img
    for img in ${SERVER_TOOLS_IMAGES:-almalinux:10}; do
      if docker run --rm -v "$CI_ROOT:/repo:ro" -e SERVER_TOOLS_TEST_DESTRUCTIVE=1 "$img" bash /repo/tools/test-server-tools.sh > "$CI_OUT/test-server-tools-${img//[:\/]/_}.log" 2>&1; then
        pass "test-server-tools.sh destructive in ${img}"
      else tail -30 "$CI_OUT/test-server-tools-${img//[:\/]/_}.log"; fail "test-server-tools.sh destructive in ${img}"; fi
    done
  fi
  endgroup
}

check_yaml() {
  group "yamllint"
  need_or_skip yamllint || { endgroup; return 0; }
  local files
  mapfile -t files < <(git ls-files '*.yml' '*.yaml' '*.yml.in' '*.yaml.in')
  # *.in templates hold only part of a document and may not parse alone: lint the real YAML files.
  mapfile -t files < <(printf '%s\n' "${files[@]}" | grep -v '\.in$')
  if yamllint -c .yamllint.yml "${files[@]}"; then pass "yamllint: ${#files[@]} files"; else fail "yamllint"; fi
  endgroup
}

check_dockerfiles() {
  group "hadolint"
  need_or_skip hadolint || { endgroup; return 0; }
  local f bad=0 n=0
  while IFS= read -r f; do
    n=$((n + 1))
    # info-level findings (DL3066 on the kali image: a numeric-name user) are listed but do not fail; warnings and errors do.
    hadolint --failure-threshold warning "$f" || bad=$((bad + 1))
  done < <(git ls-files | grep -E '(^|/)Dockerfile(\.[^/]*)?$')
  (( bad == 0 )) && pass "hadolint: ${n} Dockerfile(s)" || fail "hadolint reported problems in ${bad} Dockerfile(s)"
  endgroup
}

# Test values for the variables a compose file insists on (${NAME:?message}); the rest has defaults.
write_test_env() { # compose-file env-file
  local name
  : > "$2"
  { grep -o '\${[A-Za-z_0-9]*:?' "$1" || true; } | sed 's/^\${//; s/:?$//' | sort -u | while IFS= read -r name; do
    case "$name" in
      *IMAGE*) echo "${name}=example/test:1" ;;
      *_UID | *_GID | *PORT) echo "${name}=1000" ;;
      *) echo "${name}=test-value" ;;
    esac
  done >> "$2"
}

check_compose() {
  group "docker compose config"
  need_or_skip docker || { endgroup; return 0; }
  local f d tmp bad=0 n=0 base extra
  while IFS= read -r f; do
    n=$((n + 1)); d=$(dirname "$f"); tmp=$(mktemp -d)
    # Work on a copy of the stack folder with a generated .env (compose reads it and env_file: .env from there).
    cp -a "$d/." "$tmp/"
    base="$f"; extra=()
    # an override file belongs to its base file (torrserver: base + vpn)
    if [[ "$f" == *docker-compose.vpn.yml ]]; then base="$d/docker-compose.yml"; extra=(-f "$tmp/docker-compose.yml"); fi
    write_test_env "$base" "$tmp/.env"
    if docker compose --project-directory "$tmp" "${extra[@]}" -f "$tmp/$(basename "$f")" config -q; then echo "ok  $f"; else echo "BAD $f"; bad=$((bad + 1)); fi
    rm -rf "$tmp"
  done < <(git ls-files | grep -E '(^|/)docker-compose[^/]*\.ya?ml$')
  (( bad == 0 )) && pass "docker compose config: ${n} file(s)" || fail "docker compose config failed for ${bad} file(s)"
  endgroup
}

check_actionlint() {
  group "actionlint"
  need_or_skip actionlint || { endgroup; return 0; }
  # actionlint runs shellcheck on the run: blocks when shellcheck is installed.
  if actionlint -color; then pass "actionlint"; else fail "actionlint"; fi
  endgroup
}

check_pins() {
  group "workflow pins and permissions"
  if tools/ci/check-pins.sh > "$CI_OUT/check-pins.log" 2>&1; then tail -n 1 "$CI_OUT/check-pins.log"; pass "workflows: actions pinned by SHA, permissions set"
  else grep -v '^  PASS ' "$CI_OUT/check-pins.log"; fail "workflows: unpinned action or missing permissions (tools/ci/check-pins.sh)"; fi
  endgroup
}

check_unit() {
  group "unit tests"
  if tests/unit/run.sh > "$CI_OUT/unit-tests.log" 2>&1; then tail -n 1 "$CI_OUT/unit-tests.log"; pass "unit tests (tests/unit)"
  else cat "$CI_OUT/unit-tests.log"; fail "unit tests (tests/unit)"; fi
  endgroup
}

main() {
  local checks=("$@")
  [[ ${#checks[@]} -gt 0 ]] || checks=(shell render cloud-init server-tools yaml dockerfiles compose actionlint pins unit)
  local c
  for c in "${checks[@]}"; do
    case "$c" in
      shell) check_shell ;;
      render) check_render ;;
      cloud-init) check_cloud_init ;;
      server-tools) check_server_tools ;;
      yaml) check_yaml ;;
      dockerfiles) check_dockerfiles ;;
      compose) check_compose ;;
      actionlint) check_actionlint ;;
      pins) check_pins ;;
      unit) check_unit ;;
      -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      *) die "unknown check: $c" ;;
    esac
  done
  finish
}
main "$@"
