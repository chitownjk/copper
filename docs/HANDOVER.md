# Handover — context from the audit & strategy session (Aug 2026)

Paste-able summary of everything established before implementation started. The authoritative docs are [PRD.md](PRD.md), [TECH_PLAN.md](TECH_PLAN.md), [BACKLOG.md](BACKLOG.md) — read those in full; this file is the map and the "why," so nothing gets re-litigated.

## The mission

Merge two ideas into one polished, standalone macOS product ("Meeting Companion", final name TBD):

1. **Audio pillar** — the existing `app/` codebase: record meetings (mic + system audio), transcribe locally with Whisper, timestamped notes, AI summaries, searchable library.
2. **Video pillar (new)** — a virtual camera that makes you look better in meetings: background blur/replacement, logo/text overlays, and a branded "be right back" standby card instead of a black tile.

Ship quality bar: real installer, in-app Whisper model download, zero Terminal/Homebrew, works for business users / creators / privacy-mandated users, BYOK and local-model options. Positioning: **the private meeting companion** — no bot joins calls, nothing leaves the Mac by default.

## State of `app/` (audited file-by-file)

~2,900 lines Swift, SwiftPM executable, macOS 14+, GRDB only dependency. **The skeleton is good and stays:**

- Menu-bar app (`MenuBarExtra`), `AppState` hub, toasts.
- Dual capture: `MicRecorder` (AVAudioEngine tap with `setVoiceProcessingEnabled(true)` — keeps AEC; deliberate, keep it) + `SystemAudioRecorder` (ScreenCaptureKit audio-only, 2×2 px dummy video config).
- Calendar: EventKit polling, meeting-link detection (Zoom/Meet/Teams/Webex regex-free via NSDataDetector), `AutoRecorder` with arm(2 min)/auto-start(1 min grace) windows.
- Floating notes panel capturing per-line timestamps as you type (a real differentiator — keep).
- Post-meeting `Pipeline` actor: mix → transcribe → summarize → FTS5 rebuild; status enum on `meetings` row drives UI.
- GRDB/SQLite: meetings, segments, note_entries, summaries + FTS5 (porter/unicode61). Library window with search/rename/delete/markdown export.

**What must be replaced (all scheduled in backlog E1/E2):**

