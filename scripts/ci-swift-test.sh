#!/usr/bin/env bash
set -euo pipefail

limit="${TEST_TIME_LIMIT:-300}"

swift build --build-tests
script -q /dev/null swift test --skip-build &
runner=$!

waited=0
while kill -0 "$runner" 2>/dev/null; do
  if [ "$waited" -ge "$limit" ]; then
    echo "::error::Tests still running after ${limit}s. Thread stacks follow."
    for pid in $(pgrep -f 'xctest|swiftpm-testing-helper|PackageTests' || true); do
      echo "── sample of $pid: $(ps -o command= -p "$pid" || true)"
      sample "$pid" 3 -mayDie 2>/dev/null || true
    done
    pkill -P "$runner" 2>/dev/null || true
    pkill -f 'xctest|swiftpm-testing-helper|PackageTests' 2>/dev/null || true
    kill "$runner" 2>/dev/null || true
    exit 1
  fi
  sleep 5
  waited=$((waited + 5))
done
wait "$runner"
