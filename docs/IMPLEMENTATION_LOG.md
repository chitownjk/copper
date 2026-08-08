# Implementation log

What has been built, how it was verified, and what is still open.
Companion to [BACKLOG.md](BACKLOG.md) (story IDs) and [TECH_PLAN.md](TECH_PLAN.md) (TD-1…TD-8).

**Repo:** `github.com/chitownjk/meeting-companion` (private). Working name is
"Meeting Companion"; the real name is still an open product decision (PRD §8),
and only the repo name and window titles would need to change.

**Status: M1 complete and verified in the shipping binary. M2 well underway —
E3.1 (Xcode workspace) and E1.4 (SpeechAnalyzer) are done; the E5.1 tracer
bullet is one System Settings approval click away from proven.**
The app has no external-binary dependencies — `grep -rn "Process()\|/opt/homebrew"
App/Sources Packages/` matches nothing but comments. On a machine with Apple
Intelligence it records → mixes → transcribes → summarizes with zero configuration.

**The bundle identifier changed** (August 2026): `com.meetingnotes.app` turned
out to be registered to a different team on Apple's developer portal and could
never be provisioned. The app is now `com.strongrise.meetingcompanion` under
team GJPMXXQTWN. `LegacyDefaultsMigration` copies the old UserDefaults domain
once; the database/recordings (name-based path) and Keychain (literal service
string) were never keyed by bundle ID.

---

## Project layout (E3.1, per TD-6)

`MeetingCompanion.xcworkspace` wraps a hand-authored `MeetingCompanion.xcodeproj`
(objectVersion 77, file-system-synchronized groups — no per-file bookkeeping)
plus the local package. **`swift test` now runs from `Packages/MeetingKit`.**

| Where | Contents |
|---|---|
| `App/` | Xcode app target: SwiftUI shell, DB + migrations, pipeline, calendar, windows, Info.plist, entitlements |
| `CameraExtension/` | CMIO system-extension target (E5.1): provider/device/stream + test card, deliberately dumb |
| `Packages/MeetingKit` | Local SwiftPM package, products `MeetingCore` + `MeetingProviders`, all tests + fixtures |

