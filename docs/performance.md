# Performance

## Speed goal

Goal: every area of Navi is at least 2× faster than `main` at `ce7cc78`. Each number below is a median, measured on an Apple M5 Pro with macOS 27.0.1, release build, with the old and new code run one after the other on the same machine.

| Area | What is timed | Before | After | Faster |
|---|---|---:|---:|---:|
| Capture | PNG of a 3K area (`png-encode-area-3k`) | 24.2 ms | 4.1 ms | 5.9× |
| Capture | PNG of a full 5K screen (`png-encode-full-5k`) | 117 ms | 17.6 ms | 6.7× |
| Capture | Screen freeze source (`SCShareableContent`, warm) | 20 ms | 8 ms, or none with the fast path | 2.5× |
| Capture | Window shot wait before the capture | 150 ms | 0 ms when the app is still active | — |
| Capture | Selection overlay redraw per mouse move, 3K screen | 7–13 ms (full screen) | only changed rects; the dim and ring are GPU layers | — |
| Markup | Frame while drawing or moving a mark, 5K (`markup-drag-*`) | 10.9 ms | 0.45 ms | 24× |
| Markup | Save markup (`markup-store-save-3k`) | 51.4 ms | 8.2 ms | 6.3× |
| Markup | Open edit after capture (`editor-open-*`) | 34 ms | 19 ms, window on screen at about 10 ms | 1.8–3× |
| Background | Render, 3K (`background-render-3k`) | 62.7 ms | 12.0 ms | 5.2× |
| OCR | First Capture Text after a macOS update | 25–40 s | about 0.1 s (warmed in the background) | — |
| Scroll capture | Frames per second while scrolling | about 5.5 | about 11 | 2× |
| History | See Current numbers below | | | 2–40× |
| Clipboard | TIFF copy to history, total (`watcher-image-tiff-total`) | 29.3 ms | 5.5 ms | 5.3× |
| Recording | GIF, 75 frames | 550 ms | 130 ms | 4.2× |
| Recording | Trim export, 2.5 s | 19.5 ms | 4.5 ms | 4.3× |
| Dictation | Release to text | done in #21 | | |

Not at 2×: warm OCR (about 75 ms, all inside Vision), scroll frame registration (about 7.5 ms, Vision), audio mixdown of short clips (about 12 ms of fixed AVFoundation cost), and recording stop (about 8 ms, `finishWriting`).

### Capture and markup benchmarks

```sh
cd Packages/NaviCapture
NAVI_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter SpeedBench
NAVI_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter UIPathBench
```

`NAVI_BENCH_IMAGE=<png>` uses a real screenshot instead of the synthetic one. `UIPathBench` opens real windows; its draw times are only real while the screen is unlocked.

`PNGEncoder` (NaviCore) writes PNGs in parallel: the image is split into row bands, each band is filtered and deflated (zlib level 3) on its own core, and the bands are joined with sync flushes into one zlib stream. It keeps the color profile, the DPI, and the exact pixels, and drops the alpha channel when every pixel is opaque. Images with more than 8 bits per channel use ImageIO.

### Screenshot flow

The app logs each step under category `Timing`:

```sh
log stream --level info --predicate 'subsystem == "com.donovanhiland.navi" AND category == "Timing"'
```

`select →` steps start at the shortcut; `shot →` steps start at mouse up.

Live numbers in the real app (M5 Pro, 3K screen, Debug build with `SWIFT_OPTIMIZATION_LEVEL=-O`, median of four warm runs; "first" is the first shot after launch):

| Step | Before | After |
|---|---|---|
| Shortcut to overlay and frozen screen ready | 131 ms (first 602 ms); the overlay showed the live screen first, then the frozen screen | 67 ms (first 165 ms), shown together |
| Mouse up to corner card on screen | 72 ms | 38 ms |
| Mouse up to edit-after-capture editor on screen | 74 ms (first 620 ms) | 45 ms (first 72 ms) |

Plain Debug builds do not optimize `PNGEncoder`, so the card step is slower there than with ImageIO. Measure with `-O` or Release.

### Recording benchmark

```sh
cd Packages/NaviRecording && NAVI_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter SpeedBench
```

## History benchmark

`history-bench` times the History list (`⇧⌘V`) on synthetic histories of 200, 1,000 and 5,000 items. It never reads or writes your real history.

