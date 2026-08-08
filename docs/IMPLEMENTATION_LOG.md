# Implementation log — M1

What actually landed, what is partial, and what the next session needs to know.
Companion to [BACKLOG.md](BACKLOG.md) (story IDs) and [TECH_PLAN.md](TECH_PLAN.md) (TD-1…TD-8).

**Status: M1 is functionally complete.** The app has zero external-binary
dependencies. `grep -rn "Process()\|/opt/homebrew" app/Sources/` returns nothing
but comments. A clean Mac can record → mix → transcribe → summarize with no
Terminal use.

---

## Package layout (TD-6 groundwork)

`app/Package.swift` now has four targets instead of one executable:

| Target | Contents | Maps to (TD-6) |
|---|---|---|
| `MeetingCore` | `AudioMixer`, `TranscriptionEngine` + `WhisperKitEngine`, `WhisperModelStore`, `Paths`, `DiskSpace` | `CompanionCore` |
| `MeetingProviders` | `SummaryProvider` protocol + 4 backends, templates, chunking, Keychain | `CompanionProviders` |
| `MeetingNotes` | SwiftUI app, DB, pipeline, calendar, windows | App target |
| `MeetingCoreTests` / `MeetingProvidersTests` | 43 tests | — |

The Xcode migration (E3.1) inherits an already-separated core. `CompanionVideoCore`
does not exist yet — it arrives with E5.

---

## Stories completed

| Story | Notes |
|---|---|
| **E1.1** AVFoundation mixing | `MeetingCore/AudioMixer.swift`. Streams in ~1 s chunks; a 2-hour meeting never lands in memory. |
| **E1.2** WhisperKit engine | argmax-oss-swift v1.1.0 (MIT). ANE by default. Language is a setting, not hardcoded `en`. |
| **E1.5** Crash recovery + disk preflight | `MeetingNotes/CrashRecovery.swift`, `MeetingCore/DiskSpace.swift`. |
| **E1.6** Remove `claude` CLI | `Summarizer.swift`, `SubprocessRunner.swift`, `ToolResolver.swift` deleted. |
| **E2.1** Provider protocol + registry | `SummaryProvider`, `SummaryProviderRegistry`. Schema migration `v2_summary_provenance`. |
| **E2.2** Apple Foundation Models | Compiled against the macOS 26 SDK, gated at runtime; reports `.unavailable` with a specific reason on 14/15. |
| **E2.3** Anthropic + OpenAI BYOK | Keys in Keychain. Chunk+reduce for long transcripts. Live key validation at save time. |
| **E2.4** Local server | Ollama/LM Studio via the shared OpenAI-compatible client; connection test verifies the model is actually present. |
| **E2.5** Templates | 5 built-ins + custom. Summaries are multi-row; history pruned to the last 3. |

---

## Two behavioural changes worth knowing

**1. The mic track is 3 dB louder than it used to be.** The old ffmpeg graph
(`amix=inputs=2:duration=longest:normalize=0` → `-ar 16000 -ac 1`) silently
upmixed the mono mic to stereo through libswresample, scaling it by 1/√2 — so
the old pipeline recorded your own voice below everyone else's. Measured, not
assumed: modelling the reference as `system + mic/√2` matches ffmpeg at 65.6 dB
SNR vs 8.2 dB for a plain sum. `AudioMixer` sums at unity. Pinned by
`AudioMixerGoldenTests`; revert by scaling the mic reader if you disagree.

**2. A failed summary no longer fails the meeting.** Previously any summarizer
error set `status = failed` and the transcript was invisible in the UI. Now
mixing and transcription failing is fatal; summarization failing is not — the
meeting reaches `ready`, the transcript is searchable, and a toast explains what
went wrong. This is E1.6's acceptance criterion, and it also covers the
rate-limited / offline BYOK case.

---

## Verification performed

- **43 tests, 0 failures.** 3 are env-gated (below) and skip by default.
- **Mixer vs ffmpeg on the real 30.7 s dual-track recording**: output length
  **491,200 frames — exactly ffmpeg's**. 37.6 dB wideband SNR, 60.3 dB below
  4 kHz. The wideband residual is entirely 6–8 kHz transition-band rolloff
  (Apple mastering SRC vs soxr), verified by band-limiting.
