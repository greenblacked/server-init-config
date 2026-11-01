# shellcheck shell=bash
# put() is defined in four server-init scripts and server/install-tools.sh. Those scripts run the installer when sourced,
# so the real function text is cut out of each file (from "put() {" to the closing "}") and evaluated alone.
# Contract: write stdin to PATH with MODE only when the content changed; create parent directories; print nothing.

load_put() { # load_put FILE
  local src
  src=$(awk '/^put\(\) \{/,/^}/' "$REPO/$1")
  [[ -n "$src" ]] || { echo "put() not found in $1" >&2; return 1; }
  unset -f put
  eval "$src"
}

PUT_FILES=(server/server-init-fedora.sh server/server-init-opensuse.sh server/server-init-el10.sh server/server-init-debian.sh server/install-tools.sh)

each_put() { # each_put FN : run FN once per script, each with a fresh directory
  local f
  for f in "${PUT_FILES[@]}"; do
    load_put "$f"
    rm -rf "${T:?}/w"; mkdir "$T/w"
    "$1" "$f" || { echo "    (in $f)" >&2; return 1; }
  done
}

t_creates_with_mode_and_parents() {
  printf 'hello\n' | put "$T/w/a/b/file" 0640
  assert_eq "$(cat "$T/w/a/b/file")" hello
  assert_eq "$(stat -c %a "$T/w/a/b/file")" 640
}
t_unchanged_content_is_not_rewritten() {
  printf 'x\n' | put "$T/w/file" 0644
  touch -d '2001-01-01 00:00:00' "$T/w/file"
  printf 'x\n' | put "$T/w/file" 0644
  assert_eq "$(stat -c %Y "$T/w/file")" 978307200 "mtime unchanged"
}
t_changed_content_is_replaced() {
  printf 'x\n' | put "$T/w/file" 0644
  printf 'y\n' | put "$T/w/file" 0644
  assert_eq "$(cat "$T/w/file")" y
}
t_prints_nothing() {
  assert_eq "$(printf 'x\n' | put "$T/w/file" 0644 2>&1)" ""
}
t_leaves_no_temp_files() {
  mkdir "$T/tmp"
  printf 'x\n' | TMPDIR="$T/tmp" put "$T/w/file" 0644
  printf 'x\n' | TMPDIR="$T/tmp" put "$T/w/file" 0644
  printf 'y\n' | TMPDIR="$T/tmp" put "$T/w/file" 0644
  assert_eq "$(ls -A "$T/tmp" | wc -l)" 0
}

test_put_creates_with_mode_and_parents() { each_put t_creates_with_mode_and_parents; }
test_put_unchanged_content_is_not_rewritten() { each_put t_unchanged_content_is_not_rewritten; }
test_put_changed_content_is_replaced() { each_put t_changed_content_is_replaced; }
test_put_prints_nothing() { each_put t_prints_nothing; }
test_put_leaves_no_temp_files() { each_put t_leaves_no_temp_files; }
