# Meeting Companion — Product Requirements Document

**Status:** Draft v1 · August 2026
**Working name:** Meeting Companion (see [Naming](#naming))
**Companion docs:** [TECH_PLAN.md](TECH_PLAN.md) · [BACKLOG.md](BACKLOG.md)

---

## 1. Vision

One native Mac app that makes you better in every meeting — before, during, and after.

- **Before:** it knows your calendar, arms itself for the next call, and puts your best face forward (framing, background, branding) the moment your camera goes live.
- **During:** it records both sides of the conversation locally, lets you jot timestamped notes in a floating panel, and gives you a polished on-camera presence (blur, custom backgrounds, logo/title overlays, a branded "stepped away" card instead of a dead black tile).
- **After:** it transcribes on-device, produces a structured summary with decisions and action items, and makes every meeting searchable forever.

The unifying promise: **everything runs on your Mac.** No meeting bot joins your calls, no audio leaves your machine unless you explicitly choose a cloud summarizer. This is the wedge against Otter/Fireflies/Fathom (cloud bots, consent problems, IT bans) and the reason a single app can credibly own both audio and video: it sits at the capture layer of the OS, not in the meeting.

### Why one app instead of two?

- The audio product and the video product share the same trigger (a meeting starting), the same surface (menu bar + one window), the same calendar intelligence, and the same buyer.
- Nobody wants to run Granola *and* mmhmm *and* Krisp. One well-behaved menu bar app that handles "meeting stuff" is a real position.
- The video companion is the visible, demoable feature that markets the invisible one. "The app that makes you look good on camera" gets installed; "it also takes perfect notes" gets retained.

## 2. Current state (what exists today)

The [app/](../app) codebase is a working v0 of the audio pillar (~2,900 lines of Swift, macOS 14+):

**Working:** menu-bar app; dual-stream recording (mic via AVAudioEngine with echo cancellation, system audio via ScreenCaptureKit); calendar integration with meeting-link detection (Zoom/Meet/Teams/Webex) and auto-record with arm/grace windows; floating timestamped notes panel; post-meeting pipeline (mix → whisper transcribe → Claude summarize); SQLite/GRDB store with FTS5 full-text search; library window with summary/notes/transcript tabs, rename, markdown export; onboarding checklist; toasts.

**Developer-tool scaffolding that must be replaced for a real product:**
- Transcription shells out to Homebrew `whisper-cli`; mixing shells out to `ffmpeg`; summarization shells out to the `claude` CLI. All three are resolved from `/opt/homebrew/bin` — a consumer can't install this.
- The whisper model is a manual 1.5 GB `curl` the user runs in Terminal.
- Built as a bare SwiftPM executable — no app bundle, no signing, no icon, no installer, no updates.
- No audio playback, no speaker labels, no settings UI, no error recovery if the app dies mid-recording.

[webcamoid/](../webcamoid) is a checkout of the GPL-licensed Qt webcam app, present as a **reference** for the video pillar. Per the technical review (see TECH_PLAN §3), we will **not** fork or link it: its license is incompatible with a proprietary product, its macOS virtual-camera approach predates Apple's current API, and its Qt/C++ stack would fight our native Swift app. We build the video pillar natively and use webcamoid only as a feature checklist and algorithm reference.

## 3. Users & personas

**P1 — The back-to-back operator (primary).** Manager, founder, consultant, salesperson: 15–30 meetings/week on Zoom/Meet/Teams. Wants meeting notes to write themselves; is embarrassed sending a bot into client calls; may be under IT rules that ban cloud recorders. Buys the audio pillar; the video pillar is a delightful bonus. *Success = never takes manual notes again, finds any past decision in seconds.*

**P2 — The client-facing professional.** Sales, agency, recruiting, fractional exec. Their face *is* the brand. Wants: consistent branded look (logo, name/title lower-third), clean blurred or branded background from any location, and a professional "be right back" card instead of a black rectangle. *Success = looks like they have a production team.*

**P3 — The content-creator-adjacent.** Coaches, course creators, podcasters, streamers doing interviews from meeting apps. Wants scene-like presets (intro card, brand background, guest mode), and recordings + transcripts of everything for repurposing into content. *Success = every call is potential content, pre-transcribed.*

**P4 — The privacy-mandated user.** Legal, healthcare, finance, government-adjacent. Cloud transcription is a compliance non-starter. Local-only mode is not a preference, it's the requirement. *Success = a data-flow story they can show their compliance team: audio and transcripts never leave the device.*

Anti-persona (v1): teams wanting shared workspaces, admin consoles, CRM sync. That's a later B2B chapter; v1 is single-player.

## 4. Competitive frame

| Product | What they do | Our angle |
|---|---|---|
| Otter, Fireflies, Fathom, Read | Cloud bots that join meetings | No bot, no cloud, no consent banner with our name on it. Works for in-person meetings too. |
| Granola | Local capture + cloud AI notes | Closest audio comp. We differentiate on *fully* local option (they require cloud LLM) + the video pillar. |
| superwhisper / MacWhisper | Local transcription utilities | We're a meeting system (calendar, auto-record, notes, summaries, library), not a transcription tool. |
| mmhmm, Camo Studio | Virtual camera / look-better tools | They stop at video. We tie camera polish to the meeting workflow and notes. |
| Krisp | Audio enhancement + notes | Validates the "companion at OS capture layer" model; weak on video, notes are cloud. |
| Zoom/Teams built-ins | Per-platform blur/AI notes | We're platform-agnostic: one identity, one library, across every meeting app, including ones with weak effects (Meet in browser, Webex, FaceTime, in-person). |

**Positioning statement:** *The private meeting companion for your Mac. Look sharp on camera, get perfect notes, keep everything on your machine.*

## 5. Product pillars & requirements

### Pillar A — Record & Notes (harden what exists)

- **A1. Zero-dependency capture.** Recording, mixing, transcription fully embedded — no Homebrew, no Terminal, ever. Transcription via embedded WhisperKit (Apple-Silicon-native Whisper); audio mixing via AVFoundation (drop ffmpeg).
- **A2. Model management.** First-run flow downloads the chosen Whisper model in-app with progress, resume, and checksum; sensible default (~600 MB class) with an "accuracy vs. size" picker; per-language guidance. Apple SpeechAnalyzer (macOS 26+) offered as a zero-download engine option.
- **A3. Speaker attribution.** Diarized transcripts ("Speaker 1 / Speaker 2", renameable, learnable per calendar attendees) via SpeakerKit or equivalent on-device diarization. This is the single biggest transcript-quality differentiator.
- **A4. Live transcript (stretch, post-v1).** Streaming transcription during the meeting feeding a live sidebar.
- **A5. Crash-safe recording.** Audio written incrementally (already true); on relaunch after crash, offer to recover and process the partial recording. Disk-space preflight, low-disk warning mid-recording.
- **A6. Meeting playback.** Audio player in the library synced to transcript segments — click a segment to hear that moment. Table stakes for trust in the transcript.
- **A7. Retention controls.** Per-meeting and global: keep audio forever / N days / delete after transcription. Storage dashboard in settings.

### Pillar B — Summaries & Intelligence

- **B1. Summarizer provider abstraction** with four backends, user-selectable per default and overridable per meeting:
  1. **On-device Apple Intelligence** (Foundation Models, macOS 26+ Apple Silicon): default when available — zero setup, zero cost, fully private.
  2. **BYOK cloud:** Anthropic and OpenAI keys pasted in settings, stored in Keychain. Clear "this meeting's transcript will be sent to X" labeling.
  3. **Local server:** Ollama/LM Studio endpoint (OpenAI-compatible URL) for power users with bigger local models.
  4. **None:** transcript + notes only. Always works.
- **B2. Structured output:** TL;DR, decisions, action items (owner + due if mentioned), open questions, notable quotes — the existing prompt, productized with templates per meeting type (1:1, standup, sales call, interview) and a custom template editor.
- **B3. Regenerate & refine:** re-run summary with a different template/provider; "make it shorter/for email" quick actions.
- **B4. Ask-your-meetings (post-v1):** chat over one meeting or the whole library (local RAG over FTS + embeddings).
- **B5. Follow-through:** one-click export of action items to Reminders/Calendar; "draft follow-up email" action producing a ready-to-paste email.

### Pillar C — Video Companion (new)

- **C1. Virtual camera** ("Companion Camera") available in every meeting app (Zoom, Meet/Chrome, Teams, Safari/FaceTime, OBS), implemented as a modern CoreMediaIO Camera Extension bundled in the app; one-click enable in onboarding, clean uninstall.
- **C2. Live pipeline** at 1080p/30 with <80 ms added latency: real camera → person segmentation (Apple Vision, Neural Engine) → background treatment → overlays → virtual camera + in-app preview.
- **C3. Background treatments:** none / blur (adjustable) / custom image / subtle branded color wash. Ships with a small tasteful gallery; user can add images.
- **C4. Overlays:** logo (corner, opacity/size), lower-third (name, title, pronouns — auto-fillable), custom text. Pixel-precision drag placement in preview; safe-area guides.
- **C5. Standby card ("camera off screen").** One keystroke swaps your feed to a designed card — "Be right back," logo, name — instead of going black. Variants: BRB, muted/listening, intro/outro card. This is the demo moment of the product.
- **C6. Presets/scenes.** Named bundles of background+overlays+card (e.g., "Client calls," "Internal," "Podcast"). Switchable from the menu bar and by hotkey; optional auto-select by calendar (e.g., external meetings → "Client calls").
- **C7. Enhance (fast follow):** auto-framing/center-stage-style crop, color/exposure touch-up, mirror toggle, test pattern.
- **C8. Performance budget:** ≤ 25% of one performance core + ANE at 1080p30 on M1; graceful degradation (720p, lower segmentation quality) on constrained machines; zero dropped frames when no effects are active (passthrough).

### Pillar D — A real product (packaging, identity, distribution)

- **D1. Real app:** Xcode-built bundle, icon, brand, Dock-optional (menu bar first, main window on demand).
- **D2. Installer & updates:** signed + notarized DMG (drag-to-Applications with the standard arrow layout); Sparkle 2 auto-updates with release notes. `brew install --cask` as a channel later.
- **D3. Onboarding as a flow, not a checklist:** welcome → permissions (mic, screen recording, calendar — each with a why and a live status) → model download with progress → camera extension approval walkthrough (with a screenshot of the System Settings prompt) → "record a 10-second test meeting" moment that shows a real transcript+summary within the first 3 minutes.
- **D4. Settings window** (real one): General, Recording, Transcription (engine/model/language), Summarization (provider/keys/templates), Video (camera, quality), Storage & Privacy, Updates.
- **D5. Privacy page & data-flow diagram** in-app and on the website; every cloud egress point requires explicit opt-in and is visibly labeled.
- **D6. Website + docs** with the 90-second demo video (standby card + summary reveal is the hero shot).

## 6. Look & feel

- **Design language:** native macOS through and through — SwiftUI, vibrancy materials, SF Symbols, system accent colors, full light/dark support. It should feel like Apple could have shipped it; that *is* the brand ("the native, private one").
- **Surfaces:**
  1. **Menu bar** (primary, always available): record state at a glance, next meeting, camera quick-toggles (preset switcher, standby card, blur), recent meetings.
  2. **Main window** (one, not three): sidebar (Meetings, with search) → meeting detail (summary/notes/transcript + player). Video tab or a second sidebar section (Camera: preview + presets). Replaces today's separate Library/Onboarding windows.
  3. **Floating notes panel** during recording (keep — it's a strength) with added quick actions: flag moment ⌘⇧F, standby card toggle.
  4. **Camera preview panel:** compact always-on-top preview with preset switcher, openable from the menu bar before you join a call ("mirror check").
- **Tone:** calm, quiet, competent. No confetti. The moments of delight are: the summary appearing, and the standby card saving you when the doorbell rings.
- Full keyboard-shortcut coverage and menu-bar-only operation for power users.

## 7. Monetization & tiers (proposal — decide before public launch)

| | Free | Pro (one-time or annual) |
|---|---|---|
| Recording, notes, library, search | ✓ | ✓ |
| Transcription (on-device) | ✓ | ✓ |
| Summaries | Apple-Intelligence or BYOK | + templates, regenerate, follow-up drafts |
| Diarization | — | ✓ |
| Virtual camera | Blur + 1 preset, small watermark on overlays | Everything, no watermark, unlimited presets |
| Support/updates | ✓ | ✓ |

Rationale: capture/transcribe free builds trust and word-of-mouth (and costs us nothing per user — it's their silicon); the money features are polish (video identity, diarization, templates). BYOK means we never carry inference costs. Direct sales (Paddle/Lemon Squeezy) rather than Mac App Store initially — MAS sandboxing complicates ScreenCaptureKit + system-extension UX (revisit later; camera extensions are MAS-compatible if we ever want a MAS SKU).

## 8. Naming

"Meeting Companion" works as the category descriptor; for a brand, candidates worth checking for conflicts: **Sidebar**, **Greenroom**, **Copresence**, **Standby**, **Chamber**, **Fieldnotes**. Recommendation: pick a real name before the website; use "<Name> — meeting companion for Mac" as the tagline structure. (Trademark/domain check is an explicit backlog story.)

## 9. Success metrics

- **Activation:** ≥70% of installs reach a completed first recording with visible summary within day 1; ≥50% enable the virtual camera in week 1.
- **Retention:** ≥40% of activated users record 3+ meetings in week 2; camera used in ≥30% of recorded meetings.
- **Quality:** transcription WER spot-checks; summary thumbs-up rate ≥80%; virtual-camera crash rate ~0 (an extension crash mid-meeting is the worst possible failure — it gets its own SLO).
- **Performance:** pipeline (1-hr meeting) completes < 4 min on M1; camera pipeline within budget C8.

## 10. Non-goals (v1)

- No meeting bot, no cloud recording, no mobile app, no Windows (until product-market fit on macOS).
- No team features (sharing, workspaces, admin).
- No live translation or captions overlay.
- No audio effects (noise removal beyond Apple voice processing) — Krisp's turf, revisit later.
- No streaming-studio ambitions (multi-source scenes, RTMP) — we are not OBS.

## 11. Open questions

1. Brand name + domain (blocks website, not development).
2. Pricing model: one-time vs. subscription vs. hybrid (major; affects Sparkle/licensing infra).
3. Minimum macOS: 14 (Sonoma) proposed — WhisperKit floor; Apple-Intelligence summarizer gated to 26+ with BYOK fallback below.
4. Intel support: proposed **Apple Silicon only** (segmentation + Whisper on Intel is a poor experience; Intel Macs are 6+ years old).
5. Do we gate diarization to Pro from day one, or use it as a launch splash feature for everyone?