Run it from the package folder, in release. It needs the Xcode toolchain: `xcode-select -p` must point at `Xcode.app`, not Command Line Tools, or the SwiftUI macros do not build.

```sh
cd Packages/NaviClipboard && swift run -c release history-bench --save
```

| Option | Default | Meaning |
|---|---|---|
| `--sizes 200,1000,5000` | 200,1000,5000 | History sizes to seed and time |
| `--iterations N` | 20 | Timed runs per scenario at 1,000 items and up, after three discarded warm-up runs. Smaller sizes get more, see below |
| `--seed N` | 42 | Seed for the synthetic history. The same seed gives the same content |
| `--corpus ascii\|mixed` | ascii | Language of the seeded text. `mixed` seeds accented Latin (ã õ ç é ê á í ó ú à), Cyrillic, Japanese, Arabic, Hindi and emoji items, one script per item |
| `--json` | off | Print the report as JSON instead of a table |
| `--save` | off | Write `Bench/results/<date>-<commit>.json` (date to the second, commit = short HEAD when run) |

### Iteration rule

Small histories finish in microseconds, where timer noise and warm-up drift dominate, so they get more timed runs. Each size gets `--iterations × max(1, 1000 / size)` timed runs. At the default of 20, that is 100 runs at 200 items, 20 at 1,000 items and 20 at 5,000 items. Every scenario runs three untimed warm-up runs first.

### How the history is built

Each size gets a fresh temporary directory, deleted at the end. The bench writes `history.json` and `files/` in the format `Inbox` reads.

- 80% text items, 20 to 4,000 characters, words from a fixed vocabulary.
- 20% PNG images: two 2560×1600 and two 800×600 pictures, rendered once and reused.
- The inbox limit is size + 100, so no seeded item is evicted.

### Scenarios

| Scenario | What it times |
|---|---|
| `load` | `Inbox(directory:limit:)`: reads and decodes `history.json`, then sorts |
| `add` | `Inbox.add(text:)` on a full inbox: what the main actor pays. The background save is handed off, not waited for. The added item is removed and flushed outside the timer |
| `save-flush` | `Inbox.add(text:)` plus `Inbox.flush()`: the total persistence cost, including the background encode and write |
| `add-large-mixed` | `Inbox.add(text:)` of a 2 MB Cyrillic, Japanese and emoji text on a full inbox: the main-actor cost, as in `add`. The save and its search key are built in the background, so they are not in this time |
| `search-common` | `Inbox.search("the")`, which matches most text items |
| `search-rare` | `Inbox.search("quartz")`, which matches about 7% of text items |
| `search-none` | `Inbox.search("zzqxv")`, which matches nothing |
| `search-accent-on-ascii` | `Inbox.search("ação")` on the ASCII corpus |
| `search-cold`, `search-warmup` | The first search on a fresh inbox, and the background key build; see How it works |
| `search-cold-huge` | The first search (`привет`) on a fresh inbox that also holds a 2 MB text with no key yet. That text must be left out and counted as deferred, not folded |
| `search-mixed-cyrillic`, `-japanese`, `-arabic`, `-hindi`, `-emoji`, `-accent`, `-none` | With `--corpus mixed`: a word in each script, `😀`, `acao` (finds `ação`), and `zzqxv` |
| `search-mixed-cold-cyrillic`, `-japanese`, `-arabic`, `-hindi`, `-emoji` | With `--corpus mixed`: the first search on a fresh inbox. The `deferred` column is how many items it left out |
| `results` | `ClipboardModel.results` after the query is cleared, then set to `the` (`привет` with `--corpus mixed`). Each run is a real search, plus model overhead |
| `results-repeat` | `ClipboardModel.results` read again with nothing changed, so it is answered from the memo. No search runs |

Each scenario reports the median, p95 and minimum in milliseconds. `matches` is the number of items the last run returned.

## Signposts

The History code emits `os_signpost` intervals under subsystem `com.donovanhiland.navi`, category `History`.