- **End-to-end transcription**: 8 segments, ordered, in-bounds, text matching
  the checked-in whisper-cli reference. **30.7 s of audio in 3.3 s warm (~9×
  realtime)**; 626 MB model.
- **Schema migration**: `v1 → v2` simulated against a populated v1 database —
  rows preserved with NULL provenance, `PRAGMA foreign_key_check` clean, cascade
  delete still works.

```bash
cd app && MEETING_NOTES_GOLDEN_DIR=../spike-audio/output swift test
```

```bash
cd app && MEETING_NOTES_RUN_TRANSCRIPTION=1 MEETING_NOTES_GOLDEN_DIR=../spike-audio/output swift test --filter WhisperKitEngineIntegrationTests
```

---

## Partial / not done — read before picking this up

### E1.3 model manager — service layer only

`WhisperModelStore` has the catalog, paths, `isDownloaded`, `installedBytes`,
and a working in-app download with progress (wired into onboarding). **Missing
against the AC**: resume-after-network-drop, checksum validation, delete/
re-download, and the model picker UI. The picker needs the Settings window
(E3.4, M2) — the service API is ready for it.

**Related and important**: the first transcription after download took **244 s**
versus 3.3 s warm. That is Core ML specializing the model for the ANE. Onboarding
should prewarm (`WhisperKitEngine.prepare` with `prewarm: true`) right after the
download completes, or the first real meeting pays it.

### E1.4 SpeechAnalyzer engine — not started

`TranscriptionEngine` is the seam; add `SpeechAnalyzerEngine` and pick it in
`Pipeline.engine`. Nothing blocks it.

### E2.6 quick actions — not started

"Regenerate" / "Shorter" / "As follow-up email" are UI. The backing call exists:
`Pipeline.regenerateSummary(meetingId:template:)` runs a new generation against
the stored transcript and prunes history to 3.

### No Settings UI for any of this

Everything the provider layer needs is exposed and testable —
`SummaryProviderRegistry.statuses()` returns one row per backend with its
blocker and privacy label, `validateConfiguration()` powers a Test-connection
button, `KeychainStore` handles keys. But there is **no window to put it in**
until E3.4. Right now a provider can only be configured by writing to
UserDefaults/Keychain directly. This is the biggest gap between "M1 works" and
"a stranger can use it".

---

## Concerns to escalate

1. **This directory is not a git repository.** Everything above is unversioned.
   `git init` before more work lands. I did not run it — creating a repo and
   committing is the user's call.

2. **Model IDs in provider catalogs will age.** `AnthropicProvider.models` and
   `OpenAIProvider.models` hardcode current model IDs. The Anthropic list was
   checked against current docs; **the OpenAI list (`gpt-5.1`, `gpt-5.1-mini`)
   was not verified against OpenAI's API** — I have no authoritative source for
   it in this session. Verify before shipping, or make the model field free-text
   with a suggestion list.

3. **The Anthropic provider runs at `effort: "low"` with thinking on.** That is
   deliberate: summarization is not reasoning-heavy, and disabling thinking on
   current models risks `<thinking>` tags leaking into output. If summaries come
   back shallow on long meetings, raise to `medium` before changing anything else.

4. **`spike-audio/` still exists** and TECH_PLAN §7 says delete it. Its
   `output/` directory is the only real-world fixture and both golden tests point
   at it via `MEETING_NOTES_GOLDEN_DIR`. Relocate those three WAVs (ideally
   trimmed to ~8 s, regenerating the ffmpeg reference from the trimmed inputs)
   before deleting the spike.

5. **`Database.swift` still `fatalError`s on init.** Listed as a known debt in
   the handover; untouched because `Database.shared` is non-optional at ~15 call
   sites and making it recoverable is a UI question, not a mechanical one.

6. **The E1.2 acceptance criterion is only partly verified.** The AC asks for
   timestamps within ±500 ms of whisper-cli output. Neither `whisper-cli` nor the
   ggml model is installed on this machine, so no timestamped reference could be
   produced. Verified instead against the checked-in reference *text* plus
   ordering/bounds invariants. Installing whisper-cpp + the 1.5 GB ggml model
   would close it.

7. **Untested at runtime**: the Apple Foundation Models provider (needs macOS 26
   with Apple Intelligence on), the crash-recovery prompt (needs a real
   `kill -9` mid-recording), and the disk watchdog (needs a nearly-full volume).
   All three compile and their logic is straightforward, but none has been
   exercised end-to-end.
