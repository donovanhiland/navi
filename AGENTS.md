# Navi

A macOS menu bar app for capture. It combines four tools:

| Feature | Model app | Status |
|---|---|---|
| Clipboard history | Maccy | Done (v0.1) |
| Screenshot with markup | CleanShot X | Steps 1–4 built. Step 1 checked |
| Talk to type | Wispr Flow | Built, not checked |
| Screen recording | CleanShot X, then Screen Studio | Step 5 built, not checked. No Screen Studio editor |

The main idea: every capture (clip, screenshot, recording, GIF, dictated text,
OCR text) goes to one place. It shows first as a corner card, then in one shared
history list. `⇧⌘V` opens that list. The user can change it in Settings.

## Plan

`docs/capture-plan.html` is the source of truth for screenshots and recording.
It has three tabs:

1. **Prototype:** a clickable HTML mock of every capture flow. Match its layout
   and behavior in the real app.
2. **Feature map:** every CleanShot X feature (launch video and features page),
   what Navi builds, the macOS API, and the step.
3. **Plan:** steps 1 to 5, what "done" means for each one, permissions, and
   open questions.

Build order: clipboard (done) → screenshots (steps 1–4) → talk to type →
recording (step 5).

**Step 1 (capture core and corner card) is built and checked** (area, window,
fullscreen, Copy, Save, Show in Finder, drag, Close All, card shortcuts, Hide
Desktop Icons). Not checked yet: the `⌥⇧⌘N` menu and a second display.

**Steps 2–4 are built, not checked by Donovan yet:**
- Step 2, markup editor (`Annotate/`): every tool in the plan, color picker
  and screen color sampler, three line sizes, select/move/delete marks (after you draw,
  the tool goes back to the pointer with the new mark selected; a dashed outline
  shows it; drag a corner, an end, or anywhere on an edge to resize; the cursor
  shows what a drag does; the color and size pickers change the selected mark;
  the counter tool stays on for the next step; spotlight is a rounded box), `⌘Z`/`⇧⌘Z`/Delete through a local key monitor,
  toolbar tooltips (`Annotate/Tooltip.swift`: one dark bubble drawn in a top layer, so no
  button moves; the name and a small keycap; the first tip waits 0.45 s, then it glides
  between buttons),
  rotate, flip, resize, crop, undo/redo, drop an image in to combine, a small
  picture of the shot to drag into any app (top right, beside Cancel and Done), Done updates the card and the history item. Marks stay editable in
  `<id>.navi` (JSON + base PNG) beside the Inbox file.
- Step 3 (`Extras/`): pin to screen (move, scroll to resize, opacity, lock so
  clicks go through, unlock from the menu), Capture Text (OCR + QR, Vision;
  macOS builds the text model once per macOS build, about 40 s, so Navi runs
  one warm-up read in the background 20 s after launch when the build is new),
  self-timer, all-in-one bar on `⇧⌘5`, card quick actions (right-click).
- Step 4: scrolling capture (`Scroll/`, Vision registration, vertical and
  horizontal, Auto-scroll; a frame every 40 ms plus capture time, and only
  frames that moved a quarter frame or more are kept), background tool
  (`Background/`: gradients, solid, picture, padding, corners, shadow, aspect
  ratio, auto balance, presets; the soft fill and shadow are drawn at a quarter
  size and scaled up, and the preview renders at 1600 px at most).

