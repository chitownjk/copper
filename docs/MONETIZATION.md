# Monetization — think, do not implement

**Date:** 14 August 2026 (ET)
**Thread:** Wispr is expensive; this should be free; Jay is open to a licensing split later.
**Constraint:** no paywall, no license lock, no BYOK tax in this (or the next) build.

---

## The promise we cannot break

Wispr Flow charges for a cloud that hears everything. Companion’s wedge is the opposite: **speak on this Mac, keep the audio here, no account, no word cap.** Charging for that is how you become the thing you are replacing.

Product Hunt line: **free local Wispr + a private meeting companion.** Not “freemium notes with a 30-minute wall.”

---

## Stay free forever

These cost us ~$0 per user (their silicon, their disk, their EventKit):

| Capability | Why it stays free |
|---|---|
| Local dictation (hold / double-tap → paste) | The Wispr gesture. The reason someone installs. |
| Local meeting transcribe (WhisperKit / SpeechAnalyzer) | Same engines as dictation. A cap here is a word-cap by another name. |
| Dual-stream record, notes panel, library, FTS search, markdown export | Already shipped; costs us nothing at inference time. |
| EventKit calendar + auto-record tags | Apple Calendar the user already pays Apple for. |
| On-device summary when Apple Foundation Models are available | Zero setup, zero our bill, fully private. |
| “None” summarizer (transcript only) | E1.6. A clean Mac still gets a searchable transcript. |
| BYOK (Anthropic / OpenAI keys the user already has) | **Do not charge for this.** Jay’s keys already work. Taxing “paste your own key” is a shakedown, and it trains people to hide keys from the honest app. |
| Local-server summarizer (Ollama / LM Studio) | Power-user silicon, not ours. |

If a future Pro SKU exists, it must not dim, watermark, or time-limit any row above.

---

## What could be paid without betraying “people should have this for free”

Only convenience, team, or optional cloud *we* operate — never the local loop.

| Maybe later | Why it is not a betrayal |
|---|---|
| **Signed auto-update convenience** | Sparkle + notarized updates are ops cost. A donation / tip / “keep updates easy” ask is honest. Manual download of a free build must remain. |
| **Optional cloud quota we host** | If we ever run a Companion-hosted summarizer (no key required). The user already has Apple FM + BYOK + local server for free. Hosted is laziness, not a right. |
| **Team** (shared library, admin, SSO) | PRD anti-persona for v1. Real B2B cost. New product, not a lock on the single-player app. |
| **Pro camera** (unlimited presets, no watermark on overlays, standby-card designer) | PRD §7 already sketched this. Camera is parked and is *not* the Wispr promise. A watermark on *overlays* (not on dictation, not on transcripts) is the only video gate that does not lie. |
| **Diarization / speaker rename at scale** | E7.1 is compute + UX. Could be Pro *after* a free “Speaker 1 / 2” exists, or stay free as a launch splash. Do not use it as the first paywall. |

Do **not** charge for: extra templates (the editor is ten lines of UserDefaults), regenerate, follow-up email, calendar tags, the camera *prompt*, or Accessibility.

---

## License key vs donation vs paid Pro later

| Model | Fit | Risk |
|---|---|---|
| **Donation / tip jar** (Paddle “pay what you want”, GitHub Sponsors) | Matches “this should be free.” Ships after Product Hunt without a lock. | Most people pay $0. Fine if the goal is trust, not ARR. |
| **Paid Pro later** (one-time or annual, direct — not MAS first) | License the *optional* column only. Offline grace. Free build remains the default download. | Feature-creep: every new idea gets stuffed into Pro until the free app feels gutted. Write the free-forever list into the license page before the first SKU. |
| **License key on day one** | Wrong. Nothing paid exists yet. A key dialog on a local dictation app is Wispr’s account wall with extra steps. | Kills Product Hunt. Do not build E8.2 until Pro camera or hosted quota is real. |
| **Mac App Store IAP** | Revisit after ScreenCaptureKit + system-extension sandbox story is honest. Not v1. | Sandbox vs system audio / extension is why PRD said direct sales first. |

**Recommendation:** ship Product Hunt as **free, no account, no key**. Put a quiet “Support Companion” in the About / website only after updates are signed. If money is needed, a **one-time Pro** for camera identity + hosted convenience — never for dictation, transcribe, EventKit, Apple FM, or BYOK. A licensing split (e.g. donate-now / Pro-later) is compatible with that; a paywall is not.

---

## BYOK is not a product

Charging to *use a key the user already paid OpenAI or Anthropic for* is the one pricing idea that would make Jay right to walk away. The Keychain path is a courtesy. Our cost is $0. If hosted Companion-summaries exist later, that is a different SKU with a different privacy label (“this transcript leaves the Mac”).

---

## Product Hunt positioning

**Headline:** Free local dictation for Mac. Private meeting notes on the same app.

**Sub:** Hold a key, speak, the sentence lands in the focused field. Record Zoom / Meet / the room. Audio and transcripts stay on this Mac. No bot, no account, no word cap.

**Do not say:** “Free tier.” “Pro coming soon” on the PH page. “Bring your own key — upgrade to use it.”

**Do say:** On-device Whisper / Apple Speech. Optional Apple Intelligence summaries. Optional *your* API key. Calendar via Internet Accounts, not a Google login.

---

## Decision (locked for this session)

- No paywall. No license lock. No SKU work.
- Free-forever list above is the contract.
- Revisit Pro only when signed updates or Pro camera are actually shipping.
