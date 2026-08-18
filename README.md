# Meeting Companion

**Free local dictation for Mac. Private meeting notes in the same app.**

Hold a key, speak, and the sentence lands in the focused field. Record Zoom, Meet, or the room. Audio and transcripts stay on this Mac. No account, no bot in the call, no word cap.

This README is the product page. There is no paid tier and no hosted site.

## Why it exists

Wispr Flow is good and expensive, and it hears everything in the cloud. Meeting Companion is the opposite bet: speak on this Mac, keep the audio here.

## What it does

- **Dictate anywhere.** Hold or double-tap a chord (Control-Option by default; you can rebind it). On-device speech to text, then the words paste into Mail, a browser, Notes, wherever you were typing.
- **Record a meeting.** Microphone plus system audio for Zoom / Meet / Teams. Microphone only for in-person 1:1s. Timestamped notes while it runs. Searchable library. Markdown export.
- **Transcribe and summarize on the Mac.** WhisperKit or Apple SpeechAnalyzer for the transcript. Optional Apple Intelligence summaries, or your own OpenAI / Anthropic key, or a local server (Ollama / LM Studio). Summaries are optional. A transcript still lands with nothing configured.
- **Tag the calendar.** Companion reads Apple Calendar. Add Google or Outlook in System Settings → Internet Accounts. There is no Google login in the app. Mark Default / Record / Skip per event or series.
- **Ad-hoc capture.** If a physical camera turns on, Companion can ask “Record this?” It never starts from the camera alone.

Virtual camera (blur, logo, standby card) exists and is parked. It is not the reason to install.

## What never leaves the Mac

Recording, transcription, notes, search, and calendar tags are local.

The only network the app may use, and only if you opt in:

- downloading a speech model
- a summarizer API key *you* pasted (your provider, your bill)
- a local server URL you pointed at

No Companion account. No transcript upload we operate.

## Requirements

- Apple Silicon Mac
- macOS 14 or later (macOS 26 / Apple Intelligence is where on-device summaries work with zero setup)
- Xcode, for now (the app is not notarized; you build it)

Grant Microphone, Screen Recording (for system audio), Speech, Accessibility (for dictation insert), and Calendar when asked.

## Build

```bash
git clone https://github.com/chitownjk/meeting-companion.git
cd meeting-companion
xcodebuild -project MeetingCompanion.xcodeproj -scheme MeetingNotes \
  -configuration Release -derivedDataPath .dd build
open .dd/Build/Products/Release/MeetingNotes.app
```

Or open `MeetingCompanion.xcworkspace` in Xcode and Run.

Tests: `cd Packages/MeetingKit && swift test`

Data lives in `~/Library/Application Support/MeetingNotes/`.

## Status

Usable on a daily driver. Dictation, recording, calendar tags, and summaries are in the shipping tree. Signed updates and a downloadable DMG are not. If you want this as a Product Hunt install, that is the remaining packaging work, not a paywall.

Working name is Meeting Companion. The real name is still open.

## License

MIT. Use it. Fork it. Do not pay for the local loop.
