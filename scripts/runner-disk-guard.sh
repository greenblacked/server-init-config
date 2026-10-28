#!/usr/bin/env bash
# Emergency cleanup when the root filesystem crosses HARD_LIMIT percent.
set -Eeuo pipefail

HARD_LIMIT="${HARD_LIMIT:-85}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: $0  (env: HARD_LIMIT=85) runs runner-weekly-cleanup.sh with RETENTION_DAYS=1 when disk usage >= HARD_LIMIT%"
  exit 0
fi

used=$(df --output=pcent / | tail -1 | tr -dc '0-9')
if (( used >= HARD_LIMIT )); then
  logger -t runner-disk-guard -- "disk ${used}% >= ${HARD_LIMIT}%, running emergency cleanup"
  RETENTION_DAYS=1 /usr/local/bin/runner-weekly-cleanup.sh
fi