**Talk to type and step 5 are built, not checked by Donovan yet:**
- `Packages/NaviDictation`: hold fn to talk, double-tap fn to lock, pill with
  a waveform, on-device speech (Parakeet TDT v3 through FluidAudio, from Hex;
  `SpeechAnalyzer` or `SFSpeechRecognizer` until the Parakeet model is loaded.
  The model, about 0.5 GB, downloads on first start to
  `~/Library/Application Support/FluidAudio/Models`), cleanup with Foundation Models or rules, paste at the
  cursor, then the old clipboard comes back (marked as Navi's, so the
  history does not list the old copy again above the dictation). Each
  dictation is a `.dictation` item in the shared history. `⌥⇧V` (Hex's
  default, and a menu item; only while talk to type is on) pastes the last
  dictation again. Speed: the pill shows on the
  press. By default (like Wispr Flow) the mic is set up ahead of time but off,
  so there is no mic dot between dictations; a press only starts it. "Keep
  Microphone Ready" (Settings, off by default; Hex's "Keep ready") keeps the mic
  open with a 450 ms pre-roll, so a press records at once (macOS shows the mic
  dot). The mic is an input-only AUHAL unit on the default input, like Hex
  (cpal). Not `AVAudioEngine`: it joins the mic and the speakers in a hidden
  aggregate device, which changes music and cuts it out when it stops.
  After the release, recording runs on until
  200 ms of quiet (at least 40 ms, at most 600 ms), so the last word is kept and
  a user who already stopped talking waits only 40 ms. Speech and cleanup run
  while the user talks (`LiveDictation`): about once a second, and when the user
  goes quiet, Parakeet transcribes the audio after the last finished sentence. A
  sentence is finished when another one follows it with a real pause (found in
  the audio); it is cleaned in the background and later passes start after the
  pause. When nothing was said after the newest pass, the release reuses it, so
  the text is often ready at once. Cleanup is per sentence: rules, then Apple's
  model only for sentences that need it (`TextCleaner.needsModel`: corrections,
  lists, spoken punctuation, filler words rules keep, repeats, long sentences
  with no commas). Timings log under the `Dictation` category ("Release to
  text: … ms", "Live: …"). fn with another key (fn+⌫,
  fn+arrows) never dictates. The first launch asks before it uses fn. When on,
  Navi borrows the fn key setting (`AppleFnUsageType` = 0, "Do Nothing", applied
  with `activateSettings -u`) while it runs and puts it back on quit.
- `Packages/NaviRecording`: record bar, `SCStream` → MP4 (H.264/AAC), mic and
  computer audio (mixed to one track), camera bubble, click and key overlays,
  hide icons, mute notifications, red stop item in the menu bar, GIF, trim.
  The app wires it to the capture overlay (`CaptureFeature.onRecordRequest`)
  and to video cards (`CaptureFeature.videoTools`, `showRecording`).

Not built: swipe to close a card, the Screen Studio-style
video editor.

## Decisions

- **One app, one menu bar icon.** This gives one set of macOS permissions
  (screen, mic, accessibility) and one shared history.
- **One Swift package per feature** under `Packages/`. Features talk only
  through `NaviCore`. A feature package never imports another feature package.
- **Stack:** Swift 6, SwiftUI, and AppKit. Not Electron. Not Tauri.
- **Rust:** not for v1. Later it may be a small library for one engine part,
  such as speech or GIF encoding (gifski).
- **No cloud.** Everything stays local. Where CleanShot has a Cloud button,
  Navi shows "Show in Finder."
- **Two kinds of UI:**
  - *Quick pickers* for fast actions, such as the Maccy-style clipboard menu at
    the mouse. Fast in, fast out.
  - *Home window* in the style of Wispr Flow's main app. It brings all captures
    together. It is not for quick paste. Not built yet.
- **Hide desktop icons and mute notifications** do not change the real screen.
  Navi leaves Finder's desktop windows and Notification Center's windows out of
  the ScreenCaptureKit filter.
- **Talk to type follows Hex** (`anomalyco/hex`, MIT, from the OpenCode
  team). Port Hex's features; do not design new dictation features from
  scratch. `docs/upstream-hex.md` has the feature map, what to port next, and
  the sync steps. Check each port with the dictation benchmark
  (`cd Packages/NaviDictation && swift run dictation-bench`).
- **Single window capture** uses `SCContentFilter(desktopIndependentWindow:)`,
  so nothing behind the window gets in.

### Capture defaults

- Navi borrows `⇧⌘3` (fullscreen), `⇧⌘4` (area; Space for window), `⇧⌘5`
  (all-in-one bar), and `⌃⇧⌘3` / `⌃⇧⌘4` (the same shots, also copied to the
  clipboard) while it runs. `SystemScreenshotShortcuts` turns the macOS
  ones off at launch (IDs 28, 29, 30, 31, 184 in `com.apple.symbolichotkeys`, then
  `activateSettings -u`) and puts them back exactly as they were on quit. A
  backup from an older run keeps its entries; new IDs are added to it. SIGTERM quits the normal way, so
  `pkill` restores them too. No code runs when the app is deleted, so quitting
  is what gives the keys back. The first launch asks; Settings has a toggle ("Navi Screenshot Keys").
