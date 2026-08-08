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
3. `docs/TECH_PLAN.md` — TD-1…TD-8, the risk register
4. `docs/BACKLOG.md` — story IDs and acceptance criteria

**Where things stand.** M1 (zero-dependency audio core) is complete and verified
end-to-end in the release binary: record → mix → transcribe on the ANE →
summarize on-device → searchable. 62 tests pass. E3.4 (Settings) is done. The
video pillar has not been started at all.

Build: `cd app && swift build`. Test: `cd app && swift test`.
This Mac is macOS 26.5.2 with Apple Intelligence, so the on-device summarizer
and SpeechAnalyzer can both be exercised for real — don't assume you have to
stub them.

---

## Your job

Two tracks. **Track A is the higher risk and should start first**, because
everything in the video pillar depends on it and it is the one place the plan
could turn out to be wrong.

### Track A — unblock the video pillar (E3.1 → E4.1 → E5.1)

Nothing in this chain has been attempted, and it is the critical path.

1. **E3.1 — migrate SwiftPM → Xcode workspace.** App target + local packages
   (`MeetingCore`, `MeetingProviders` already exist as separate targets and
   should become local packages). This is a prerequisite for embedding a system
   extension and for signing. Keep `swift test` working if you can; if the
   packages have to move, say so.
2. **E4.1 — Developer ID signing + notarization.** Needs a paid Apple Developer
   account and the `com.apple.developer.system-extension.install` entitlement.
   **Entitlement approval has latency — request it on day one**, before you need it.
3. **E5.1 — the CMIO camera extension tracer bullet.** A minimal extension that
   shows a test pattern and is selectable in Photo Booth and Zoom. Nothing else.
   No effects, no compositor, no UI.

   This story is marked XL and the difficulty is *structural*, not effort:
   silent failures where the extension installs but never appears in a picker,
   entitlement/provisioning coupling, sink-stream handshake quirks. Break it
   down before starting. Keep the dumb-extension / smart-app boundary from TD-4
   and hard rule 2 — no effects in the extension process.

   **If it stalls, say so rather than restructuring the product around the
   blocker.** That is an explicit instruction from the project owner.

### Track B — things that are cheap and this Mac can verify

Do these when Track A is blocked on an approval or a decision:

- **E1.4 SpeechAnalyzer engine.** Add `SpeechAnalyzerEngine` behind the existing
  `TranscriptionEngine` protocol, offer it as "Apple (no download)". Compare its
  output against WhisperKit on the bundled fixture — same schema, timestamps in
  the same ballpark. Runnable for real here.
- **E2.6 quick actions.** UI over `Pipeline.regenerateSummary(meetingId:template:)`.
- **Custom template editor.** `SummaryTemplateStore.custom` exists and Settings
  already reads it; only the editor is missing.

---

## Things to distrust

These are honest gaps, not busywork. Check them rather than assuming.

1. **No BYOK provider has ever talked to a live endpoint.** Anthropic, OpenAI,
   and local-server code paths are unit-tested at parsing and error mapping
   only. The request shapes follow current docs but have never round-tripped.
   If a key is available, that is a cheap, high-value first test.
2. **Model IDs are hardcoded and will age.** Verified August 2026. Re-check
   before trusting them.
3. **`Database.swift` `fatalError`s on init.** Decide what the app should do
   with an unreadable database, then fix it.
4. **Long-meeting chunking is only tested with synthetic text.** The real
   two-hour map-reduce path is unproven.
5. **The retention sweep deletes audio.** It is gated on policy, pin, and
   `status == ready`, and covered by tests — but it is the one piece of code
   here that destroys user data. Re-read it before changing it.

---

## How to work

- Commit at checkpoints with real messages; the history so far explains *why*,
  not just what. Push to `main`.
- Verify with measurements, not assertions of correctness. The existing tests
  set the bar: exact frame counts, measured SNR, real transcripts.
- Update `docs/IMPLEMENTATION_LOG.md` as you go — it is the handover.
- Flag anything structurally blocked instead of routing around it.
