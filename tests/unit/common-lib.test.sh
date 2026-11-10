# shellcheck shell=bash
# Unit tests for backup() and edit_with_backup() in common/lib.sh. Sourced by run.sh; $T is a private empty directory.
# Sourcing common/lib.sh installs diffutils when run as root without cmp. A unit test must not change the host, so stop first.
if [[ $EUID -eq 0 ]] && ! command -v cmp >/dev/null 2>&1; then
  echo "cmp is missing and this is root: install diffutils first (common/lib.sh would install it on source)" >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck source=../../common/lib.sh
source "$REPO/common/lib.sh"

baks() { compgen -G "$1.bak.*" || true; }
count_baks() { baks "$1" | grep -c . || true; }

test_backup_copies_once_for_unchanged_file() {
  echo one > "$T/f"
  backup "$T/f"
  backup "$T/f"
  assert_eq "$(count_baks "$T/f")" 1 "identical content is not backed up twice"
}

test_backup_new_copy_after_real_change() {
  echo one > "$T/f"; backup "$T/f"
  # make the first backup's name differ from the next one (names carry seconds)
  mv "$T/f.bak."* "$T/f.bak.20000101-000000"
  echo two > "$T/f"; backup "$T/f"
  assert_eq "$(count_baks "$T/f")" 2
}

test_backup_keeps_mode() {
  echo secret > "$T/f"; chmod 0600 "$T/f"
  backup "$T/f"
  assert_eq "$(stat -c %a "$(baks "$T/f")")" 600
}

test_edit_no_backup_when_unchanged() {
  echo one > "$T/f"
  edit_with_backup "$T/f" true
  assert_eq "$(count_baks "$T/f")" 0
  assert_eq "$(cat "$T/f")" one
}

test_edit_no_backup_when_rewritten_identically() {
  echo one > "$T/f"
  edit_with_backup "$T/f" sed -i 's/one/one/' "$T/f"
  assert_eq "$(count_baks "$T/f")" 0
}

test_edit_one_backup_with_previous_content() {
  echo one > "$T/f"
  edit_with_backup "$T/f" sed -i 's/one/two/' "$T/f"
  assert_eq "$(cat "$T/f")" two
  assert_eq "$(count_baks "$T/f")" 1
  assert_eq "$(cat "$(baks "$T/f")")" one "backup holds the old content"
}

test_edit_keeps_mode() {
  echo one > "$T/f"; chmod 0640 "$T/f"
  edit_with_backup "$T/f" sed -i 's/one/two/' "$T/f"
  assert_eq "$(stat -c %a "$(baks "$T/f")")" 640
}

test_edit_names_are_unique_within_one_second() {
  echo a > "$T/f"
  local i
  for i in 1 2 3 4 5; do edit_with_backup "$T/f" sh -c 'echo "$1" >> "$2"' _ "$i" "$T/f"; done
  assert_eq "$(count_baks "$T/f")" 5 "five edits, five distinct backups"
}

test_edit_failed_command_keeps_backup_and_stops_the_caller() {
  # Installers run with set -e: a CMD that dies halfway aborts the caller (exit status 7 here) and the snapshot of the
  # previous content stays next to the file, because the file may be half-written. A child bash gives a real set -e.
  echo one > "$T/f"
  rc=0
  REPO="$REPO" bash -c 'set -e; source "$REPO/common/lib.sh"; edit_with_backup "$1" sh -c "echo partial >> \$1; exit 7" _ "$1"; echo not-reached' _ "$T/f" > "$T/out" || rc=$?
  assert_eq "$rc" 7
  assert_eq "$(cat "$T/out")" ""
  assert_eq "$(count_baks "$T/f")" 1
  assert_eq "$(cat "$(baks "$T/f")")" one
}

test_edit_leaves_nothing_outside_the_target_directory() {
  mkdir "$T/tmp" "$T/d"; echo one > "$T/d/f"
  TMPDIR="$T/tmp" edit_with_backup "$T/d/f" sed -i 's/one/two/' "$T/d/f"
  assert_eq "$(ls -A "$T/tmp" | wc -l)" 0 "snapshot is not placed in TMPDIR"
}

