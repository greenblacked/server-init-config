#!/usr/bin/env bash
# Disable SSH for root. Run only after "ssh ADMIN@server sudo -n true" works. See install/users.sh --help.
# Extra options go to users.sh; --unlock-root and --help replace the default --lock-root.
set -Eeuo pipefail
mode=(--lock-root)
for arg in "$@"; do
  case "$arg" in
    --unlock-root|-h|--help) mode=() ;;
  esac
done
exec bash "$(dirname "${BASH_SOURCE[0]}")/users.sh" "${mode[@]}" "$@"