The app target is signed automatically (team GJPMXXQTWN, Apple Development)
with hardened runtime; the app is deliberately NOT sandboxed (sandboxing would
relocate Application Support away from existing data — that move is E3.5's).
GRDB is a project-level package dependency now; the package only depends on
argmax-oss-swift. `CompanionVideoCore` still doesn't exist — it arrives with E5.2+.

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
| **E3.1** Xcode workspace | Hand-authored project, synchronized groups; app + extension targets; `swift test` green after the move; `--recover-orphans` / `--settings` verified from the .app bundle. |
| **E1.4** SpeechAnalyzer engine | `SpeechAnalyzerEngine` behind `TranscriptionEngine`; Settings picker "Apple (no download)"; engine resolved per pipeline run, stale prefs fall back to Whisper. |
| **E2.6** Quick actions | Regenerate (any template) / Shorter / As-follow-up-email on the summary tab. Email drafts are one-off (`Pipeline.generateOneOff`) so they never displace a summary in the 3-generation history. Live on-device email draft in 2.2 s with a `Subject:` line. Button wiring built and compiling; clicked-through UI verification still pending (menu-bar UI automation needs a permission this session doesn't have). |

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

**67 tests, 0 failures** (`cd Packages/MeetingKit && swift test`). Golden audio
fixtures are bundled, so nothing needs an environment variable. One test is
gated (the model is already installed on this Mac, so it runs in ~3 s here):

```bash
cd Packages/MeetingKit && MEETING_NOTES_RUN_TRANSCRIPTION=1 swift test --filter WhisperKitEngineIntegrationTests
```

Measured, not asserted-from-theory:

| What | Result |
|---|---|
| Mixer output length vs ffmpeg | **Exact** (130,560 frames on the bundled fixture; 491,200 on the full 30.7 s recording) |
| Mixer fidelity vs ffmpeg | 38.0 dB wideband, 61.8 dB below 4 kHz — residual is 6–8 kHz transition-band rolloff only |
| Transcription throughput | 30.7 s of audio in 3.3 s warm (~9× realtime) |
| SpeechAnalyzer vs WhisperKit on the bundled fixture | Same 3-segment structure; boundaries agree within 0–580 ms (Whisper pads to round times, SA hugs speech onsets); SA 0.3 s vs Whisper 2.9 s warm; SA misheard the boundary-clipped last word ("audience" for "audio") — TD-2's quality ranking is real |
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

## E5.1 tracer bullet — where it stands (August 2026)

Everything up to the human approval step is **proven on this Mac**:
`systemextensionsctl list` shows `com.strongrise.meetingcompanion.cameraextension
(0.1.0/1) [activated waiting for user]`. Breakdown and failure-mode notes in
[E5.1_TRACER.md](E5.1_TRACER.md). Dev loop: build → `cp -R` the app to
`/Applications` → `--install-camera-extension`.

Hard-won, log-verified facts:

1. **The CMIO category validator on macOS 26 rejects a team-ID-prefixed
   `CMIOExtensionMachServiceName`** (paramErr -50, "must be prefixed with one
   of the App Groups in the entitlement") — contrary to WWDC22-era docs. The
   extension carries app group `GJPMXXQTWN.com.strongrise.meetingcompanion`
   and the mach service name is prefixed by it. The app will adopt the same
   group for the sink stream.
2. The System Extension entitlement is **self-service** for this team —
   `-allowProvisioningUpdates` registered the App ID, this Mac, and minted the
   development profile non-interactively. No Apple approval request, no latency.
3. A failed activation leaves a half-uninstalled registration; an immediately
   repeated request can race it ("Category delegate returned error"). Retry
   once the state settles.
4. The extension's Info.plist needs `NSSystemExtensionUsageDescription` (error
   is explicit about it).

**Approved and running** (later the same evening): `systemextensionsctl list`
shows `[activated enabled]`; `Scripts/list-cameras.swift` finds "Meeting
Companion Camera" as an `.external` AVFoundation device with the fixed device
UUID; and the extension's own os_log shows two full
`client connected → started streaming → stopped streaming` cycles matching
the capture probe's two 1.5 s runs exactly — discovery, connect, startStream,
frame timer, and teardown all work. What no headless check can prove: the
rendered pixels in a real app. `Scripts/probe-companion-camera.swift` would
prove it but camera TCC is auto-denied for CLI processes in the agent session
("granted: false", no prompt). **A human opening Photo Booth and picking
"Meeting Companion Camera" — expect color bars, a sweeping green block, and a
counting frame number — is the last inch of E5.1 acceptance**, plus the
uninstall path (`--uninstall-camera-extension`). Then the sink stream as its
own step.

## Open work

### Not started

- **E3.2 unified main window**, **E3.3 onboarding rewrite**, **E3.5 brand pass**
  (bundle ID already moved to `com.strongrise.meetingcompanion`; visible name
  still "MeetingNotes"), **E4 signing/DMG/Sparkle** (see "User actions" below).
- **E5.2+**: capture/render pipeline, segmentation, overlays — gated on the
  E5.1 approval verification.

### User actions required (nobody else can do these)

- **Approve the camera extension**: System Settings → General → Login Items &
  Extensions → Camera Extensions → allow "Meeting Companion Camera".
- **E4.1 Developer ID**: the keychain has only an Apple Development cert.
  Creating a **Developer ID Application** certificate must be done by the
  team's Account Holder at developer.apple.com. Notarization also needs an
  App Store Connect API key or app-specific password for `notarytool`.
- Optional hygiene: a leftover `com.splitmedialabs.virtcam.extension` sits in
  "terminated waiting to uninstall on reboot"; a reboot flushes it.

### Partial

- ~~Custom summary templates editor~~ **Done** — Settings > Summaries has
  add/edit/delete with a name + instructions sheet; deleting the current
  default falls back to General visibly.
- **Per-meeting retention pinning**: the column, the sweep logic, and the
  "Apply Retention Now" button all exist. There is no UI to *set* the pin — that
  belongs in the meeting detail view, which E3.2 rewrites anyway.
- **Onboarding** still uses the old checklist window. It now checks the right
  things (speech model, summarizer) but E3.3 replaces the whole flow.

---

## Concerns

1. ~~`Database.swift` `fatalError`s on init~~ **Fixed.** An unreadable store
   now raises a modal: Quit, or set the bad file aside (kept as
   `meetings.sqlite.unreadable-<timestamp>` with its -wal/-shm) and start with
   an empty library; recordings are never touched. A fresh file failing too
   (full disk, unwritable dir) gets an explanatory alert, then exit. Verified
   with a real garbage file: app survives and prompts where it used to crash;
   restore + relaunch behaves normally. The "start fresh" *button click*
   itself isn't automated-tested (needs assistive access) — logic is three
   file moves + reopen.

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
   has only been tested with synthetic text. This concern already paid out
   once: the on-device budget assumed ~4 chars/token, real timestamped
   transcripts run ~2.6, and the 4,096-token window (which includes the
   *output*) blew mid-generation. Fixed for Apple FM (6,000-char budget +
   1,024-token response cap, 3/3 live passes); the cloud providers' budgets
   rest on the same heuristic and deserve the same scrutiny on first live use.

6. **Nothing is signed or notarized**, so the camera extension (which requires
   Developer ID + notarization + `/Applications`) remains entirely unproven.
   That dependency chain — E3.1 → E4.1 → E5.1 — is the critical path to the
   video pillar and none of it has started.

7. **No BYOK provider has been exercised against a live endpoint.** Anthropic,
   OpenAI, and the local-server paths are unit-tested at the parsing and
   error-mapping layer only; no real API key was used. The wire format follows
   current documentation, but first real use may surface something.
