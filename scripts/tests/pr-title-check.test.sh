#!/usr/bin/env bash
# Tests scripts/pr-title-check.sh. Runs on Linux and macOS.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
check="$root/scripts/pr-title-check.sh"

passes() {
  if ! "$check" "$1" >/dev/null 2>&1; then
    printf '  FAIL expected a pass: %s\n' "$1"
    failures=$((failures + 1))
  fi
}

test_good_titles() {
  passes "fix(capture): area shots keep the last pixel row"
  passes "feat: pin a shot to the screen"
  passes "ci(release): a repo variable pauses nightly releases"
  passes "refactor(navi-core)!: Inbox saves on a background queue"
  passes "docs: contributing guide"
}

test_bad_titles() {
  assert_fails "empty" "$check" ""
  assert_fails "no type" "$check" "area shots keep the last pixel row"
  assert_fails "unknown type" "$check" "feature: pin a shot"
  assert_fails "no space" "$check" "fix:area shots"
  assert_fails "empty subject" "$check" "fix: "
  assert_fails "capital scope" "$check" "fix(Capture): area shots"
  assert_fails "merge subject" "$check" "Merge pull request #20 from donovanhiland/chore/no-comments"
  assert_fails "trailing period" "$check" "fix: area shots keep the last row."
  assert_fails "too long" "$check" "fix: $(printf 'a%.0s' {1..100})"
  assert_fails "line break" "$check" $'fix: one\ntwo'
}

run_tests