- Area mode (`⇧⌘4`, and the `⇧⌘5` bar in Screenshot or Record) spotlights the
  window under the cursor: the rest of the screen dims, the window gets a purple
  ring and glow, and a label shows its app and pixel size. The highlight glides
  between windows (`WindowHighlight`). A click (under 5 pt of movement) picks
  that window, the same as Space window mode; a drag selects an area, even
  inside a window. Capture Text and scrolling capture have no highlight.
- In the `⇧⌘5` all-in-one bar, a dragged area stays on screen, like macOS:
  drag inside to move it, drag a corner to resize it, then press the bar's
  Capture (or Copy Text, Start Scrolling) button or Return. Picking Record
  hands the area to the record bar at once; in Record mode a drag goes
  straight to the record bar. The record bar's Record Video / Record GIF
  is the only button that starts a recording. `⇧⌘4` still captures as soon
  as the drag ends.
- Other hotkeys: `⌥⇧⌘4` scrolling capture, `⌥⇧⌘T` capture text, `⌥⇧⌘5` record
  (press again to stop), `⌥⇧V` paste last dictation.
- Shots leave out Navi's overlays, cards, pins, and pills (window layer above 0)
  but keep Navi's normal windows, such as the markup editor.
- The selection overlay is a non-activating panel: it takes Esc, Space, and the
  mouse without activating Navi, so an open markup editor is not raised.
- The screen freeze starts before the selection overlay is built. When Navi
  has no normal window open and Hide Desktop Icons is off, it captures each
  display with a filter that leaves out the whole Navi app (cached displays
  and app from launch); otherwise it fetches `SCShareableContent` first. The
  overlay waits for the frozen images, at most 0.1 s, so the dim, frozen
  screen, and magnifier show together with no fade in. The frozen images are
  what gets cropped; a selection that ends first waits for them, off screen.
  The window list for the highlight is read off the main thread. Nothing else
  is built when a shot starts: the spare card panel and the editor window are
  made when Navi is idle (2.5 s after launch, 1 s after each shot).
  The dim and the window ring are GPU layers (`DimView`); the overlay view
  redraws only the rects that changed. On mouse up the shot is handed off
  first, then the overlay leaves the screen. PNG encoding (`PNGEncoder`) runs
  off the main thread; the card shows, then the clipboard copy is written.
  Step times log under `Timing` (`docs/performance.md`).
- Edit after capture uses an editor window built ahead of time
  (`InPlaceAnnotator.Stage`), activates Navi once the drag starts, and orders
  the editor in before the selection overlay leaves, so no frame shows the
  plain screen. While a mark is drawn or moved, the editor redraws only a
  patch around it (`AnnotationRenderer.patch`).
- Area selection is pixel exact: the pixels under both corners of the drag (the
  pixel the magnifier centers on) are in the shot, and the outline shows the
  exact crop. A corner snaps (6 pt) only to a window edge you can see near the
  cursor, never to the hidden edge of a window behind another one, and the
  magnifier shows the snapped point.
- Screen Recording is requested at launch through ScreenCaptureKit
  (`SCShareableContent`), which lists Navi in System Settings, switched off, so
  users only flip the switch.
- Cards stay on the display where the capture was taken.
- The history keeps a recording as MP4, with `<id>.preview.png` for its
  thumbnail; paste from history pastes the file. Background clears the
  `.navi` markup, so the next markup starts from the background image.
- Recording cards show the duration, an MP4/GIF switch on hover, and Trim in
  the bottom-left corner (`⌘E` on hover). Pin, markup, OCR, and background are
  for images only.
- Save puts files in the macOS screenshot folder (`defaults read com.apple.screencapture location`),
  as `Navi 2026-11-06 at 16.10.12.png`, or on the Desktop when that folder is missing.
  Navi's `capture.saveFolder` key overrides both (`CaptureSettings.saveFolder`).
