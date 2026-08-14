# Meeting Companion — macOS UI / UX review

**Brand (locked):** [BRAND.md](BRAND.md) — name, copper accent, type, marks, and the three surfaces. This review is the chrome audit; BRAND.md is the identity. Do not reopen the name or accent.

**Date:** 14 August 2026 (ET)  
**Checkout:** `cd532ce` — *Open Camera settings to a live composed preview, and make delete/retention tell the truth about audio.*  
**Method:** Read the current SwiftUI / AppKit views. Every quoted string is in the shipping chrome. No invented screens. Dictation HUD is not in the tree.

---

## Verdict

A stranger who launches this build does not meet a meeting companion, and they do not meet a local Wispr. They meet a **settings app that happens to contain a library**. The main window (`Meeting Companion`, 900×560) opens on launch with one product row — **Library** — and five **Settings** rows (**Camera**, **General**, **Transcription**, **Summaries**, **Storage & Privacy**). The empty library then says *“Start a recording from the menu bar to populate your library.”* So the first ten seconds teach: this window is not the product; go find a waveform extra. That extra is a 336×520 scrolling dump of recording, virtual camera, calendar, Finder, four different “open a window” verbs, auto-record, and Quit.

Two locked tensions sit on top of that chrome. The PRD still sells a private Mac meeting companion (notes + virtual camera) and says *“Not a transcription tool.”* Jay, today, wants a free local-first Wispr Flow: double-tap anywhere → cleaned text in the focused field. Camera feature work is parked. The dictation spike is queued, not built. **This review picks one stranger-facing promise for the shipping UI: click the extra, start a recording, get notes / transcript / summary on this Mac.** That is the only complete loop that exists. Do not preview Wispr in this window, and do not keep Camera as a peer of Library. One product. One first gesture. Settings stay rare.

---

## The first gesture

**Click the menu-bar waveform → Start Recording.**

That is the only action a stranger can complete today that delivers the product. It is already the extra’s first button (`MenuBarView`, idle). A floating **Meeting Notes** panel appears (*“Notes — saved automatically”*). Stop is on the extra, the dock menu, the Meeting menu, the session banner, and the global Control-Option-Command-R safety net.

What a stranger actually feels in ten seconds, on this build:

1. Launch opens the main window (`AppDelegate.showWhenReady` → `mainWindow.show()`). First launch also opens **Meeting Notes Setup**.
2. Sidebar: **App / Library**, then **Settings / Camera, General, Transcription, Summaries, Storage & Privacy**.
3. Detail: waveform glyph, **Select a meeting**, and — if the library is empty — *“Start a recording from the menu bar to populate your library.”*
4. There is no **Start Recording** in the idle main window. The session banner only appears once something is already live.

So the window that claims to be the product points at a different surface, and that surface is overstuffed. The polish is not a new feature. It is making the extra *be* the first gesture, and making the window *be* the library.

If Jay later ships the Wispr spike, the first gesture becomes a global hold / double-tap and a HUD. That is a different chrome story. Do not design it here, and do not leave a settings dashboard sitting in the way.

**Primary chrome story (one):**

| Surface | Job |
|---|---|
| Menu extra | Daily product. Record / stop, next meeting, open the library, Quit. |
| Main window | Apple Notes: search + list + meeting. Not a settings host. |
| Settings (⌘,) | Rare prefs. Camera lives here while that work is parked. |
| Notes panel | Only while recording. Keep. |
| Dock | Reopen = library. Dock menu = Start/Stop + Open. |

Do not ship two products in one window. Do not keep a second Library window and a second Settings window next to a main window that already embeds both.

---

## What the app is today

### Window map

