# Feature audit — Meeting Companion

**Date:** 14 August 2026 (ET)
**Checkout:** `65361e4` — *Fix Jay-test bugs: Drive is not a meeting link, honest dictation insert, delete-after-transcribe, Whisper junk.*
**Goal:** the one Mac app for meetings, plus free local Wispr-like dictation. Product Hunt when the first gesture is tested.
**Method:** PRD, BACKLOG, UX_REVIEW, BRAND, PIVOT_DICTATION, IMPLEMENTATION_LOG, and the shipping SwiftUI / AppKit chrome. No invented screens.

---

## Verdict

The capture loop is real: menu extra → Start Recording → notes panel → on-device transcribe → summary (Apple FM / BYOK / local server) → library with search and markdown export. Dictation is in the tree (hold / double-tap Control-Option or Fn) but still compile-only — Mail / Notes / TextEdit have not been human-verified. Templates and “As follow-up email” already exist. What a stranger still cannot do is *trust the calendar* (no per-event list, no Internet Accounts copy), *rebind the talk chord*, or *opt into a recording when a meeting app turns a camera on*. Those are capture + trust, not summarizer toys.

Product Hunt is blocked on (1) a human dictation loop and (2) honest calendar / hotkey / camera-prompt chrome. Not on diarization, live captions, Sparkle, or Windows.

---

## Ranked: shipped vs still needed

| Item | State | Where it actually lives |
|---|---|---|
| **Summary templates (defaults + user-editable)** | **Shipped.** | Built-ins General / 1:1 / Standup / Sales call / Interview in `SummaryTemplate`. Settings → Summaries: default picker, custom add/edit/delete sheet (name + instructions). Meeting detail **Regenerate** menu lists every template. Do not rebuild a template studio. |
| **Email / follow-up summaries** | **Shipped.** | Summary bar: **Regenerate**, **Shorter**, **As follow-up email**. Email is a one-off (`Pipeline.generateOneOff`) — sheet **Follow-up email**, *“This draft isn’t saved with the meeting.”*, **Copy** / **Done**. |
| **Calendar record list** | **Designed 14 Aug, not built.** | EventKit `CalendarService` fetches ~24h. Auto-record is a global Settings radio (Off / `[record]` / meeting link / all) plus `startedEventIds`. Menu extra shows one upcoming line. Main window sidebar is Library only — no Calendar row, no per-event Default / Record / Skip, no This time / This series. |
| **Camera-in-use “Record this?”** | **Not built.** | We can see our *virtual* camera claimed (`CameraSinkClient.isVirtualCameraRunningSomewhere`). No watch on physical cameras. No HUD. Camera work is parked at Go Live / blur / logo. |
| **Rebindable dictation hotkey** | **Not built.** | Chord is hardcoded Control-Option, plus Fn alone (`DictationChord`). Settings → Transcription is a caption, not a picker. People already use Control-Option for other things. |
| **Onboarding / Internet Accounts** | **Partial.** | Setup checklist: mic, screen recording, calendar grant, speech model, summarizer. Calendar copy does not say Google/Outlook arrive via System Settings → Internet Accounts. No deep link. No Google OAuth (correct — do not add). |
| **Live transcript** | **Not built.** | PRD A4 stretch / post-v1. Pipeline is post-stop only. |
| **Diarization** | **Not built.** | E7.1. Segments have no speaker column in the UI. |
| **Search** | **Shipped.** | Library search field → FTS5 (`MeetingSearch`). Empty: *“No meetings match”*. |
| **Export** | **Shipped.** | Overflow **Export as Markdown…** (summary + notes + transcript). |
| **Signed updates** | **Not built.** | E4.1–E4.3. Dev-signed only. No Developer ID, notarization, Sparkle. |
| **Windows** | **Not built.** | PRD non-goal until macOS PMF. |
| **Retry → summary UI refresh** | **Known gap.** | `LibraryModel.retry` awaits `CrashRecovery.retry` → `Pipeline.process` (mix / transcribe / summarize). ValueObservation watches `meetings` rows, not `summaries`. After Retry the transcript can appear while the Summary tab stays on the old empty / stale string until you leave the meeting. |

### Already good enough (do not reopen)

- Dual-stream record, crash recovery, disk preflight, retention sweep (pin UI still missing — not this slice).
- WhisperKit + SpeechAnalyzer, in-app model download.
- Apple FM / Anthropic / OpenAI / local-server summarizers; BYOK keys in Keychain.
- Library-first main window, copper brand, slim menu extra.
- Virtual camera tracer (test card + passthrough). Feature work stays parked.

---

## This session vs later

### Ship this session (capture + trust)

Bias: finish the things that make recording *chosen and honest*. Templates and email already work.

1. **Rebindable dictation hotkey** — Settings → Transcription picker; persist; HUD / settings copy use the current chord. Default stays Control-Option + Fn.
2. **Calendar record list** — EventKit only. Sidebar **Calendar** above **Library**. Today + 7 days. Per event Default / Record / Skip; This time vs This series (this time wins). Meeting-link Record = mic + system; tagged in-person = mic only. Start only if Companion is running and the Mac is unlocked. Session banner always; never silent. Persist tags; keep `startedEventIds`.
3. **Camera-in-use prompt** — physical camera on (not our virtual camera / test card) → dictation-style tray *“Record this?”* Yes = mic + system, one-off. Never auto-start from camera alone. Ignore Photo Booth if cheap; always ignore Companion Camera.
4. **Onboarding Internet Accounts copy** — one step/row: Google / Outlook via System Settings → Internet Accounts. We read Apple Calendar. No Google sign-in. Deep link if stable, else the path. Do not rewrite E3.3.
5. **Retry → reload meeting detail** after transcription + summary finish, without leaving the meeting.

### Later (not this session)

- Human verify dictation in Mail / Gmail / Notes / TextEdit (Jay, this Mac).
- E3.3 onboarding rewrite, E4 signing / DMG / Sparkle, website.
- Live transcript, diarization, playback, ask-your-meetings.
- Camera scenes / standby card / auto-go-live.
- Chrome extension, Windows, paywall / license lock.
- Template studio (already exists). Retention pin control (column exists, no UI).

---

## Product Hunt bar

Ship when: a stranger can (a) hold a chosen chord and see text land in a focused field, (b) tag tomorrow’s Zoom as Record and see a banner when it starts, (c) dismiss a camera prompt without a silent recording. Positioning: **free local Wispr + private meeting companion**. Not “another Otter.”
