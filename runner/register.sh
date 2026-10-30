#!/usr/bin/env bash
# Thin wrapper: registers the runner (asks for the glrt- token). See runner/install/register-runner.sh --help.
set -Eeuo pipefail
exec bash "$(dirname "${BASH_SOURCE[0]}")/install/register-runner.sh" "$@"
