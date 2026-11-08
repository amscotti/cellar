#!/usr/bin/env bash
# I14: nothing outside src/runtime may resolve a cell by key without the Locator.
# Fails if a file mentions a cell-table/map lookup primitive outside runtime/.
set -uo pipefail
cd "$(dirname "$0")/.."
HITS=$(grep -rn --include='*.zig' -E 'cells\.get\(|cellTable|findCell\(' src \
  | grep -v '^src/runtime/' || true)
if [ -n "$HITS" ]; then
  echo "$HITS"
  exit 1
fi
echo "locator: ok"