- Edit after capture (`CaptureSettings.editAfterCapture`, off by default; Settings
  toggle "Mark Up Before Copying"): after an area shot (`⇧⌘4`, or
  Capture in the `⇧⌘5` bar, no timer), the frozen screen stays dimmed and the
  area becomes the markup canvas in place (`Annotate/InPlaceAnnotator.swift`),
  with the toolbar floating below it (above it near the bottom, inside it when
  it fills the screen). No window or title bar. The frame can still be
  fixed (`Annotate/FrameAdjuster.swift`): soft corner brackets sit just
  outside it; near the frame they grow, ticks show on all four edges, and a
  move tab (move icon and pixel size) fades in above the frame, apart from the
  top edge (inside it at the top of the screen). Drag any edge or corner to
  resize, the tab to move; the shot is cut again from the frozen screen and the marks stay on
  their pixels (`ScreenPlacement`). One undo puts a whole drag back. A crop
  keeps the kept pixels in place; rotate, flip, or resize lock the frame. The
  dim outside is 0.42. Return or Copy copies the
  marked-up shot, adds it to the history with its marks, and shows "Copied";
  no corner card. Save (`⌘S`) writes it to the save folder and shows "Saved".
  Stash only keeps it in the history and shows "Stashed". Both add it to the
  history and do not copy. Esc or Cancel drops the shot, with no close animation (the
  selection overlay's Esc too). While typing text or cropping,
  Return and Esc end that first. Every editor key (tool letters, `⌘Z`, Delete)
  works. The window editor and this one share `AnnotateToolbar`,
  `AnnotateCanvas`, and `AnnotateKeys`.
- Every screenshot goes to the clipboard as soon as it is taken, and again after
  markup Done (`CaptureSettings.copyToClipboard`, on by default; Settings
  toggle "Copy to Clipboard").
- Each capture is its own history item, even when its pixels match an older
  shot (`Inbox.add(fileData:…, deduplicate: false)`). Saved markup opens only
  while the history file is still that markup's flat image.
- Markup editor keys: V select, A arrow, R rectangle, F filled rectangle,
  O ellipse, L line, P pencil, H highlighter, T text, N counter, B blur,
  X pixelate, S spotlight, C crop. Text: picking the tool opens a box with
  the caret in it, no click needed (at the mouse if it is over the image,
  else a quarter in from the left); a click elsewhere moves an empty box; a click
  outside keeps the text and selects it; drag text with the text or select
  tool; click selected text to edit it; Esc ends typing.
- Copy and Save close the card, like CleanShot X. ⌥ + Copy keeps it open. Show
  in Finder keeps it open.
- While the mouse is on a card: `⌘C` copy, `⌘S` save, `⌘W` close. They are
  Carbon hot keys that exist only during the hover, so other apps keep them.
  `⌘E` annotate, `⌘P` pin. CleanShot X works the same way (shortcuts only
  while the mouse is on the card). Card corners: Pin, Close, Annotate, Show in
  Finder.
- Card drag sends the file URL, so the drop keeps the `Navi … .png` name.
- Corner cards do not close on their own (`autoCloseSeconds` = 0). Close with ✕,
  or Close All Cards (menu, or right-click a card). Cards slide in with a small
  bounce. A fullscreen capture shows the shot and closes it, so macOS plays the
  same shrink as the area overlay. No shutter sound.
- No Restore Closed Card. A closed shot stays in `⇧⌘V` history. `⌘E` on an
  image in that list opens the markup editor (saved marks stay editable); Done
  updates the history item and its open card. `NaviClipboard` reaches capture
  only through `ClipboardFeature.onAnnotate`, wired in the app.
- The Navi menu holds actions only. Every on/off setting, the History
  shortcut, Clear History, and the permissions live in the Settings panel
  (`Settings…`, `⌘,` in the menu; `App/Sources/SettingsPanel.swift` and
  `SettingsView.swift`). It pops up where the Navi menu was (under the menu
  bar icon, or at the mouse after `⌥⇧⌘N`) and looks like that menu: section
  titles, separators, a rounded hover highlight, and its own accent-colored
  switches (AppKit switches draw grey because Navi is never the active app).
  A click anywhere on a row flips it. Esc, ⌘W, or a click away closes it.
- `⌥⇧⌘N` opens the Navi menu at the mouse. The same menu shows from the
  menu bar icon. It is an AppKit `NSStatusItem` menu, built in `NaviMenu`.
- Navi marks its own pasteboard writes with `NaviPasteboard.ownType`, so the
  clipboard watcher does not add a capture twice.

## UX to copy

- **Maccy (clipboard):** keyboard only. Hotkey, type to filter, Return to paste,
  `⌘1`–`⌘9`, `⌥P` pin, `⌥⌫` delete, `⌥⌘⌫` clear, a preview card beside the
  selected row. Line breaks show as `⏎`. Navi adds scope chips under the
  search field (All, Text, Images, Dictation); Tab and ⇧Tab move between them,
  and each open starts at All. Images include screenshots and recordings.
- **CleanShot X (capture):** crosshair with magnifier and pixel size, snap to
  windows, freeze screen. Corner card: on hover it blurs and shows round Copy and
  Save buttons. Corners: Pin (top left), Close (top right), Annotate or Trim
  (bottom left), Show in Finder (bottom right). Drag the card into any app.
  Markup: arrow, box, filled box, ellipse, line, pencil, highlighter, text,
  counter, blur, pixelate, spotlight, crop. Record bar: mic, options, exact
  width × height, fullscreen, then Record GIF or Record Video.
- **Wispr Flow (talk to type):** hold fn to talk, release to type at the
  cursor. Double-tap fn locks hands-free. A small pill at the bottom of the
  screen with a waveform. A cleanup pass removes filler words and adds
  punctuation. On-device Apple speech first, then a small model for cleanup.

Reference code to read, but **do not copy** (license): `sw33tLie/macshot`
(GPL-3.0) and `lzhgus/Capso` (BSL 1.1). Code you **may copy**, with its MIT
notice kept: `anomalyco/hex`. Ideas to borrow: Shottr's pixel ruler,
Xnapper's backgrounds, and macshot's auto-redact.

## Layout

| Path | Holds |
|---|---|
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated and gitignored |
| `App/Sources/NaviApp.swift` | Global hot keys, app wiring |
| `App/Sources/NaviMenu.swift` | Menu bar icon and the Navi menu (`⌥⇧⌘N` opens it at the mouse) |
| `App/Sources/SettingsPanel.swift`, `SettingsView.swift` | Settings panel: toggles, History shortcut, permissions |
| `Packages/NaviCore` | `Inbox` (shared history store), `CaptureItem`, `HotKey` (Carbon global hotkeys) |
| `Packages/NaviClipboard` | Pasteboard watcher, Maccy-style panel, paste |
| `Packages/NaviRecording` | Screen recording engine, record bar, camera bubble, overlays, GIF, trim |
| `Packages/NaviDictation` | Talk to type: fn key, speech, cleanup, pill, paste |
| `Packages/NaviCapture` | Selection overlay and all-in-one bar, ScreenCaptureKit capture, corner cards, `Annotate/`, `Extras/` (pin, OCR, toast), `Scroll/`, `Background/` |
| `docs/capture-plan.html` | Prototype, feature map, and plan |
| `docs/upstream-hex.md` | Hex as the upstream for talk to type: feature map, sync steps |
| `Packages/NaviDictation/Bench` | Dictation benchmark cases and saved results |
| `docs/performance.md` | Speed goal and numbers for every area; capture, recording, and history benchmarks |
| `Packages/NaviClipboard/Bench` | Saved `history-bench` results |

`Inbox` keeps items in `~/Library/Application Support/Navi/` (`history.json`
plus `files/`). Items sort by pinned, then by `lastUsedAt`. The newest 200
unpinned items stay, and separately the newest 200 unpinned dictations
(`dictationLimit`), so dictation does not push out clips and captures. Saves run on a background queue (`HistoryWriter`); call
`Inbox.flush()` before the process exits (`applicationWillTerminate` does).
Search ignores case, accents and character width (`SearchCache`).
New fields on `CaptureItem` must decode from old history
files (use `decodeIfPresent` in `init(from:)`).

## Commands

```sh
xcodegen generate                       # after you change project.yml or add files
~/.local/bin/heavy -- xcodebuild -project Navi.xcodeproj -scheme Navi \
  -configuration Debug -derivedDataPath build.noindex -quiet build
cd Packages/NaviCore && swift test      # unit tests, run directly
cd Packages/NaviCapture && swift test   # capture, markup, stitch, background tests
NAVI_SNAPSHOTS=/tmp/navi-snaps swift test --filter EditorSnapshot  # in NaviCapture: draws the markup editor to PNGs (760/1000/1400 wide, dark and light) and edit after capture (1440 × 900; NAVI_BACKDROP=<png> for a real screen behind it) to check their look
NAVI_TOOLTIP_FRAMES=/tmp/navi-tips swift test --filter TooltipDemo  # in NaviCapture: records the toolbar tooltips as 30 fps PNG frames, for a video
cd Packages/NaviRecording && swift test # recording math, GIF, audio mixdown
cd Packages/NaviDictation && swift test # cleanup rules, fn gestures, fn setting, scoring
cd Packages/NaviDictation && swift run dictation-bench [--audio [--speech apple,parakeet]] [--failures] [--save]
cd Packages/NaviDictation && swift run -c release dictation-bench --latency [--failures]  # release-to-text time for 3 s to 60 s dictations, live and not
cd Packages/NaviClipboard && swift run -c release history-bench [--sizes 200,1000,5000] [--corpus ascii|mixed] [--save]  # History list benchmark
NAVI_HISTORY_SNAPSHOTS=/tmp/navi-history swift test --filter HistorySnapshot  # in NaviClipboard: draws the ⇧⌘V panel to PNGs (each scope, and the order after a dictation)
swift scripts/comments.swift [--fix]  # fails on any comment in Swift code; --fix removes them
scripts/tests/run.sh    # release script tests (plan, notes HTML, Sparkle signature checker, PR title)
scripts/pr-title-check.sh "fix(capture): …"  # checks a PR title the way CI does
MODE=dry-run VERSION=9.9.9 BUILD=1 NOTES=x SKIP_TESTS=1 scripts/ci-release.sh  # release without Apple keys; nothing published
scripts/dev.sh          # build and run Navi Dev in place of Navi (fresh: wipe it first; stop: back to Navi)
```

Releases live on GitHub (`donovanhiland/navi` is public) and are built on
GitHub Actions (`.github/workflows/release.yml`). It runs every night at 10:00
UTC and goes to everyone (no separate nightly channel). A Linux `plan` job runs
`scripts/release-plan.sh`: when `main` has no commits since the last `v*` tag it
stops, before a Mac starts or a key loads; otherwise it picks the next patch
version, the build number (the commit count of `main`, so it only grows), and the
notes (commit subjects since the last tag). The `release` job on `macos-26` runs
`scripts/ci-release.sh` on that exact commit: test every package, archive with
`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` set on the command line, sign
with a "Developer ID Application" certificate, notarize (`notarytool`, App Store
Connect API key), staple, check the app, sign the update with the Sparkle key
(EdDSA; public half is `SPARKLE_PUBLIC_KEY` in `project.yml`, which fills `SUPublicEDKey`), write `appcast.xml`,
and make the release with the tag on the built commit. Nothing is committed, so
the versions in `project.yml` are only for local builds. A failed step stops it
before anything is published. To release now, push to `main` and run
`scripts/release.sh [<version> ["<notes>"]]` (or Actions → Release → Run
workflow). Secrets (`DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`,
`ASC_KEY_P8`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `SPARKLE_PRIVATE_KEY`) are set once
with `scripts/release-secrets.sh`. CI does not use Xcode cloud signing: cloud
signing for Developer ID does not work with an API key. Actions in workflows are
pinned to full commit SHAs.

`scripts/ci-release.sh` has three modes (`MODE`): `publish` (default),
`rehearse` (real keys and notarization, nothing published; the workflow's
"rehearse" box, to check the secrets), and `dry-run` (no Apple keys: ad hoc
signature, no notarization, a throwaway Sparkle key unless one is given,
nothing published). Every mode checks the app (bundle ID, version, build,
`SUFeedURL`, `SUPublicEDKey`, mic and camera entitlements, hardened runtime,
signature; signed modes add Developer ID team, stapled ticket, Gatekeeper)
and checks the feed with `scripts/sparkle-check.swift`, which verifies the
Ed25519 signature with CryptoKit the way Navi does. `publish` also downloads
the published feed and zip and checks them again. Sparkle's `generate_appcast`
leaves the signature out when the key does not match the app's key; the checks
stop on that.

Pull requests: `.github/workflows/ci.yml` runs on each PR and push to `main`:
every package's tests, an unsigned Debug build, a release dry run, and the
release script tests (`scripts/tests/run.sh`: release plan, notes HTML, and the
signature checker against Sparkle's `sign_update`; `shellcheck`). `Check` sums
them up and is the one status to require. `CONTRIBUTING.md` and
`.github/pull_request_template.md` say what a PR needs (one problem, Problem /
Change / Verification, screenshots for UI).

### Commits and PR titles

The repo allows only squash merges. The PR title becomes the one commit on
`main` and one line in the release notes, with ` (#<number>)` added. The PR
body becomes the commit body.

- PR title: `type(scope): what changed`, in plain words a user understands.
  Example: `fix(capture): area shots keep the last pixel row`.
- Types: `feat`, `fix`, `perf`, `refactor`, `docs`, `test`, `ci`, `build`,
  `chore`, `revert`. Scope is optional: lowercase letters, digits, dashes,
  such as `capture`, `history`, `dictation`, `recording`, `release`.
- Describe the result, not the work: "area shots keep the last pixel row", not
  "update CaptureGeometry".
- 100 characters or fewer, no period at the end. `!` after the scope marks a
  change that breaks something.
- The `PR title` workflow (`.github/workflows/pr-title.yml`) runs
  `scripts/pr-title-check.sh` when a PR opens or its title changes. Run the
  script before you open a PR.
- Commits inside a PR are squashed, so their messages are not checked. Use the
  same format for them anyway.
- `chore(release):` lines are left out of the release notes.

Share
`https://github.com/donovanhiland/navi/releases/latest/download/Navi.zip`.
Navi checks `…/releases/latest/download/appcast.xml` daily and from "Check for
Updates…" in the menu. Debug builds never update themselves.

The app icon is drawn by `scripts/make-icon.swift` into
`App/Assets.xcassets/AppIcon.appiconset`.

To build a shareable copy without releasing it, run `scripts/share.sh`. It archives Release,
then Xcode signs it with Developer ID, notarizes it with the Apple account
signed in to Xcode, and staples it. Output: `dist/Navi.zip`. Not
TestFlight or the App Store: both need the app sandbox, which blocks the system
shortcut and paste features.

Test locally with `scripts/dev.sh`. It quits Navi, builds, and runs Navi Dev
(they share shortcuts, so one runs at a time). `scripts/dev.sh fresh` wipes
Navi Dev's permissions, settings, and history first, to test first-run setup.
`scripts/dev.sh stop` quits Navi Dev and reopens Navi. Builds go to
`build.noindex/` so Spotlight lists only the installed Navi. Navi Dev keeps its
history in `~/Library/Application Support/Navi Dev`.

Debug builds are a separate app, **Navi Dev** (`com.donovanhiland.navi.dev`),
signed with the Apple Development certificate, team `77SAW76597`. Release
builds are **Navi** (`com.donovanhiland.navi`), signed with Developer ID by
Xcode's cloud signing during export (no Developer ID private key on this Mac).
macOS ties permissions to the signature, so the two apps get separate
permissions. Donovan's own copy is the release in `/Applications`. `App/Navi.entitlements` (generated from `project.yml`) holds the
microphone and camera entitlements that the hardened runtime needs. Keep a stable signature so macOS keeps the Accessibility and
Screen Recording permissions between builds.

## Rules

- No comments in Swift code. CI runs `swift scripts/comments.swift` and fails on any
  comment. Allowed: `// swift-tools-version` in `Package.swift`, and a license header at
  the top of a file (it must say Copyright and License).
- `@MainActor` on UI and state types. Swift 6 strict concurrency must build
  with no warnings.
- Put pure logic in packages with unit tests (Swift Testing). Test `NaviCore`
  changes with `swift test`.
- After a UI change, build, run, and ask Donovan to check it. Your terminal
  cannot take screenshots of the real screen.
- Skip pasteboard items marked private by password managers (nspasteboard.org
  types).
- Update this file when a decision changes. Write the current state, not the
  history.

## Brain

The project note is `~/Developer/personal/personal-assistant/projects/navi.md`.
It keeps a short summary and status. Put details here, in the repo.
