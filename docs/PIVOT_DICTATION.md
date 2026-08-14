# Pivot: local-first dictation (Wispr gesture, our engines)

**Date:** 14 August 2026 (ET)  
**Checkout:** spike on `main` after `381ab09` (brand + library-first chrome).  
**Status:** code-complete and Debug-compiled. Not human-verified in Mail / Notes / TextEdit from this session (no Accessibility grant in the agent).

Camera feature work stays parked. Brand chrome already shipped — do not reopen it. Dictation is the wedge.

## What Jay locked

Double-tap (or hold) in any app → speak → the sentence lands in the focused text field.

- Local only. No account. No word cap.
- Audio never leaves the Mac. The temp WAV is deleted after transcribe.
- Copy Wispr Flow’s *gesture*, not their cloud.

## Gesture

Talk chord: **Control-Option** (no Command / Shift). On Apple keyboards, **Fn alone** is the same chord; Fn plus anything else is ignored so brightness / F-keys do not start a session.

| Action | Result |
|---|---|
| Hold the chord ≥ 180 ms | Push-to-talk. Release pastes. |
| Double-tap the chord (second tap within 350 ms) | Hands-free. Same chord, Esc, or the HUD **Stop** button ends it. |
| Esc while listening | Cancel. Nothing is pasted. Audio is deleted. |

Partials are never streamed. Capture writes a temp file with the existing `MicRecorder` (`AVAudioEngine` + voice processing). On stop, `TranscriptionEngines.current()` (WhisperKit or SpeechAnalyzer, same Settings picker) transcribes the file. Then we insert.

The existing Control-Option-Command-R stop-recording hotkey is untouched: Command is on that chord, so it is not a talk chord.

## Insert

1. Refuse Secure Keyboard Entry (`IsSecureEventInputEnabled`) and `AXSecureTextField`.
2. Try `AXSelectedText` on the focused element (no clipboard).
3. Fall back to clipboard + synthetic ⌘V, then restore the pasteboard.
4. If both fail, leave the text on the clipboard and toast *Copied — paste with ⌘V*.

The HUD is a non-activating panel so we never steal key focus from Mail / Notes / TextEdit.

## Isolation

New types only:

| Where | What |
|---|---|
| `App/Sources/Dictation/` | Controller, hotkey tap, inserter, HUD, permissions |
| `Packages/MeetingKit/Sources/MeetingCore/DictationGesture.swift` | Hold / double-tap state machine |
| `Packages/MeetingKit/Sources/MeetingCore/DictationText.swift` | Join segments into one paste |

Reused: `TranscriptionEngine` / `WhisperKitEngine` / `SpeechAnalyzerEngine` / `WhisperModelManager` / `MicRecorder`. Not touched: calendar, dual-stream mix, virtual camera, meeting library, `CompanionVideoCore`.

A meeting recording and a dictation session cannot share the mic; dictation refuses if a meeting is live.

## Failure modes (expected)

| Situation | What happens |
|---|---|
| No Accessibility | System prompt. Session does not start. Settings → Transcription has **Grant Accessibility…**. |
| No microphone | TCC prompt on first use, or a toast if denied. |
| Speech model not downloaded (Whisper selected, not installed) | Toast pointing at Settings → Transcription. We do not start a 600 MB download from a hotkey. |
| Secure Keyboard Entry (Terminal menu, some password prompts) | Refused. |
| Password / secure text field | Refused. |
| Sandboxed or hostile apps (some App Store apps, games, a few terminals) | AX write and synthetic paste both fail. Text stays on the clipboard. |
| Event tap disabled by the system (lag) | Tap is re-enabled. If creation failed, we fall back to global/local `NSEvent` monitors (cannot swallow Esc). |
| Fn on a keyboard that does not emit `maskSecondaryFn` | Use Control-Option. |

## How Jay verifies (this Mac, Apple Silicon)

This session compiled Debug only. It did **not** dictate into Mail.

1. Build and run the Debug app (or the `xcodebuild` product under `/tmp/mc-dictation-dd/Build/Products/Debug/MeetingNotes.app`).
2. Grant **Microphone** and **Accessibility** (System Settings → Privacy & Security). Accessibility is required for the global chord and for insert.
3. Settings → Transcription: pick Apple (no download) or a downloaded Whisper model. Confirm the engine is ready.
4. Click into Mail / Notes / TextEdit (not a password field).
5. Hold Control-Option, speak a sentence, release. A small HUD should say Listening, then Transcribing. The sentence should appear at the cursor.
6. Double-tap Control-Option, speak, tap again (or Esc, or HUD Stop). Same paste-after-stop behaviour.
7. Confirm Esc cancels and pastes nothing.
8. Optional: Fn-only on the built-in keyboard.

If insert is silent, check the toast: Accessibility missing, secure field, or “Copied — paste with ⌘V”.

## What this session could not test

- Accessibility TCC / event tap on a real focused third-party field.
- Paste into Mail, Notes, or TextEdit.
- Fn on hardware (agent has no keyboard).
- Secure Keyboard Entry and password-field refusal on a live prompt.
- Whisper vs SpeechAnalyzer quality on a spoken dictation (engines themselves were already verified on meeting audio).

## Chrome

Brand pass (`381ab09`) stays. The extra still starts with **Start Recording**. Dictation only adds a Listening / Stop row while a session is active, a mic glyph on the extra, a Transcription settings note, and a Storage privacy line. No new Settings tab. No Camera / library entanglement.
