#!/usr/bin/env bash
set -euo pipefail

# Keep gzip bytes identical across Python/zlib implementations. Use this pinned
# Python/zlib image only when runner-engine-update.sh changes.
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=python@sha256:5e2bdb1b0d542d5039cffb8181c65930093949194a65c365dfb1b0fe13a4fa5b
DOCKER=(docker)
if ! "${DOCKER[@]}" info >/dev/null 2>&1; then
  DOCKER=(sudo -n docker)
fi

"${DOCKER[@]}" run --rm \
  --user "$(id -u):$(id -g)" \
  --volume "$ROOT:/src" \
  --workdir /src \
  "$IMAGE" python -c 'import gzip,pathlib; p=pathlib.Path("runner/scripts/runner-engine-update.sh"); f=p.with_name(p.name+".gz").open("wb"); g=gzip.GzipFile(filename="",fileobj=f,mode="wb",mtime=0,compresslevel=9); g.write(p.read_bytes()); g.close(); f.close()'
