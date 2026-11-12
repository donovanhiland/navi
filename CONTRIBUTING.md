# Contributing to Navi

Thanks for helping. Navi is a small project with one maintainer, so these rules keep reviews fast.

## Before you start

- **Bugs:** open an issue, or send a small fix with the steps to see the bug.
- **New features or changed defaults:** open an issue first and wait for a yes. A PR that changes
  how Navi behaves without that may be closed, even if the code is good.
- Read `AGENTS.md`. It has the decisions, the layout, and the rules (Swift 6, one package per
  feature, no cloud).

## Set up

```sh
brew install xcodegen
xcodegen generate
scripts/dev.sh                          # build and run Navi Dev
cd Packages/NaviCapture && swift test   # tests, one package at a time
```

Navi Dev is a separate app from the installed Navi, with its own permissions and history.

## Pull requests

- **One problem per PR.** Split unrelated fixes, even small ones.
- **Title:** a conventional commit in plain words, such as `fix(capture): …` or `feat(history): …`.
  The PR is squashed, so the title becomes the line in the release notes. CI checks it; run
  `scripts/pr-title-check.sh "<title>"` to check it first. The rules are in `AGENTS.md`
  ("Commits and PR titles").
- **Fill in the template:** Problem, Change, Verification. Show what you checked and what you saw.
  UI changes need before and after screenshots; add a short recording when motion or timing
  matters.
- **Tests:** put pure logic in a package and test it with Swift Testing. UI is checked by hand and
  shown in the PR.
- **CI must pass.** The `Check` status runs every package's tests, an unsigned app build, a
  release dry run (archive, app checks, a signed update feed, nothing published), and the release
  script tests. Run the script tests with `scripts/tests/run.sh`.
- **Agents are welcome.** You own the result: check it, and end the PR with the model and the
  tool you used.
- **Licenses:** do not copy code from GPL or BSL projects (macshot, Capso). Code from Hex (MIT)
  keeps its notice.

## Releases

Releases are automatic. Every night at 10:00 UTC, when `main` has new commits, GitHub builds,
signs, notarizes, and publishes the next patch version, and installed copies update through
Sparkle. A merged PR reaches everyone the next morning, so merge only what is ready.
