#!/usr/bin/env bash
# I10: only these paths may bind a C header.
set -uo pipefail
cd "$(dirname "$0")/.."
BAD=$(grep -rln --include='*.zig' -E 'addTranslateC|@cInclude|@cImport|@import\("sqlite"\)' src \
  | grep -v -E '^src/(store/sqlite|vm/[a-z_]+)\.zig$' || true)
if [ -n "$BAD" ]; then
  echo "C bindings outside the allowlist:"
  echo "$BAD"
  exit 1
fi
echo "layers: ok"
