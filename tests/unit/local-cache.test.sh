#!/usr/bin/env bash
filter_cache() { awk -f "$REPO/runner/install/local-cache.awk" "$@"; }
test_remove_and_idempotence() {
  printf '%s\n' '[[runners]]' '[runners.cache]' 'MaxUploadedArchiveSize = 0' '[runners.cache.s3]' 'AssumeRoleMaxConcurrency = 0' '[runners.cache.gcs]' '[runners.cache.azure]' '[runners.docker]' 'volumes = ["/cache"]' > "$T/input"
  printf '%s\n' '[[runners]]' '[runners.docker]' 'volumes = ["/cache"]' > "$T/expected"
  filter_cache "$T/input" > "$T/output"
  cmp "$T/expected" "$T/output"
  filter_cache "$T/output" > "$T/again"
  cmp "$T/output" "$T/again"
}
test_preserve_configured_cache() {
  for setting in 'Type = "s3"' 'MaxUploadedArchiveSize = 1000' 'UnknownSetting = true'; do
    printf '%s\n' '[[runners]]' '[runners.cache]' "$setting" '[runners.cache.s3]' '[runners.docker]' > "$T/input"
    filter_cache "$T/input" > "$T/output"
    cmp "$T/input" "$T/output"
  done
}
test_multiple_runners() {
  printf '%s\n' '[[runners]]' '[runners.cache]' '[[runners]]' '[runners.cache]' 'Type = "gcs"' > "$T/input"
  printf '%s\n' '[[runners]]' '[[runners]]' '[runners.cache]' 'Type = "gcs"' > "$T/expected"
  filter_cache "$T/input" > "$T/output"
  cmp "$T/expected" "$T/output"
}
