# Fresh-session prompt

Paste this into a new session (Fable or otherwise). It is written to be
self-contained: it says what exists, what to distrust, and what to do.

---

You are picking up **Meeting Companion**, a macOS app at
`/Users/jayklauminzer/Development/meeting-notes` (private repo
`github.com/chitownjk/meeting-companion`, branch `main`).

**Read first, in this order:**
1. `docs/IMPLEMENTATION_LOG.md` — what exists, how it was verified, open concerns
2. `CLAUDE.md` — hard rules (especially: never copy from `webcamoid/`, it is GPL-3.0)
3. `docs/E5.1_TRACER.md` — the camera-extension breakdown and its failure modes
4. `docs/TECH_PLAN.md` — TD-1…TD-8, the risk register
5. `docs/BACKLOG.md` — story IDs and acceptance criteria

**Where things stand (August 2026).** M1 complete and verified. E3.1 (Xcode
workspace), E1.4 (SpeechAnalyzer engine), E2.6 (quick actions), E3.4
(Settings), the custom template editor, and the Database recovery prompt are
all done and verified on this Mac. 67 tests pass from `Packages/MeetingKit`.
The bundle ID is `com.strongrise.meetingcompanion` (the old one was squatted;
see the log).

Build: `xcodebuild -project MeetingCompanion.xcodeproj -scheme MeetingNotes
-configuration Release -derivedDataPath .dd -allowProvisioningUpdates build`.
Test: `cd Packages/MeetingKit && swift test`.
This Mac is macOS 26.5.2 with Apple Intelligence — the on-device summarizer
and SpeechAnalyzer run for real; don't stub them.

---

## Your job

### First: check whether the sink relay got its eyeball check

The E5.1 **sink stream is built and transport-proven** (300/300 frames across
the process boundary, extension log accounting exact — see the log). What no
headless check can prove is the rendered relay: camera TCC is auto-denied for
CLI processes. If the user is around, ask them to run

    /Applications/MeetingNotes.app/Contents/MacOS/MeetingNotes --push-camera-frames=30

and watch "Meeting Companion Camera" in Photo Booth: indigo "LIVE FROM
MEETING COMPANION APP" pattern while pushing, SMPTE test card returning ~1 s
after it stops. Extension logs the "relaying app frames" / "serving test
card" transitions. That closes E5.1's transport step.

**Before any extension replace:** read the launchd-race note in the log
(hard-won fact #1 under the sink-stream section). If the camera vanishes
after a replace, `launchctl print system | grep CMIOExtension` is the tell;
bump `CFBundleVersion` and replace again.

The **E5.2 first slice is also built**: `CompanionVideoCore` (new MeetingKit
product) with `CameraCaptureService`, and `--camera-passthrough[=seconds]`
chaining real camera → sink → virtual camera. Unverified for the same TCC
reason; the log has the exact verification run. Next E5.2 work after the
eyeball checks pass: in-app live preview panel, device picker (incl.
Continuity Camera), latency measurement (PRD wants ≤5 ms added), then
segmentation (E5.3). The dumb-extension rule (CLAUDE.md rule 2) still holds.

### Whenever blocked

- **E3.2 unified main window** (sidebar; folds in the recovery prompt + a
  retention-pin UI, both currently homeless).
- **E3.3 onboarding rewrite.**
- **Live BYOK test** the moment an Anthropic/OpenAI key exists in Settings —
  no provider has ever hit a live endpoint.

## User actions outstanding (nobody else can do these)

1. Eyeball the sink relay in Photo Booth (see above — 60 seconds).
2. E4.1: create a **Developer ID Application** cert (Account Holder at
   developer.apple.com) + notarytool credentials. Dev-signing needed no
   Apple approval — the System Extension capability is self-service.
3. Optional: reboot to flush the dead SplitmediaLabs virtcam uninstall and
   the stack of superseded Meeting Companion extension versions (v1–v7 sit
   in "waiting to uninstall on reboot" / stale staging dirs).

---

## Things to distrust

1. **No BYOK provider has ever talked to a live endpoint.** Parsing/error
   mapping unit-tested only; no key exists in the Keychain to test with.
2. **Model IDs are hardcoded and will age.** Verified August 2026.
3. **Long-meeting chunking on cloud providers is synthetic-tested only.** The
   on-device path had exactly the predicted bug (found + fixed live: budget
   assumed 4 chars/token; timestamped transcripts run ~2.6). The Anthropic/
   OpenAI budgets rest on the same heuristic — re-derive them when a key is
   available.
4. **The retention sweep deletes audio.** Gated and tested, but re-read it
   before changing anything near it.
5. **The pbxproj is hand-authored.** Xcode will rewrite it on the first GUI
   edit (fine), but check the diff before committing one.

---

## How to work

- Commit at checkpoints with real messages; the history explains *why*.
  Push to `main`.
- Verify with measurements, not assertions of correctness. The bar so far:
  exact frame counts, measured SNR, real transcripts, sysextd log excerpts.
- Update `docs/IMPLEMENTATION_LOG.md` as you go — it is the handover.
- Flag anything structurally blocked instead of routing around it.
