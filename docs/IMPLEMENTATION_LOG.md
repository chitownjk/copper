# Implementation log

What has been built, how it was verified, and what is still open.
Companion to [BACKLOG.md](BACKLOG.md) (story IDs) and [TECH_PLAN.md](TECH_PLAN.md) (TD-1…TD-8).

**Repo:** `github.com/chitownjk/meeting-companion` (private). Working name is
"Meeting Companion"; the real name is still an open product decision (PRD §8),
and only the repo name and window titles would need to change.

**Status: M1 complete and verified in the shipping binary. M2 partially done.**
The app has no external-binary dependencies — `grep -rn "Process()\|/opt/homebrew"
app/Sources/` matches nothing but comments. On a machine with Apple Intelligence
it records → mixes → transcribes → summarizes with zero configuration.

---

## Package layout (TD-6 groundwork)

| Target | Contents | Maps to (TD-6) |
|---|---|---|
| `MeetingCore` | `AudioMixer`, `TranscriptionEngine` + `WhisperKitEngine`, `WhisperModelStore` + `WhisperModelManager`, `RetentionPolicy`, `RecordingArtifacts`, `DiskSpace`, `Paths` | `CompanionCore` |
| `MeetingProviders` | `SummaryProvider` + 4 backends, templates, map-reduce chunking, `KeychainStore` | `CompanionProviders` |
| `MeetingNotes` | SwiftUI app, DB + migrations, pipeline, calendar, windows | App target |
| `MeetingCoreTests` / `MeetingProvidersTests` | 62 tests, bundled audio fixtures | — |

`CompanionVideoCore` doesn't exist yet — it arrives with E5.

---

## Stories complete

| Story | Notes |
|---|---|
| **E1.1** AVFoundation mixing | Streams in ~1 s chunks; a 2-hour meeting never lands in memory. |
| **E1.2** WhisperKit engine | argmax-oss-swift v1.1.0 (MIT), ANE. Language is a setting. |
| **E1.3** Model manager | Install / verify / delete / cancel, ANE prewarm after download. |
| **E1.5** Crash recovery + disk preflight | Plus a headless `--recover-orphans` path. |
| **E1.6** Remove `claude` CLI | Summarization is best-effort; a transcript always survives. |
| **E2.1–E2.5** Provider layer | Apple FM / Anthropic / OpenAI / local server, templates, provenance. |
| **E3.4** Settings window | Four tabs, deep-linkable, retention policy + daily sweep. |

### Behavioural changes worth knowing

**The mic track is 3 dB louder than it used to be.** The old ffmpeg graph
upmixed the mono mic to stereo through libswresample, scaling it by 1/√2 — so
the old pipeline recorded your own voice below everyone else's. Measured, not
assumed: modelling the reference as `system + mic/√2` matches ffmpeg at 65.6 dB
SNR versus 8.2 dB for a plain sum. Pinned by `AudioMixerGoldenTests`.

**A failed summary no longer fails the meeting.** Mixing and transcription
failing is fatal; summarization failing is not. The meeting reaches `ready`, the
transcript is searchable, and a toast explains what happened. This is E1.6's
acceptance criterion and it also covers rate-limited or offline BYOK.

---

## Verification

**62 tests, 0 failures** (`cd app && swift test`). Golden audio fixtures are
bundled, so nothing needs an environment variable. One test is gated:

```bash
cd app && MEETING_NOTES_RUN_TRANSCRIPTION=1 swift test --filter WhisperKitEngineIntegrationTests
```

Measured, not asserted-from-theory:

| What | Result |
|---|---|
| Mixer output length vs ffmpeg | **Exact** (130,560 frames on the bundled fixture; 491,200 on the full 30.7 s recording) |
| Mixer fidelity vs ffmpeg | 38.0 dB wideband, 61.8 dB below 4 kHz — residual is 6–8 kHz transition-band rolloff only |
| Transcription throughput | 30.7 s of audio in 3.3 s warm (~9× realtime) |
| First transcription after download | **244 s** — Core ML ANE specialization. Now paid during install via prewarm. |
| Model integrity check | Accepts the real 626 MB install, rejects a gutted one |

**Verified by running the release binary on macOS 26.5.2:**

- All three migrations apply to a real database; `integrity_check` and
  `foreign_key_check` clean. The v1→v2 summaries rebuild preserves existing rows
  with NULL provenance.