| Surface | Title / chrome | How you get there | What it actually is |
|---|---|---|---|
| Main window | **Meeting Companion** (`MainWindowController`) | Launch, dock reopen, extra **Open Meeting Companion**, Meeting menu | `NavigationSplitView`: 1 App row + 5 Settings rows. Nested `LibraryView` split inside the Library row. |
| Library window | **Meeting Notes Library** | Extra **Open Library** (⌘L) | A second, standalone `LibraryView`. Same model type, different instance. |
| Settings window | **Settings** | Extra **Settings…**, ⌘,, dock **Settings…** | TabView: **General**, **Transcription**, **Summaries**, **Storage & Privacy**. No Camera tab. `openSettings(tab:)` does not switch an already-open window. |
| Setup | **Meeting Notes Setup** / in-view **Setup** | First launch; extra **Setup…** | Checklist, not a rehearsal of the first gesture. |
| Notes panel | **Meeting Notes** | Starts with a recording | Floating utility. Header: **Notes — saved automatically**. |
| Menu extra | Tooltip **Meeting Companion**; popover 336×520 | Status item click | The real control surface, currently a settings dump. |
| Dock menu | — | Right-click dock icon | **Start/Stop Recording**, **Go Live (Virtual Camera)** / **Stop Virtual Camera**, **Open Meeting Companion**, **Settings…** |
| Session banner | On the main window only when recording, camera live, or virtual camera claimed | — | **● Recording** / **Stop Recording**; **● Camera Live** / **Stop Virtual Camera**; **Virtual camera in use (test card)** + **Go Live** |

`Info.plist` still names the bundle **MeetingNotes**. Usage strings say MeetingNotes. Window titles say Meeting Companion / Meeting Notes. There is no `LSUIElement`; this is a regular dock app that also owns a status item. `AppState` still comments as if it were “a menu-bar app with no dock icon.”

### Main window — real labels

Sidebar (`MainWindowView.MainSection`):

- Section **App**: **Library**
- Section **Settings**: **Camera**, **General**, **Transcription**, **Summaries**, **Storage & Privacy**

Library (`LibraryView`):

- Search field: **Search meetings**
- Empty detail: **Select a meeting**
- Empty library caption: *“Start a recording from the menu bar to populate your library.”*
- Row status: **● recording**, **mixing…**, **transcribing…**, **summarizing…**, **ready**, **failed**
- Row action: **Retry** (failed / stuck; not the live session)
- Context menu: **Delete Meeting**; swipe: **Delete**

Meeting detail (`MeetingDetailView`):

- Tabs: **Summary** / **Notes** / **Transcript**
- Header status: `meeting.statusEnum.rawValue` — the raw enum (`recording`, `mixing`, `transcribing`, `summarizing`, `ready`, `failed`)
- Overflow: **Export as Markdown…**, **Reveal Recording in Finder**, **Delete Meeting**
- Summary empty: *“No summary yet — recording may still be processing.”*
- Summary bar: **Regenerate**, **Shorter**, **As follow-up email**
- Email sheet: **Follow-up email**, *“This draft isn’t saved with the meeting.”*, **Copy** / **Copied**, **Done**
- Notes empty: *“No notes captured for this meeting.”*
- Transcript empty: **No transcript available.** + **Retry Transcription**

Camera pane (`CameraPaneView` — current, not an older mental model):

- Title **Camera**
- Opening the pane calls `goLive()` (preview + sink). Leaving it does not stop the feed.
- One 16:9 composed preview. Overlay while not live: **Starting camera…** or **Camera could not start**
- Failed copy (access): *“Camera access denied — enable it in System Settings > Privacy & Security > Camera”*
- Form: **Background** **None** / **Blur**; **Blur strength** Light / Medium / Strong (`rawValue.capitalized`); **Logo** **Add Logo…** / **Change…** / **Remove**; **Logo size** Small / Medium / Large; **Mirror output (flips what others see too)**
- Open panel: *“Choose a logo image (PNG with transparency works best).”*

Settings tabs (same views in the main sidebar *and* the Settings window, except Camera):