- `Mixer` shells out to Homebrew **ffmpeg** → replace with AVFoundation offline mixing (E1.1).
- `Transcriber` shells out to Homebrew **whisper-cli**, model is a manual 1.5 GB curl → embed **WhisperKit**, in-app model manager (E1.2, E1.3). Hardcodes `-l en`.
- `Summarizer` shells out to the **`claude` CLI** (piggybacks the dev's Claude Code login — not shippable) → provider layer (E2).
- `ToolResolver` hardcodes Homebrew paths — deleted when the above land.
- No app bundle/signing/installer/updates; onboarding is a checklist window with copy-a-curl-command UX.
- Known debts: `Database.swift` fatalError on init; delete leaves audio orphaned on disk (make it a retention setting, PRD A7); no crash recovery for `status=recording` orphans (E1.5); single-prompt summarization overflows on long meetings (chunk+reduce, E2.3).
- `spike-audio/` is superseded; delete it.

## Webcamoid verdict (deep survey done — do not redo it)

**TD-1: no fork, no linking, no code reuse. Build video natively.** Evidence:

- **GPL-3.0-or-later, no dual license.** Embedding or even dynamic linking makes the whole app GPL. Separate-process IPC is legally grey and would ship a Qt runtime.
- **Its macOS virtual camera was deleted upstream** (9.4.0, commit `3ef411699`, mid-2026, "unstable… most probably not working"). It was based on the **DAL plugin API deprecated since macOS 12.3**; zero references to the modern CMIO Camera Extension API exist anywhere in its history. Their macOS replacement is local HTTP streaming — not a camera, invisible to Zoom/Meet/Teams.
- **No background blur/segmentation/ML anywhere** (verified greps: onnx/tflite/mediapipe/segmentation = zero hits). No text overlay, no logo plugin. Chroma-key's GPU version moved to a **private sponsors-only submodule** (`WebcamoidPrivate`); public tree has ~20 basic filters.
- Its macOS "installer" compiles from source on the user's machine via Homebrew. Bus factor ≈ 1.
- Worth keeping as *ideas only*: `vcam.h` interface as a vcam-manager checklist; `akglpipeline.cpp` FBO ping-pong chain (maps to a Metal/Core Image node chain).

## Verified external facts (checked Aug 2026 — don't re-verify from stale memory)

- **WhisperKit** is MIT, now shipped in `argmaxinc/argmax-oss-swift` v1.0+ (May 2026) bundling **SpeakerKit** (on-device pyannote diarization → story E7.1) and TTSKit. macOS 14+, CoreML/ANE, models on Hugging Face, plus whisperkit-cli.
- **Apple SpeechAnalyzer/SpeechTranscriber** (macOS 26+): on-device, no download, ~2× faster than whisper-large-v3-turbo, quality strong. Second `TranscriptionEngine` (E1.4).
- **Apple Foundation Models** (macOS 26+, Apple Silicon, Apple Intelligence enabled): free on-device LLM — the zero-setup default summarizer (E2.2).
- **CMIO Camera Extensions**: require Developer ID signing + notarization, `com.apple.developer.system-extension.install` entitlement, shared App Group, and the app running from **/Applications**. Reference implementations: Apple WWDC22 sample ("Create camera extensions with Core Media IO"), OBS Studio PR #7777. This is the only supported virtual-camera path; it works in Zoom/Chrome/Teams/Safari/FaceTime.

## Decisions locked (TECH_PLAN TD-1…TD-8, don't reopen)

1. **TD-1** No webcamoid code — native video stack.
2. **TD-2** Transcription = WhisperKit (primary) + SpeechAnalyzer (26+) behind a `TranscriptionEngine` protocol; in-app model manager, default quantized large-v3-turbo (~600 MB class).
3. **TD-3** Summarization = `SummaryProvider` protocol: Apple Foundation Models (default when available) / Anthropic BYOK / OpenAI BYOK / Ollama-compatible local server. Keys in Keychain. No bundled cloud inference at launch.
4. **TD-4** Virtual camera = CMIO Camera Extension embedded in app bundle; app pushes composited frames via the extension's **sink stream**; extension serves branded placeholder when app closed; extension process stays dumb (hard rule).
5. **TD-5** Effects pipeline = AVCaptureSession → Vision `VNGeneratePersonSegmentationRequest` (temporal-smoothed mask) → Core Image on Metal (blur/replace/overlays/lower-third/standby card) → tee to sink stream + preview. Perf budget: 1080p30, ≤25% of one perf core + ANE on M1, degrade ladder to passthrough.
6. **TD-6** Migrate SwiftPM exe → Xcode workspace: App target + CameraExtension target + local packages `CompanionCore` / `CompanionVideoCore` / `CompanionProviders`.
7. **TD-7** Distribution = Developer ID + notarized DMG (move-to-/Applications nudge) + Sparkle 2 (EdDSA appcast). No Mac App Store at launch. Paddle/LemonSqueezy for licensing later (E8.2).
8. **TD-8** macOS 14+, **Apple Silicon only**.

## Execution order (BACKLOG has full stories + acceptance criteria)

- **M1** zero-dependency audio core: E1.1 AVFoundation mixing, E1.2 WhisperKit, E1.3 model manager, E1.5 crash recovery, E1.6 remove claude-CLI, E2 provider layer.
- **M2** shippable app: E3.1 Xcode migration (prereq for everything below), E3.2 unified main window, E3.3 onboarding flow, E3.4 settings, E4 signing/DMG/Sparkle. **During M2: run the E5.1 tracer bullet** (minimal extension showing a test pattern selectable in Zoom) — it's the highest-risk item (R1); don't wait for M3.
- **M3** video MVP: E5 (extension, pipeline, segmentation/backgrounds, overlays, standby cards, camera onboarding step).
- **M4** depth: E7.1 diarization (SpeakerKit), E7.2 playback synced to transcript, E6 presets/auto-preset/enhance.
- **M5** launch: privacy page/license audit, paywall, website, beta.

**Start with E1.1 + E1.2 in parallel** — pure Swift, high certainty, kills two of three Homebrew deps.

## Escalation guidance

E5.1 (camera extension) is the one story where difficulty is structural, not effort: silent failures (extension installs but never appears in pickers), entitlement/provisioning coupling, sink-stream handshake quirks. Break it down before starting (it's marked XL); the breakdown must keep the dumb-extension/smart-app boundary. If it stalls, say so rather than restructuring around the blocker — the user may route that story to a different session/model.

## Open product decisions (user-owned, don't decide unilaterally; none block M1/M2)

1. Brand name + domain (candidates in PRD §8; E8.5 is the trademark check).
2. Pricing: one-time vs. subscription vs. hybrid (PRD §7 has the proposed Free/Pro split).
3. Diarization: Pro-gated vs. launch splash feature.