| Interval | Where | Covers |
|---|---|---|
| `PanelShow` | `ClipboardPanelController.show()` | From the call until the panel is ordered front. The panel is built earlier, by `prepare()` at launch |
| `Search` | `ClipboardModel.results` | Filtering the inbox, only when the query or the history changed |
| `RowImage` | `ClipboardModel.thumbnail(for:)` | A cache miss: decoding the row thumbnail off the main actor |
| `InboxSave` | `Inbox` (NaviCore) | Encoding and writing `history.json` |

Rows show a thumbnail of at most 400 pixels, decoded in the background (`ClipboardModel.thumbnail(for:)`). The preview card decodes its image off the main actor, at card size (`ClipboardModel.previewImage(for:)`).

### Recording a trace

Start the debug app first, then run this. It attaches to the process named `Navi` for 60 seconds. Open the History panel several times while it records.

```sh
xcrun xctrace record --template 'Time Profiler' --instrument 'os_signpost' --instrument 'Points of Interest' --attach Navi --time-limit 60s --output "$HOME/Desktop/navi-history.trace"
```

Open the `.trace` file in Instruments. In the `os_signpost` track, filter by subsystem `com.donovanhiland.navi`. The intervals above appear under category `History`.

## Current numbers

Goal: every main-thread scenario has a p95 under 16.6 ms (one 60 Hz frame) at 200, 1,000 and 5,000 items. **Met** on both corpora.

5,000 items, median in ms, on Apple M5 Pro, macOS 27.0.1, release build, seed 42. Before is `main` at `ce7cc78`; both runs used the same bench sources, one after the other.

| Scenario | ascii before | ascii after | mixed before | mixed after |
|---|---:|---:|---:|---:|
| `load` | 4.70 | 1.37 | 7.94 | 2.89 |
| `add` | 0.48 | 0.061 | 0.65 | 0.083 |
| `add-large-mixed` | 1.18 | 0.045 | 1.25 | 0.050 |
| `search-common` | 1.42 | 0.29 | | |
| `search-rare` | 4.49 | 0.14 | | |
| `search-none` | 4.20 | 0.14 | 8.74 | 0.21 |
| `search-mixed-*` | | | 6.6–8.7 | 0.21–0.27 |
| `search-cold` | 6.11 | 1.39 | 6.2 | 2.75 |
| `results` | 1.34 | 0.26 | 7.7 | 0.32 |
| `save-flush` (background) | 25.8 | 2.54 | 37.8 | 4.76 |
| `search-warmup` (background) | 10.0 | 2.41 | 159 | 38.6 |
| `watcher-text` | 0.59 | 0.10 | | |
| `paste-image` | 9.4 | 0.27 | | |
| `thumbnail-large` | 8.8 | 0.68 | | |
| `preview-large` | 7.9 | 2.4 | | |

`--only a,b` runs a subset of scenarios.

## Baseline

Recorded on:

- Machine: Apple M4 Pro, macOS 27.2 (26B123)
- Toolchain: Xcode's Swift and SDK (macOS 27.2), release build
- Settings: seed 42, 20 timed runs per scenario at 1,000 and 5,000 items, 100 at 200 items, 3 warm-up runs
- Commit: `3356977`, the commit the code was built on before this change

The two runs were made one after the other, at 21:20:24 and 21:20:36 on 2026-11-10. Both are in `Packages/NaviClipboard/Bench/results/`: `2026-11-10T21.20.24-3356977.json` and `2026-11-10T21.20.36-3356977.json`.

### 200 items (history.json 380 KB)

| Scenario | Median, run 1 (ms) | Median, run 2 (ms) | Spread | p95, run 2 (ms) | Matches |
|---|---:|---:|---:|---:|---:|
| load | 0.702 | 0.687 | -2.2% | 0.794 | - |
| add | 1.821 | 1.814 | -0.4% | 2.424 | - |
| search-common | 0.320 | 0.323 | +0.9% | 0.362 | 155 |
| search-rare | 1.402 | 1.401 | -0.0% | 1.636 | 14 |
| search-none | 1.450 | 1.444 | -0.4% | 1.539 | 0 |
| results | 0.322 | 0.323 | +0.5% | 0.373 | 155 |
| thumbnail-open | 0.135 | 0.131 | -3.0% | 0.163 | - |
| thumbnail-draw | 1.691 | 1.682 | -0.5% | 1.923 | - |

### 1000 items (history.json 1825 KB)

