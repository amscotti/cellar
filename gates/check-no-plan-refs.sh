#!/usr/bin/env bash
# I9: code, tests and comments never cite plan phases or task ids.
set -uo pipefail
cd "$(dirname "$0")/.."
HITS=$(grep -rn --include='*.zig' -E 'Phase [0-9]|phase [0-9]|TASK-[0-9]|task id' src test 2>/dev/null || true)
if [ -n "$HITS" ]; then
  echo "$HITS"
  exit 1
fi
echo "no plan references: ok"