- **General**: **Start recording** — **Off** / **When title contains [record]** / **Events with a meeting link** / **All calendar events**. Caption explains the two-minute arm / one-minute start.
- **Transcription**: **Whisper (downloadable model)** / **Apple (no download)**; **Spoken language** including **Auto-detect**; model rows with **Download** / **Cancel** / **Delete**; **On disk**
- **Summaries**: **Template**; **Custom templates** empty caption about “Board minutes”; **Add Template…**; **Use** **Automatic (first available)**; provider rows **Ready** / **Needs an API key** / **Needs a server URL**; **Remove Key**; **Save & Test**; **Test Connection**; **Connection verified**
- **Storage & Privacy**: *“Audio is the expensive part…”*; **Retention** **Delete audio after 30 days** / **Delete audio once transcribed** / **Keep audio forever**; *“Pin a meeting in the library to keep its audio regardless of this setting.”*; **Recordings** / **Speech models** / **Free space**; **Reveal in Finder**; **Apply Retention Now**; **Where your data goes**

Delete (`MeetingDeletePrompt`) — honest, just shipped:

- **Delete this meeting?**
- With audio: *“Notes, transcript, summary, and audio will be permanently deleted. This meeting’s recordings use {size} on disk.”* Buttons: **Delete Everything** (default) / **Delete Meeting, Keep Audio** / **Cancel**
- No audio: *“Notes, transcript, and summary will be permanently deleted. There are no audio files on disk.”* **Delete** / **Cancel**

Setup (`OnboardingView` / `OnboardingChecks`):

- Header **Setup** — *“Grant the permissions and install the tools below to enable recording, transcription, and summarization.”*
- Rows: **Microphone access**, **Screen Recording (system audio)**, **Calendar access**, **Speech model ({name})**, **Summarizer**
- Actions: **Grant**, **Open Settings**, **Download**, **Install Help**
- Footer: **All checks passed** or *“N of M ready”*; **Re-check**
- Installed-model detail is a filesystem path. Summarizer has no button — it only narrates Settings.

Menu extra (`MenuBarView`), in order:

- Idle: **Start Recording** (⌘R in the popover)
- Recording: **● Recording**, **Stop Recording**
- Armed: **Armed: {title}** or **Armed for upcoming meeting**; **Start Now**; **Cancel Auto-Start**
- Camera: **Go Live (Virtual Camera)** / **● Camera Live** + **Stop Virtual Camera**; **Background**; **Blur Strength**; **Add Camera Logo…** / **Camera Logo: {filename}**; **Mirror Output (flips for viewers too)**
- Calendar: **Connect Calendar…** / **Calendar access denied** + **Open System Settings** / **No upcoming meetings** / **Upcoming** (`in 12m · Title — Zoom`); **Refresh Calendar**
- **Recent** — click opens the meeting’s `audioDir` in Finder, not the library
- **Reveal Recordings in Finder**
- **Open Meeting Companion**
- **Open Library**
- **Settings…**
- **Setup…**
- **Auto-Record: {mode}**
- **Quit**

Toasts that exist: **Recording started**, **Recording stopped** / *“Processing in background…”*, **Summary ready**, **Summary failed — transcript saved**, **Running out of disk space**, **Processing failed: {title}**, **Retrying transcription**, **Retry failed**.

Crash recovery (launch modal): **“{title}” didn’t finish recording/processing**; **Recover** / **Discard** / **Decide Later**.

---

## Reference takeaways

Only what transfers. Wispr’s audio always leaves the device; this app is local-first. That difference is a promise, not a layout.

