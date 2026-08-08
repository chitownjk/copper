# Meeting Companion (working name)

One macOS app, two pillars: local meeting recording/transcription/notes plus a new native video companion (virtual camera with blur, backgrounds, overlays, standby card).

**Read before doing anything:**
- [docs/IMPLEMENTATION_LOG.md](docs/IMPLEMENTATION_LOG.md) — what has actually been built so far, what's partial, open concerns
- [docs/NEXT_SESSION_PROMPT.md](docs/NEXT_SESSION_PROMPT.md) — a paste-able brief for a fresh session
- [docs/HANDOVER.md](docs/HANDOVER.md) — condensed context from the strategy/audit session
- [docs/PRD.md](docs/PRD.md) — product requirements (requirement IDs A1–D6)
- [docs/TECH_PLAN.md](docs/TECH_PLAN.md) — architecture decisions TD-1…TD-8, risk register
- [docs/BACKLOG.md](docs/BACKLOG.md) — epics/stories with acceptance criteria, milestones M1–M5

## Hard rules (do not violate)

1. **Never copy code, shaders, or assets from `webcamoid/`.** It is GPL-3.0 and reference-only; any copied line contaminates the proprietary app. It is not part of the build. Reading it for ideas is fine.
2. **No effects or heavy logic in the camera-extension process.** The CMIO extension stays minimal (serve frames from the sink stream, or a placeholder). All capture/segmentation/compositing runs in the main app. An extension crash mid-meeting is the worst possible failure (TECH_PLAN R2).
3. **No new external-binary dependencies.** The product ships self-contained: no Homebrew tools, no CLI shell-outs. The existing ffmpeg / whisper-cli / claude subprocess calls are scheduled for deletion (E1.1, E1.2, E1.6/E2).
4. **Default data flow stays 100% local.** Any new network egress (beyond model downloads, Sparkle, BYOK summarization) needs explicit sign-off.

## Repo layout

- `MeetingCompanion.xcworkspace` / `MeetingCompanion.xcodeproj` — the Xcode workspace (E3.1, TD-6)
- `App/` — the app target's sources, Info.plist, entitlements (SwiftUI shell, windows, menu bar, DB, pipeline)
- `Packages/MeetingKit/` — local SwiftPM package: `MeetingCore` (audio + transcription) and
  `MeetingProviders` (summarization backends) products, plus all tests
- `webcamoid/` — GPL reference checkout, reference-only (see rule 1)
- `docs/` — PRD, tech plan, backlog, handover

## Working notes

- Build: `xcodebuild -project MeetingCompanion.xcodeproj -scheme MeetingNotes -configuration Release build`
  (or open the workspace in Xcode)
- Test: `cd Packages/MeetingKit && swift test`. Golden fixtures are bundled; the end-to-end transcription
  test is gated behind `MEETING_NOTES_RUN_TRANSCRIPTION=1` (it downloads a 632 MB model)
- Data lives in `~/Library/Application Support/MeetingNotes/` (rename/migration is story E3.5)
- Platform floor: macOS 14, Apple Silicon only (TD-8)