- All four Settings tabs render without trapping.
- Apple Foundation Models summarizes a real transcript on-device and correctly
  attributes the owner flagged in the notes; a 40k-character transcript
  map-reduces in ~18 s.
- **Full crash-recovery chain**: a staged orphan raises the prompt, and headless
  recovery carries it all the way — `ended_at` stamped from file mtime, a
  mic-only partial mixed, three correct transcript segments off the ANE, an
  on-device summary with provenance recorded, FTS rebuilt. That exercises E1.1,
  E1.2, E1.5, E1.6, E2.1, E2.2 and E2.5 together in the shipping app.

### Launch flags

Support affordances, not test scaffolding — this is a menu-bar app with no dock
icon, so there is otherwise no way into a window from a cold launch.

```bash
.build/release/MeetingNotes --settings=summaries   # general | transcription | summaries | storage
```

```bash
.build/release/MeetingNotes --recover-orphans      # salvage crashed recordings, no UI
```

---

## Open work

### Not started

- **E1.4 SpeechAnalyzer engine.** `TranscriptionEngine` is the seam; add
  `SpeechAnalyzerEngine` and pick it in `Pipeline.engine`. Nothing blocks it,
  and this Mac can run it.
- **E2.6 quick actions.** "Regenerate" / "Shorter" / "As follow-up email" are UI
  only — `Pipeline.regenerateSummary(meetingId:template:)` already does the work.
- **E3.1 Xcode migration**, **E3.2 unified main window**, **E3.3 onboarding
  rewrite**, **E3.5 brand pass**, **E4 signing/DMG/Sparkle**. E3.1 is the hard
  prerequisite for the camera extension and for signing.
- **E5 video pillar.** Untouched. The E5.1 tracer bullet is the single riskiest
  item in the whole plan (TECH_PLAN R1) and should start during M2, not M3.

### Partial

- **Custom summary templates** have a store (`SummaryTemplateStore.custom`) and
  are picked up by the Settings dropdown, but there is no editor UI. Built-ins
  work fully.
- **Per-meeting retention pinning**: the column, the sweep logic, and the
  "Apply Retention Now" button all exist. There is no UI to *set* the pin — that
  belongs in the meeting detail view, which E3.2 rewrites anyway.
- **Onboarding** still uses the old checklist window. It now checks the right
  things (speech model, summarizer) but E3.3 replaces the whole flow.

---

## Concerns

1. **`Database.swift` still `fatalError`s on init.** A corrupt or unwritable
   database kills the app at launch with no message. `Database.shared` is
   non-optional at ~15 call sites, so fixing it is a UI-design question (what
   does the app *do* in that state?), not a mechanical change. Worth a decision
   before shipping to strangers.

2. **The modal recovery alert blocks at launch.** `NSAlert.runModal()` in
   `CrashRecoveryPrompt` runs a nested run loop before the menu bar is usable.
   Correct behaviour, arguably, but with several orphans it means several
   sequential modals. Consider folding recovery into the E3.2 main window.

3. **Provider model catalogs will age.** Anthropic and OpenAI IDs were verified
   against current docs in August 2026 (`claude-sonnet-5` / `claude-opus-5` /
   `claude-haiku-4-5`; `gpt-5.6-terra` / `-luna` / `-sol`). They are hardcoded
   lists and will need periodic checking, or a free-text field with suggestions.

4. **Anthropic runs at `effort: "low"` with thinking on.** Deliberate:
   summarization is not reasoning-heavy, and disabling thinking on current
   models risks `<thinking>` tags leaking into output. If summaries come back
   shallow on long meetings, raise to `medium` before changing anything else.

5. **The 8-second bundled fixture is a slice, not a whole meeting.** Good enough
   for the mixer and a smoke transcription. Chunking behaviour over a genuinely
   long meeting (2 hours, map-reduce across many chunks with a cloud provider)
   has only been tested with synthetic text.

6. **Nothing is signed or notarized**, so the camera extension (which requires
   Developer ID + notarization + `/Applications`) remains entirely unproven.
   That dependency chain — E3.1 → E4.1 → E5.1 — is the critical path to the
   video pillar and none of it has started.

7. **No BYOK provider has been exercised against a live endpoint.** Anthropic,
   OpenAI, and the local-server paths are unit-tested at the parsing and
   error-mapping layer only; no real API key was used. The wire format follows
   current documentation, but first real use may surface something.
