# shellcheck shell=bash
# Unit tests for backup() and edit_with_backup() in common/lib.sh. Sourced by run.sh; $T is a private empty directory.
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