| Scenario | Median, run 1 (ms) | Median, run 2 (ms) | Spread | p95, run 2 (ms) | Matches |
|---|---:|---:|---:|---:|---:|
| load | 3.483 | 3.494 | +0.3% | 3.812 | - |
| add | 7.679 | 7.868 | +2.5% | 10.244 | - |
| search-common | 1.749 | 1.675 | -4.2% | 3.037 | 746 |
| search-rare | 6.743 | 6.692 | -0.8% | 8.020 | 64 |
| search-none | 7.020 | 6.997 | -0.3% | 7.195 | 0 |
| results | 1.729 | 1.668 | -3.5% | 1.839 | 746 |
| thumbnail-open | 0.143 | 0.134 | -5.9% | 0.285 | - |
| thumbnail-draw | 11.018 | 8.956 | -18.7% | 9.089 | - |

### 5000 items (history.json 8918 KB)

| Scenario | Median, run 1 (ms) | Median, run 2 (ms) | Spread | p95, run 2 (ms) | Matches |
|---|---:|---:|---:|---:|---:|
| load | 17.333 | 17.315 | -0.1% | 18.434 | - |
| add | 36.203 | 35.937 | -0.7% | 37.624 | - |
| search-common | 8.662 | 8.683 | +0.3% | 9.067 | 3704 |
| search-rare | 33.261 | 33.277 | +0.0% | 33.600 | 280 |
| search-none | 34.439 | 34.271 | -0.5% | 34.624 | 0 |
| results | 8.635 | 8.427 | -2.4% | 8.809 | 3704 |
| thumbnail-open | 0.133 | 0.144 | +8.5% | 0.254 | - |
| thumbnail-draw | 1.699 | 1.711 | +0.7% | 2.076 | - |

### Run-to-run variance

Spread is run 2 against run 1, on the median. The target is within 15% for every scenario at every size.

- 200 items: every scenario is within 3%. Met, with the iteration rule above.
- 5,000 items: every scenario is within 9%. Met.
- 1,000 items: every scenario but one is within 6%. `thumbnail-draw` moved 18.7% (11.0 ms to 9.0 ms), which misses the target. Two more runs at 1,000 items, not saved, gave 9.76 ms and 9.76 ms, so run 1 looks like an outlier: its p95 was 28.9 ms against 9.1 ms in run 2. The cause is not established. Compare `thumbnail-draw` changes with a fresh pair of runs before trusting a difference under 20%.

No scenario has a median under 0.1 ms, so none is below timer resolution.

## How it works

- **Saving** (`HistoryWriter`): `Inbox` hands each snapshot to a serial background queue. A newer snapshot replaces one that has not started writing. Files of removed items are deleted after the snapshot that drops them is written. `Inbox.flush()` waits for the queue; the app calls it on quit.
- **Loading** (`CaptureItem.decodeHistory`): a `history.json` over 512 KB is cut at item boundaries and the pieces decode in parallel. If a piece fails, the whole file decodes on one thread. The format on disk is unchanged.
- **Memoized results** (`ClipboardModel.results`): the last search is kept until the query, the items or the search keys change. A repeated read is a comparison, not a search.
- **Warm thumbnails** (`ClipboardModel.keepThumbnailsWarm()`): the first 40 rows decode their thumbnails at launch and again whenever the history changes. A row and the prewarm share one decode of the same image.
- **Card image** (`ClipboardModel.previewImage(for:)`): the preview card decodes at most 960 pixels on its long side, off the main actor. It waits 150 ms first, so holding an arrow key decodes nothing. The cache holds this card-size copy, not the full image.
- **Panel at launch** (`ClipboardPanelController.prepare()`): the panel and its list view are built and sized at launch, so the first open does not build them.
- **Search** (`SearchCache`): each item has a key, the bytes of its text and source app after `String.folding` with case, accents and width ignored (`acao` finds `ação`). A search folds the query the same way and looks for it with `memmem`.
  - A new item up to 16 KB gets its key when added; a bigger one in the background. After launch a background task builds the keys of the loaded items, 500 at a time.
  - Until the keys exist, a search builds missing ones up to 16 KB itself for at most `Inbox.searchBudget` (6 ms). Items still without a key are left out of that search and counted in `Inbox.deferredSearchItems`. Each installed batch changes `Inbox.searchKeysVersion`, so the list refreshes by itself as keys land.
