# Upstream: Hex (talk to type)

Navi's talk to type follows **Hex** (`github.com/anomalyco/hex`), the local
dictation app from the OpenCode team (Anomaly). Hex is best in class for local
dictation. Navi does not invent its own dictation features. It ports Hex's
features into `Packages/NaviDictation` and checks them with the benchmark.

- **License:** MIT. Navi may copy Hex code. Keep Hex's copyright and MIT notice
  in each copied file (a header comment with the source path and commit).
- **Stack:** Hex's core is Rust, with Swift bridges for macOS (`src/*.swift`)
  and an iOS app in Swift (`ios/`). Swift files port almost as is. Rust logic
  ports by hand to Swift.
- **Contributions:** Hex takes no pull requests. Report bugs as issues.

**Last checked:** Hex 3.3.0 (2026-11-02), on 2026-11-07.

## How Hex does dictation

| Part | Hex | Navi now |
|---|---|---|
| Speech to text | Parakeet TDT (default, through FluidAudio), Whisper, Apple Speech (`src/apple_speech.swift`), your own models (`docs/features/own-models.md`) | Parakeet TDT v3 through FluidAudio (`ParakeetEngine.swift`, from Hex). Apple Speech until the model is loaded |
| Filler removal | Rules, no model: um, umm, uh, uhh, erm, er, ah (`src/dictation/filler_words.rs`, Labs, off by default) | Rules (`TextCleanup`), then Apple's model |
| AI cleanup | **Post-processing:** an AI rewrite with your own prompt, sent to a running OpenCode service and the model you pick there (local or cloud). Off until you turn it on (`src/dictation/modes.rs`, `src/desktop/opencode_service.rs`). Also the "Bark Clean" Parakeet model, which drops fillers while it transcribes | Apple's on-device model (`TextCleaner`), on by default, per sentence, only for sentences that need it |
| Modes | Per app or website: its own corrections, rewrite prompt, and transforms (`src/dictation/modes.rs`) | None. One cleanup for all apps |
| Replacements | Global text replacements, then each mode's corrections (`src/dictation/text_replacements.rs`) | None |
| Transforms | Your own JS/TS functions that change text before paste; can call Ollama (`site/public/docs/transforms.md`) | None |
| Raw dictation | A second shortcut pastes the words as heard, with no processing | None |
| Apple Intelligence | Only for meeting notes (`src/apple_intelligence.swift`), not dictation | Dictation cleanup |
| Order of steps | Spoken formatting, spoken symbols, fillers, replacements, mode corrections, OpenCode rewrite, transforms | Fillers (rules), then Apple's model |
| Vocabulary | Vocabulary biasing for Parakeet (`docs/features/vocabulary.md`, Labs) | One list, rescored with FluidAudio's CTC vocabulary boosting (64 terms). Navi also learns words from the clipboard history (`WordLearner.swift`); Hex has no learning |
| Spoken punctuation, formatting | Labs, Output group (`docs/features/labs.md`) | None |
| Live text | Words beside the HUD while you talk (Labs) | "Show Words While Talking" (on by default): one line in the pill, newest words in view. Parakeet previews the newest 10 s every 0.6 s, alongside the sentence passes; Apple speech reports partial results (`LiveText.swift`) |
| Speech while talking | Streaming finish: a live Parakeet stream (Unified English, 1.04 s chunks) fed every 160 ms; the release only finalizes it, with the whole clip as the fallback (`docs/features/dictation.md`, Streaming Finish) | Sentence passes with Parakeet v3 (`LiveDictation.swift`): about once a second and when the user goes quiet, the audio after the last finished sentence is transcribed; finished sentences are cut at a pause in the audio and cleaned at once. The release transcribes only the rest, or reuses the newest pass |
| Microphone | Keep ready (stream open, 450 ms pre-roll) or Release when idle; 200 ms release tail (`docs/features/dictation.md`, Warm And Cold Capture) | "Keep Microphone Ready" (off by default; then the mic is set up but off until the press, like Wispr Flow), 450 ms pre-roll, tail until 200 ms of quiet (40 to 600 ms); input-only AUHAL unit, like Hex's cpal stream, so output audio is never touched (`AudioCapture.swift`) |
| Shortcut | Option by default. Hold, toggle, double-tap; Fn/Globe, keys, mouse buttons | Hold fn, double-tap fn to lock, or "Tap fn to Start and Stop" (toggle) |
| Meetings | Call detection, recording, transcripts, chapters, notes | None |
| CLI | `hex dictation start/stop/toggle`, `hex paste-last`, transcript CLI | None |

## What to port first

Done: **Parakeet speech** (2026-11-07). On `say` audio, word errors went from
20.2% (Apple Speech) to 13.2%, and speech time p50 from 66 ms to 47 ms. With
Apple cleanup, the pass rate went from 37% to 47%.

Done: **Vocabulary** (2026-11-13). Not yet: Hex's "sounds like" spellings in the Settings list (the model and engine take them).

1. **Spoken punctuation and formatting** (the `spoken` and `format` groups).
2. **Transforms**, so cleanup steps are pluggable. Keep Apple's model as one step.

## How to sync

Do this every few weeks, or when Hex ships a release:

1. `gh release list --repo anomalyco/hex --limit 10` and read the notes since
   **Last checked** above (`docs/releases/<version>.md`).
2. Read `docs/features/dictation.md`, `docs/features/labs.md`, and
   `docs/features/vocabulary.md` for new or changed behavior.
3. Pick features that fit Navi. Port them into `Packages/NaviDictation`, with
   the MIT notice in copied files.
4. Add benchmark cases for the feature in `Packages/NaviDictation/Bench/cases.json`,
   then run `swift run dictation-bench --engines rules,apple --save` (and
   `--audio` for speech changes). A port is done when its group improves and
   no other group gets worse.
5. Update **Last checked** and the table above.

## Benchmark

`cd Packages/NaviDictation && swift run dictation-bench` scores cleanup engines
on 51 cases in 9 groups (filler, stutter, correction, list, spoken, terms, keep,
format, ramble). Columns: pass rate, word accuracy, made-up words, fillers left,
and cleanup time. Flags: `--audio` speaks each case with `say` and transcribes it
(`--speech apple,parakeet` picks the speech engines), `--score file.json` scores another app's output (for
example Wispr Flow or Hex: `{"engine": "hex", "outputs": {"<case id>": "<text>"}}`),
`--save` stores a run in `Bench/results/`, `--failures` lists failed cases.
