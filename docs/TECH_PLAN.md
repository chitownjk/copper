# Meeting Companion — Technical Plan

**Status:** Draft v1 · August 2026
**Companion docs:** [PRD.md](PRD.md) · [BACKLOG.md](BACKLOG.md)

This document records the architecture audit of both codebases, the key technical decisions (TD-1…TD-8), the target architecture, and the risk register. It is written to be executed against by an engineering agent without further strategy discussion.

---

## 1. Audit — `app/` (the audio product)

~2,900 lines of Swift, SwiftPM executable, macOS 14+, GRDB 6 as the only dependency.

**Architecture as-built:** menu-bar `MenuBarExtra` app (`MeetingNotesApp.swift`) → `AppState` (observable hub) → `RecordingSession` spawning two writers: `MicRecorder` (AVAudioEngine input tap, with `setVoiceProcessingEnabled(true)` for AEC/AGC — a good call, keeps meeting speaker audio out of the mic track) and `SystemAudioRecorder` (ScreenCaptureKit audio-only stream). Post-meeting `Pipeline` actor: mix (ffmpeg) → transcribe (whisper-cli subprocess, JSON parse) → summarize (`claude` CLI subprocess) → FTS5 rebuild. `CalendarService` + `AutoRecorder` handle EventKit polling, meeting-URL detection, and arm/auto-start windows. UI: library window (list/detail with summary/notes/transcript), floating notes panel with per-line timestamp capture, onboarding checklist window, toast presenter.

**Verdict: keep the skeleton, replace the tendons.** The domain model (meetings/segments/notes/summaries + FTS5), the capture layer, the calendar/auto-record logic, and the notes-timestamping design are sound and stay. Everything that shells out (`ToolResolver`, `SubprocessRunner` consumers: `Mixer`, `Transcriber`, `Summarizer`) is scaffolding to be replaced by embedded frameworks — a consumer product cannot depend on Homebrew, a hand-curled 1.5 GB model, or the user having Claude Code installed.

Specific debts to clear along the way:

- `Database.swift` `fatalError` on init failure → recoverable error UI.
- `LibraryModel.deleteSelected` deletes DB rows but leaves audio on disk with no retention policy (fine as a choice, but must become an explicit setting — PRD A7).
- No recovery for `status=recording` orphans after a crash (BACKLOG E1.5).
- `Transcriber` hardcodes `-l en` (language must become a setting).
- Whole-transcript-in-one-prompt summarization will overflow provider context on long meetings (chunk+reduce needed — E2.3).
- `spike-audio/` is a superseded spike; archive or delete it.

## 2. Audit — `webcamoid/` (findings that drive the decision)

Full report from the code survey, condensed to what matters:

1. **License is GPL-3.0-or-later, no dual licensing.** Embedding or linking (static *or* dynamic) makes our whole app a GPLv3 derivative — fatal for a proprietary product. Even the "separate process over IPC" arrangement is legally grey and would mean shipping a Qt runtime beside a Swift app.
2. **The macOS virtual camera no longer exists.** Removed upstream in 9.4.0 (commit `3ef411699`, mid-2026) as "unstable, barely maintained, most probably not working." What was removed was a loader for the separate AkVirtualCamera project, built on the **DAL plugin API that Apple deprecated in macOS 12.3**. There are zero references to the modern CMIO Camera Extension API anywhere in the tree or its history. Webcamoid's macOS "replacement" is local HTTP streaming, which does not appear in Zoom/Meet/Teams device pickers.
3. **The effects we want don't exist there.** No person segmentation, no background blur/replacement, no ML anywhere (verified: zero hits for onnx/tflite/mediapipe/segmentation). Text overlay: never existed. Logo overlay: no dedicated plugin. Chroma-key exists, but its current GPU version lives in a **private sponsors-only submodule** (`WebcamoidPrivate`); the public tree is down to ~20 basic filters (blur, contrast, crop, flip…).
4. **Distribution model is disqualifying:** the macOS "installer" installs Homebrew and Xcode CLT on the end user's machine and compiles from source. The project gave up on signing/notarization.
5. **Worth stealing as ideas only:** the `VCam` abstract interface (`vcam.h`) as a checklist for what a virtual-camera manager needs (install detection, device lifecycle, format negotiation, placeholder frame when idle); the FBO ping-pong effect-chain (`akglpipeline.cpp`), which maps 1:1 onto a Metal/Core Image chain; plugin manifests if we ever want third-party effects.

### TD-1 — Do not fork, embed, or link webcamoid. Build the video pillar natively.

Every factor points the same way: license (GPL), missing capability (no modern vcam, no segmentation), stack mismatch (Qt/QML/OpenGL vs Swift/SwiftUI/Metal), bundle weight (~150 MB of Qt/FFmpeg for zero needed capability). The webcamoid checkout stays in the repo as reference material only; **no code, no shaders, may be copied from it** (note for E8.1 license audit). The native Apple stack provides strictly more than webcamoid ever had on macOS.

