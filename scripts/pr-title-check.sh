#!/usr/bin/env bash
# Checks a pull request title. PRs are squashed, so the title becomes the commit subject on main
# and one line of the release notes.
#   scripts/pr-title-check.sh "<title>"
# Format: type(scope): what changed, in plain words. The scope is optional.
set -euo pipefail

title=${1-}
types='feat|fix|perf|refactor|docs|test|ci|build|chore|revert'
max=100

fail() {
  printf 'PR title: %s\n  %s\n' "$1" "$title" >&2
  printf 'Use: type(scope): what changed, such as "fix(capture): area shots keep the last pixel row".\n' >&2
  printf 'Types: %s. Scope: lowercase letters, digits, and dashes.\n' "${types//|/, }" >&2
  exit 1
}

[[ -n $title ]] || fail "the title is empty"
[[ $title =~ ^($types)(\([a-z0-9-]+\))?!?:\ [^[:space:]] ]] || fail "it does not start with type(scope): "
(( ${#title} <= max )) || fail "it is ${#title} characters; the limit is $max"
[[ $title != *. ]] || fail "it ends with a period"
[[ $title != *$'\n'* ]] || fail "it has a line break"
echo "PR title ok: $title"
