#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
work=$(mktemp -d)
lint() { swift "$root/scripts/comments.swift" "$@"; }

test_finds_every_kind() {
  cat > "$work/a.swift" <<'SWIFT'
/// Doc
struct A {
    // note
    let x = 1 /* inline */ + 2
}
SWIFT
  assert_eq 3 "$(lint "$work/a.swift" | grep -c 'not allowed')" "comment count"
}

test_ignores_comment_marks_in_strings() {
  cat > "$work/b.swift" <<'SWIFT'
let url = "https://x.com"
let raw = #"a // b \#(f("x // y")) "#
let multi = """
    /* not a comment */
    """
SWIFT
  lint "$work/b.swift" >/dev/null || { echo "  FAIL strings"; failures=$((failures + 1)); }
}

test_allows_tools_version_and_license_header() {
  mkdir -p "$work/p"
  printf '// swift-tools-version: 6.0\nimport PackageDescription\n' > "$work/p/Package.swift"
  printf '// MIT License. Copyright (c) 2026 Someone.\nimport Foundation\n' > "$work/c.swift"
  lint "$work/p/Package.swift" "$work/c.swift" >/dev/null || { echo "  FAIL allowed"; failures=$((failures + 1)); }
}

test_fix_removes_comments_and_keeps_code() {
  printf 'struct A {\n    // note\n\n    let x = 1 // trailing\n}\n' > "$work/d.swift"
  lint --fix "$work/d.swift"
  assert_eq $'struct A {\n    let x = 1\n}' "$(cat "$work/d.swift")" "fixed file"
}

run_tests
