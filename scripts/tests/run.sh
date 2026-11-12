#!/usr/bin/env bash
# Runs the release script tests. On Linux it skips the tests that need macOS.
#   scripts/tests/run.sh
set -euo pipefail
cd "$(dirname "$0")"
status=0
for test in *.test.sh; do
  if [[ ($test == sparkle-check.test.sh || $test == comments.test.sh) && $(uname) != Darwin ]]; then
    echo "skip $test (macOS only)"
    continue
  fi
  echo "$test"
  bash "$test" || status=1
done
exit $status
