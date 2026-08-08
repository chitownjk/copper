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

### First: check whether the camera extension got approved

The E5.1 tracer bullet is built, signed, provisioned, and **activated pending
the user's one click** (System Settings → General → Login Items & Extensions →
Camera Extensions). Check state:

    systemextensionsctl list

- `[activated waiting for user]` → still waiting; nag the user, work Track B.
- `[activated enabled]` → verify immediately: `swift Scripts/list-cameras.swift`
  should show "Meeting Companion Camera"; then check Photo Booth/Zoom show the
  test pattern (moving green block + frame counter — a frozen counter means
  the stream died). Update the log; that closes the tracer bullet.

Then the next E5.1 increment is the **sink stream** (app→extension frame
transport) — the extension gains a `.sink` direction stream, the app connects
via CoreMediaIO and pushes frames; the extension serves them instead of the
test card when the app is live. The dumb-extension rule (CLAUDE.md rule 2)
still holds. After that: E5.2 capture pipeline in `CompanionVideoCore`.

### Whenever blocked

- **E3.2 unified main window** (sidebar; folds in the recovery prompt + a
  retention-pin UI, both currently homeless).
- **E3.3 onboarding rewrite.**
- **Live BYOK test** the moment an Anthropic/OpenAI key exists in Settings —
  no provider has ever hit a live endpoint.

## User actions outstanding (nobody else can do these)

1. Approve the camera extension (one click, see above).
2. E4.1: create a **Developer ID Application** cert (Account Holder at
   developer.apple.com) + notarytool credentials. Dev-signing needed no
   Apple approval — the System Extension capability is self-service.
3. Optional: reboot to flush the dead SplitmediaLabs virtcam uninstall.

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