**Wispr Flow** ([wisprflow.ai](https://wisprflow.ai), [docs.wisprflow.ai](https://docs.wisprflow.ai) — fetched 14 Aug 2026)

- Stranger promise is one sentence: *“Don’t type, just speak.”* The product is a gesture, not a window.
- First gesture: hold **fn** (push-to-talk) or double-tap for hands-free; release / stop pastes into the focused field. The Flow Bar is a HUD (listening bars, stop, cancel) — not a settings app.
- Setup rehearses the gesture on screen. Settings exist; they are not the home screen.
- Transfer: one verb, one HUD, paste-after-stop. Do not transfer the cloud, the Hub, or the account wall.
- Do not transfer into *this* window. The spike is not built. Building a fake Flow Bar on top of five Settings rows would be two products.

**Apple Notes**

- Daily path is library + editor. Search, list, note. Settings are not a sidebar section.
- Empty state is a place to start, not a caption that points at another surface.
- Transfer: the main window should be this, and only this.

**Superwhisper** ([superwhisper.com](https://superwhisper.com))

- First gesture is **⌥Space** anywhere. Menu extra is status (idle / listening / processing) plus Start/Stop, history, Settings, Quit. Optional: left-click toggles record, right-click opens the menu.
- Transfer: extra = state + the one verb. History is a window you open on purpose. Settings are Settings.

**CleanShot X**

- First gesture is a capture shortcut (or the extra). After the gesture, a small overlay offers the next verbs (copy / save / edit). Settings are behind **Settings…**.
- Transfer: gesture → small aftermath, not gesture → a 520-pt preferences popover.

**Things / Reminders (density only)**

- A list row is title + one quiet meta line. Status is a word a person would say, not a database enum.
- Transfer: meeting rows already do this; the detail header does not.

---

## Ranked findings

### 1. The main window is a settings app — P0

**Wrong.** Five of six sidebar rows are Settings. Camera — parked as a feature — is a peer of Library. A stranger’s first screen is preferences.

**Evidence.** `MainWindowView.swift` `MainSection`: labels **Library**, **Camera**, **General**, **Transcription**, **Summaries**, **Storage & Privacy**. Sidebar sections **App** and **Settings**. Empty library: *“Start a recording from the menu bar to populate your library.”* (`LibraryView.swift`)

**Reference.** Apple Notes does not put General / iCloud / Accounts in the notes sidebar. Wispr and Superwhisper do not open a preference host on launch.

**Change.** Main window = Library only. ⌘, and **Settings…** open the existing Settings window (add a **Camera** tab there — the pane already exists). Launch and dock reopen show the library, not Camera.

### 2. Three windows, four “open” verbs — P0

**Wrong.** Library and Settings each exist twice. The extra asks the user to choose among **Open Meeting Companion**, **Open Library**, **Settings…**, and **Setup…**.

**Evidence.** `MenuBarView.swift` those four buttons. `LibraryWindowController` title **Meeting Notes Library**. `SettingsWindowController` title **Settings**. `MainWindowController` title **Meeting Companion**. `openSettings(tab:)` fronts an existing Settings window without changing tab.

**Reference.** Superwhisper: one extra, one Settings window, one history. CleanShot: extra + Settings. Notes: one window.

**Change.** Extra keeps **Open Meeting Companion** (the library) and **Settings…**. Delete **Open Library**. **Setup…** only if a required check is not ok. Kill the standalone Library window or make it `show()` the main window.

### 3. The extra is a preferences panel, not a first gesture — P0

**Wrong.** The status-item popover is 336×520 and scrolls. Camera logo / blur / mirror, auto-record, Finder, and four window verbs sit above Quit. The first gesture is visible and then buried.

**Evidence.** `StatusItemController.swift` popover `336×520`, `MenuBarView` hosted in a `ScrollView`. Camera block duplicates `CameraPaneView`. **Recent** opens `row.audioDir` in Finder.

**Reference.** Superwhisper extra: Start/Stop, history, Settings, Quit. CleanShot extra: capture verbs, then Settings. Wispr: the extra is not the product; the hotkey + Flow Bar are.

**Change.** Extra, in order: **Start Recording** / **● Recording** + **Stop Recording**; one next-meeting line; **Open Meeting Companion**; **Settings…**; **Quit**. Camera: **Go Live** / **Stop Virtual Camera** only, and only while that work is still reachable. **Recent** opens that meeting in the library. Move Background / Logo / Mirror / Auto-Record to Settings.

### 4. Empty library has no first verb — P0

**Wrong.** The only empty-state instruction is to leave the window.

**Evidence.** `LibraryView.emptyDetail`: **Select a meeting** + *“Start a recording from the menu bar to populate your library.”* No **Start Recording** in the idle main window. Banner is gated on `recording || live || claimed`.

**Reference.** Notes empty state is a new note. Wispr onboarding puts the gesture on screen and makes you do it. CleanShot’s aftermath is the next verb, not a map.

**Change.** Empty library: one sentence (*“Record a meeting. Transcript and notes stay on this Mac.”*) and a prominent **Start Recording**. Keep the extra as the always-available twin, not the only door.

### 5. Detail header prints a raw enum — P1

**Wrong.** Destructive-adjacent status is a database string.

**Evidence.** `MeetingDetailView.swift` header: `Text(meeting.statusEnum.rawValue)` → `recording`, `mixing`, `transcribing`, `summarizing`, `ready`, `failed`. The same file’s list cousin uses **● recording** / **ready** / **failed**.

**Reference.** Things / Reminders: human words. The library row already has the mapping.

**Change.** Reuse `statusLabel` from `MeetingRowView`. Never show `rawValue` in chrome.

### 6. Storage copy lies about pin — P1

**Wrong.** Settings tells you to pin a meeting. There is no pin control.

**Evidence.** `SettingsView.swift`: *“Pin a meeting in the library to keep its audio regardless of this setting.”* `LibraryView` / `MeetingDetailView` have no pin. `MeetingRow.retentionPinned` and the sweeper exist. `IMPLEMENTATION_LOG` already names this gap.

**Reference.** Notes / Finder: a promised control is in the object’s menu, not only in a preference caption.

**Change.** Overflow menu: **Keep Audio** (toggle `retentionPinned`). Until that ships, delete the sentence.

### 7. Camera is still first-class chrome for parked work — P1

**Wrong.** Feature work is parked; the UI still leads with Camera (sidebar row, half the extra, dock **Go Live (Virtual Camera)**, auto-start on pane appear).

**Evidence.** `MainWindowView` Settings section first row **Camera**. `CameraPaneView.onAppear` → `goLive()`. `MenuBarView.cameraSection` is the largest idle block. Dock menu always offers Go Live.

**Reference.** Superwhisper does not put model-download UI on the extra. CleanShot does not put annotation settings on the capture menu.

**Change.** Camera settings stay (the live preview + honest mirror copy just shipped — keep that). Demote the extra to Go Live / Stop. Do not add scenes, standby cards, or a second preview. Do not start a dictation spike from this pane.

### 8. Naming is three products — P1

**Wrong.** The same binary answers to MeetingNotes, Meeting Companion, and Meeting Notes.

**Evidence.** `Info.plist` `CFBundleName` **MeetingNotes**. Windows: **Meeting Companion**, **Meeting Notes Library**, **Meeting Notes Setup**, panel **Meeting Notes**. Extra tooltip **Meeting Companion**. TCC strings: *“MeetingNotes records your microphone…”*

**Reference.** Wispr is Flow everywhere. Notes is Notes. Superwhisper is Superwhisper.

**Change.** One visible name: **Meeting Companion**. Bundle display name, window titles, extra tooltip, TCC strings. Defer a real brand / website.

### 9. Nested splits and leftover Library chrome — P2

**Wrong.** `LibraryView` is a `NavigationSplitView` (min 820) embedded in the main `NavigationSplitView`. Two sidebars, two column-width fights.

**Evidence.** `LibraryView.swift` lines 8–18; `MainWindowView` detail `case .library: LibraryView(...)`.

**Reference.** Notes is one split.

**Change.** When the main window *is* the library, drop the inner split’s outer frame and let the window own the columns.

### 10. Setup is a checklist, not the first gesture — P2

**Wrong.** First launch opens a permission list. The first recording is never rehearsed.

**Evidence.** `OnboardingView` header **Setup**. Checks: mic, screen recording, calendar, speech model, summarizer. Speech-model detail when installed is a folder path. Summarizer action is `nil`.

**Reference.** Wispr setup: grant mic → set shortcut → *try it*. PRD D3 already asked for a 10-second test meeting.

**Change.** This slice: hide **Setup…** from the extra when required checks pass; stop showing a filesystem path. Defer the E3.3 rewrite (welcome → permissions with a why → first recording).

### 11. A few remaining honesty nits — P2

**Wrong / weak.**

- **Apply Retention Now** (`StorageSettingsTab`) has no confirm and no “N meetings, {size}” preview.
- Crash **Discard** is a single click (Recover is first — good — but Discard is still immediate).
- Template trash and model **Delete** have no confirm (model **Delete** is disabled on the selected row — good).
- Library list has no empty row of its own; only the detail pane speaks.
- Search-with-no-hits has no empty state.

**Change.** Confirm **Apply Retention Now** with count + bytes. One empty-list line in the sidebar when `allMeetings.isEmpty` or search misses. Leave crash Recover/Discard order as-is.

---

## Recommended 1–2 day polish slice

Concrete screens and copy. No dictation HUD. No brand site. No camera features beyond moving the existing pane.

### Day 1 — one chrome story

1. **Main window = Library.** Remove Camera / General / Transcription / Summaries / Storage from `MainWindowView`’s sidebar. The window is search + list + detail. Flatten the nested split so there is one `NavigationSplitView`.
2. **Settings window gains Camera.** Put `CameraPaneView` in `SettingsView` as a tab (live preview on appear stays). ⌘, / extra **Settings…** / dock **Settings…** all go here. Fix `openSettings(tab:)` so a second call actually selects the tab.
3. **Retire the extra Library window.** **Open Library** becomes `mainWindow.show()`. Or delete the button.
4. **Cut the extra** to: Start/Stop (or Armed + Start Now / Cancel Auto-Start); one upcoming line; **Go Live** / **Stop Virtual Camera** (no blur/logo/mirror); **Open Meeting Companion**; **Settings…**; **Quit**. **Recent** opens the meeting in the library. Drop **Reveal Recordings**, **Setup…** (unless a required check failed), and the Auto-Record submenu.

### Day 2 — empty state, honesty, names

5. **Empty library** (no meetings):  
   **Record a meeting**  
   *Transcript, notes, and summary stay on this Mac.*  
   Button: **Start Recording**  
   Quiet caption: *Or click the waveform in the menu bar.*
6. **Empty library** (meetings exist, none selected): keep **Select a meeting**.
7. Replace `statusEnum.rawValue` in the detail header with the same labels as the list.
8. Overflow: **Keep Audio** toggle. If that slips, delete the Storage sentence about pinning.
9. Visible name **Meeting Companion** on the four window titles, extra tooltip, and the four TCC strings. Leave `CFBundleName` / bundle id if a rename is scary; fix what the stranger reads.
10. **Apply Retention Now** confirm: *“Delete audio from N meetings ({size})? Transcripts and notes stay.”*

Cap. If Day 2 slips, ship 1–4 + 5 + 7. That is the first gesture.

---

## What to defer

- **Dictation HUD / Wispr spike.** Not in the tree. When it starts, it gets its own first gesture (hold / double-tap → paste in the focused field) and must not land as another Settings row. Local-first is the wedge; say it in the HUD, not in a manifesto window.
- **Brand and website.** Working name is fine once the four titles agree. No marketing page until the first gesture is true.
- **Camera feature work.** Preview-on-open, one mirror toggle, honest delete/retention — done. Scenes, standby card, second preview, auto-go-live: parked.
- **E3.3 onboarding rewrite.** Checklist is ugly; it is not this week’s stranger problem once Setup is off the extra.
- **Playback, speakers, live transcript, ask-your-meetings.** Library density can wait until the window is only a library.

---

## Tension, stated

| | PRD (private meeting companion) | Jay 14 Aug 2026 (local Wispr) |
|---|---|---|
| First gesture | Extra → Start Recording; notes panel | Double-tap → text in the focused field |
| Main window | Library of meetings | Should barely exist |
| Camera | Pillar C, demoable | Parked |
| Audio | Stays on the Mac | Stays on the Mac (this is the only shared promise) |
| In this build | Partially built, chrome fights it | Not built |

Ship the left column’s first gesture until the right column exists. Do not merge them in one sidebar.