test_version_ge() {
  assert_ok "equal" version_ge 2.23.1 2.23.1
  assert_ok "newer patch" version_ge 2.23.2 2.23.1
  assert_ok "numeric, not lexical" version_ge 2.100.0 2.23.1
  assert_ok "newer major" version_ge 5.0.0 2.23.1
  assert_fail "older patch" version_ge 2.23.0 2.23.1
  assert_fail "older minor" version_ge 2.9.9 2.23.1
  assert_fail "older major" version_ge 1.29.2 2.23.1
}

# require_compose_min with a stub "docker" that prints $FAKE_COMPOSE for "compose version --short"
test_require_compose_min() {
  mkdir -p "$T/bin"
  printf '#!/bin/sh\n[ -n "$FAKE_COMPOSE" ] && echo "$FAKE_COMPOSE"\n' > "$T/bin/docker"
  chmod +x "$T/bin/docker"
  PATH="$T/bin:$PATH"
  FAKE_COMPOSE=2.24.0 assert_ok "newer compose passes" require_compose_min 2.23.1 test
  FAKE_COMPOSE=v2.23.1 assert_ok "v prefix is accepted" require_compose_min 2.23.1 test
  FAKE_COMPOSE=2.23.1+ds1 assert_ok "distro suffix is ignored" require_compose_min 2.23.1 test
  FAKE_COMPOSE=2.22.0 assert_fail "old compose dies" bash -c 'source "$1"; require_compose_min 2.23.1 test' _ "$REPO/common/lib.sh"
  FAKE_COMPOSE='' assert_fail "missing compose dies" bash -c 'source "$1"; require_compose_min 2.23.1 test' _ "$REPO/common/lib.sh"
}

# ci_jobs_running / ci_job_ids with a stub "docker ps" that answers per label filter: $FAKE_GITLAB and $FAKE_GITHUB hold container ids
fake_docker_ps() {
  mkdir -p "$T/bin"
  cat > "$T/bin/docker" <<'STUB'
#!/bin/sh
[ -n "$FAKE_DOCKER_FAIL" ] && exit 1
case "$*" in
  *com.gitlab.gitlab-runner.managed=true*) [ -n "$FAKE_GITLAB" ] && printf '%s\n' $FAKE_GITLAB ;;
  *io.server-init.github-runner=job*) [ -n "$FAKE_GITHUB" ] && printf '%s\n' $FAKE_GITHUB ;;
esac
exit 0
STUB
  chmod +x "$T/bin/docker"
  PATH="$T/bin:$PATH"
}

test_ci_jobs_running_counts_gitlab_and_github_containers() {
  fake_docker_ps
  assert_eq "$(ci_jobs_running)" 0 "idle host"
  assert_eq "$(FAKE_GITLAB='a b' ci_jobs_running)" 2 "two GitLab job containers"
  assert_eq "$(FAKE_GITHUB='c' ci_jobs_running)" 1 "one GitHub runner container is a job too"
  assert_eq "$(FAKE_GITLAB='a' FAKE_GITHUB='c d' ci_jobs_running)" 3 "both kinds"
}

test_ci_job_ids_is_an_error_when_docker_fails() {
  fake_docker_ps
  assert_fail "docker not answering is not 'no jobs'" env FAKE_DOCKER_FAIL=1 bash -c 'source "$1"; ci_job_ids' _ "$REPO/common/lib.sh"
  assert_eq "$(FAKE_GITLAB='a' bash -c 'source "$1"; ci_job_ids' _ "$REPO/common/lib.sh")" a
}

test_require_runner_idle_dies_for_a_github_pod() {
  fake_docker_ps
  assert_ok "idle passes" bash -c 'source "$1"; require_runner_idle' _ "$REPO/common/lib.sh"
  assert_fail "a GitHub pod blocks the update gate" env FAKE_GITHUB=c bash -c 'source "$1"; require_runner_idle' _ "$REPO/common/lib.sh"
}
