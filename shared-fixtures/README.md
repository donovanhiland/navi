# Shared fixtures

Files that both the Mac app (`Packages/`) and the Windows app (`windows/`) read in their tests.
When one app changes a file format, both test suites must still pass on these files.

- `history/history.json`: a history file in the format the Mac `Inbox` writes (dates are seconds
  since 2001-01-01 UTC, IDs are uppercase UUIDs, missing optional fields are left out). The last
  item has no `lastUsedAt` or `copyCount`, like files from before copy counts.
