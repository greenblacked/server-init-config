#!/usr/bin/env bash
# Thin wrapper: updates the installed components to the state of this repo copy. See runner/install/update.sh --help.
set -Eeuo pipefail
exec bash "$(dirname "${BASH_SOURCE[0]}")/install/update.sh" "$@"
