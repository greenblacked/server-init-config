#!/usr/bin/env bash
# Disable SSH for root. Run only after "ssh ADMIN@server sudo -n true" works. See install/users.sh --help.
set -Eeuo pipefail
exec bash "$(dirname "${BASH_SOURCE[0]}")/users.sh" --lock-root "$@"