## 3. Key technical decisions

### TD-2 — Transcription: embed WhisperKit; offer Apple SpeechAnalyzer as a second engine

- **Primary:** [WhisperKit](https://github.com/argmaxinc/WhisperKit) (MIT, now part of `argmaxinc/argmax-oss-swift` v1.0+, which also bundles **SpeakerKit** for on-device pyannote diarization — used in E7.1). CoreML/ANE-native, macOS 14+, pre-converted models on Hugging Face, in-process Swift API. Replaces `whisper-cli` + the JSON-file handoff.
- **Secondary engine:** Apple **SpeechAnalyzer/SpeechTranscriber** (macOS 26+): no model download, very fast, quality ≈ between whisper-small and large; ideal "instant start" default on new Macs, with WhisperKit as the accuracy option.
- Both sit behind a `TranscriptionEngine` protocol producing the existing `TranscribedSegment` schema. Language becomes a setting; auto-detect via engine capability.
- **Model manager** (E1.3): models stored in `Application Support/<App>/models/`, downloaded from Hugging Face with resume + checksum; default `large-v3-turbo` (quantized ~600 MB class); UI exposes size/accuracy tradeoff. The installer therefore stays small (~30 MB) and "downloads whisper" on first run, per the product requirement.

### TD-3 — Summarization: provider abstraction, no bundled cloud

`SummaryProvider` protocol with four implementations (PRD B1): Apple Foundation Models (on-device, macOS 26+, default when available), Anthropic BYOK, OpenAI BYOK, OpenAI-compatible local server (Ollama/LM Studio). Keys in Keychain. Chunk+reduce for long transcripts. The `claude`-CLI shell-out is deleted (it was a dev convenience that piggybacked on a Claude Code login; not shippable). We deliberately do **not** run our own inference backend at launch — BYOK + on-device keeps marginal cost at zero and the privacy story clean.

### TD-4 — Virtual camera: CMIO Camera Extension, embedded in the app

The modern, only-supported path (same as OBS 28+):

- A **system-extension target** (`CMIOExtensionProvider` / `CMIOExtensionDevice` / `CMIOExtensionStream`) embedded at `<App>.app/Contents/Library/SystemExtensions/`, activated via `OSSystemExtensionRequest` with a guided System Settings approval flow.
- **Frame transport:** the extension publishes the output stream *and* a **sink stream**; the main app connects to the sink via CoreMediaIO and pushes composited `CMSampleBuffer`s. When the app isn't streaming, the extension serves a branded placeholder ("Open <App> to go live") from within the extension process — this keeps the camera alive in pickers even when the app is closed.
- **Requirements** (drive other decisions): Developer ID signing + notarization, `com.apple.developer.system-extension.install` entitlement, shared App Group between app and extension, and the app **must run from /Applications** — hence the DMG's move-to-Applications nudge (E4.2) and the Xcode migration (TD-6).
- Works in Zoom, Chrome/Meet, Teams, Safari, FaceTime, OBS — anything using AVFoundation device discovery.

### TD-5 — Video effects pipeline: AVFoundation + Vision + Core Image/Metal

```
AVCaptureSession (real camera, incl. Continuity Camera)
  └─ CVPixelBuffer @ 1080p30 (IOSurface-backed)
      └─ VNGeneratePersonSegmentationRequest (Vision, ANE; quality tier by thermal/perf state)
          └─ Compositor (Core Image graph on Metal, one render pass where possible)
              ├─ background: passthrough | CIGaussianBlur via mask | image replace | color wash
              ├─ overlays: logo (CISourceOverCompositing), lower-third & text (pre-rendered CALayer→CIImage at stream resolution)
              └─ standby card path (bypasses camera entirely)
                  └─ tee → CMIO sink stream (virtual camera)
                       └─ tee → in-app preview (CAMetalLayer)
```

- Segmentation mask gets temporal smoothing (EMA over mask + confidence threshold) to kill edge flicker.
- Effects chain is structured as an ordered list of `VideoEffect` protocol nodes (the one good idea from webcamoid's `AkGLPipeline`, reimplemented natively) so presets are just serialized node configurations.
- Performance budget per PRD C8; degrade ladder: segmentation quality balanced→fast → 720p → passthrough with a UI hint.

### TD-6 — Project structure: migrate to an Xcode workspace with a core SwiftPM package

Required regardless (system-extension embedding, entitlements, asset catalogs, archiving/notarization are Xcode-project territory). Structure:

```
MeetingCompanion.xcworkspace
├─ App/                      # Xcode app target (SwiftUI shell, windows, menu bar)
├─ CameraExtension/          # CMIO system-extension target (minimal; links CompanionVideoCore)
├─ Packages/
│  ├─ CompanionCore/         # today's app logic: models, DB, capture, pipeline, calendar (unit-testable)
│  ├─ CompanionVideoCore/    # capture/segmentation/compositor (shared app↔extension where needed)
│  └─ CompanionProviders/    # TranscriptionEngine + SummaryProvider implementations
└─ Scripts/release.sh        # archive → notarize → staple → DMG → appcast
```

Bundle-ID scheme with App Group (`group.<team>.meetingcompanion`) shared across app + extension. One-time data migration from `Application Support/MeetingNotes/`.

### TD-7 — Distribution: Developer ID + notarized DMG + Sparkle 2

No Mac App Store at launch (sandbox friction with ScreenCaptureKit UX and update cadence; camera extensions are MAS-eligible so a MAS SKU stays possible later). Sparkle 2 with EdDSA-signed appcast for updates; updates deferred while recording. Licensing/paywall via Paddle or Lemon Squeezy (E8.2). Homebrew cask once the DMG is stable.

### TD-8 — Platform floor: macOS 14 (Sonoma), Apple Silicon only

- macOS 14 = WhisperKit floor and already the app's floor. Features gated by capability at runtime: SpeechAnalyzer + Foundation Models summarizer on 26+.
- Apple Silicon only: Vision segmentation + Whisper on Intel GPUs/CPU is a bad product experience, and it halves the QA matrix. (State it on the download page.)

## 4. Data model changes

Migrations on the existing GRDB store (`v2_product`):

- `segments`: + `speaker TEXT NULL` (diarization), + index.
- `summaries`: becomes multi-row per meeting — + `id PK`, + `provider TEXT`, + `template TEXT`, keep last N generations (E2.5); FTS indexes latest only.
- `meetings`: + `retention_pinned BOOL`, + `preset_used TEXT NULL` (video preset, analytics for auto-preset rules).
- New tables: `video_presets` (serialized effect-chain config JSON), `standby_cards`, `settings_kv` only if UserDefaults outgrows itself (prefer UserDefaults + Keychain).
- Transcript language + engine recorded per meeting for reproducibility.

## 5. Privacy & security posture

- Default data flow is 100% local: capture → mix → transcribe → store. The **only** possible egress points are (a) BYOK summarization, (b) model downloads (Hugging Face CDN), (c) Sparkle appcast checks, (d) opt-in crash reports. Each is user-visible and individually disable-able; the in-app privacy page (E8.1) diagrams exactly this.
- Keys in Keychain; no analytics SDKs; metrics per PRD §9 are computed locally and only leave the device if the user opts into aggregate telemetry.
- Recordings and DB under `Application Support`, protected by FileVault like everything else; no additional encryption at rest in v1 (document as such; revisit if enterprise demand appears).
- System-audio capture requires the Screen Recording permission — the most alarming prompt we trigger. Onboarding must explain *why* ("to hear the other side of your calls — we never capture your screen"; we configure the SCStream with a 2×2 px video config and discard video).

## 6. Risk register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | CMIO extension dev friction (entitlement provisioning, approval UX, debugging system extensions) drags M3 | High | High | Tracer-bullet prototype in week 1 of M2 (BACKLOG note); OBS's camera-extension PR (#7777) and Apple's WWDC22 sample as references; `systemextensionsctl developer on` for dev loop |
| R2 | An extension crash mid-meeting (worst failure mode) | Med | Very high | Extension kept minimal (render nothing, just serve frames from sink or placeholder); all effects run in the app process; watchdog + auto-passthrough on app crash |
| R3 | Whisper quality/latency complaints on 8 GB base machines | Med | Med | Default to quantized turbo model; SpeechAnalyzer engine as light option; model picker with honest guidance |
| R4 | Apple Intelligence unavailable (older OS, disabled, EU edge cases) breaks "zero-setup summaries" story | Med | Med | Provider ladder degrades to BYOK prompt with a friendly explainer; transcript-only is always a valid end state (E1.6) |
| R5 | ScreenCaptureKit permission scares users off | Med | High | Onboarding copy + animation (E3.3); "test recording" moment proves value immediately after the scary prompt |
| R6 | GPL contamination claim if any webcamoid code/shader is copied | Low | High | TD-1 hard rule; E8.1 audit step; webcamoid dir excluded from app build context |
| R7 | macOS updates change SCK/CMIO behavior (history: 12.3 broke all DAL vcams) | Low | High | Beta-OS smoke tests each June–Sept; Sparkle lets us ship fixes fast |
| R8 | Scope creep: two products in one app stall each other | Med | High | Milestone gates in BACKLOG: audio core must be shippable (M2) before video MVP starts (M3); video is additive, never blocking audio |

## 7. Suggested immediate next steps (for the implementing agent)

1. E1.1 + E1.2 (AVFoundation mixing, WhisperKit embed) — pure Swift, high certainty, kills two of three Homebrew deps.
2. E3.1 (Xcode migration) immediately after — it unblocks signing, extension work, and real UI.
3. R1 tracer bullet: minimal camera extension showing a test pattern in Zoom — before *any* effects work.
4. Delete `spike-audio/`, add `webcamoid/` to a "reference-only, do not import" note in the workspace README.
