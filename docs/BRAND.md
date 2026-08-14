# Meeting Companion — brand

One page. Locked. Do not reopen in a chrome pass.

## Name

| Surface | Copy |
|---|---|
| Shipping name | **Meeting Companion** |
| Short | **Companion** |
| Bundle ID | `com.strongrise.meetingcompanion` (keep) |
| Do not show | MeetingNotes, Meeting Notes, Meeting Notes Library, Meeting Notes Setup |

Window titles, the menu-extra tooltip, TCC / usage strings, onboarding, and the Dock all say **Meeting Companion**. The notes panel is **Notes**.

## Voice

Calm, precise, local. A Mac utility that records a meeting and keeps the notes here.

Not purple-AI. Not enterprise Slack. Not a settings app. Not a manifesto.

One stranger sentence: *Click the waveform, start a recording, get notes on this Mac.*

## Color

Prefer system materials plus this accent. No theme engine.

| Token | Light | Dark | Use |
|---|---|---|---|
| Accent | `#C4845A` | same copper | Start Recording, primary buttons, selected segment |
| Accent hover / selected | `#D4946A` | same | Hover, pressed, selected control |
| Surface (only if custom) | system paper / window | `#1C1916` | Window fill |
| Elevated (only if custom) | system | `#2A2520` | Cards, sidebar |

Do not paint every list row copper. Status red stays red (Recording). Destructive stays system red.

## Type

SF Pro. Meeting titles: `.title2` semibold. Body and lists stay system sizes. Never print a raw enum (`recording`, `mixing`, …). Human status: **Ready / Failed / Recording / Mixing / Transcribing / Summarizing**.

## Mark

| File | Job |
|---|---|
| `docs/brand/companion-icon-dock.png` | Dock / app icon — copper waveform in a ring on a charcoal squircle |
| `docs/brand/companion-mark-menubar.png` | Menu extra — 5-bar waveform, template (black, no fill) |
| `docs/brand/companion-library-mock.png` | Target library chrome |

The extra uses the 5-bar mark as a template image at 18pt. Recording may swap to a system record symbol so the state is obvious.

## Surfaces

The product is three places:

1. **Menu extra** — daily. Start/Stop, one upcoming line, Go Live / Stop Virtual Camera, Open Meeting Companion, Settings…, Quit. Recent (3) opens the meeting in the library.
2. **Main window** — Apple Notes: search + list + meeting. Title: Meeting Companion. Session banner when recording or camera is live.
3. **Settings (⌘,)** — rare. Camera, General, Transcription, Summaries, Storage & Privacy.

Empty library: **Start Recording** + *Recordings stay on this Mac.* Do not send people to the menu bar as if the window is useless.

Camera tweaks live in Settings. Dictation HUD is not this product yet.
