# Copper privacy

**Effective date:** August 18, 2026

Copper is a local-first macOS application. It does not require an account and
does not include advertising, analytics, or third-party crash reporting.

## Data stored on your Mac

Copper stores recordings, transcripts, notes, summaries, preferences, and its
local database under your macOS user account. API keys are stored in Keychain.
Calendar access is read through macOS EventKit. You can delete meetings in the
app and configure automatic retention in Settings.

## When Copper uses the network

Copper makes a network request only when you choose a feature that requires it:

- downloading a Whisper speech model;
- sending transcript text to a summary provider you configured, such as
  Anthropic or OpenAI;
- contacting a local or custom summary server you configured;
- allowing macOS to obtain assets required by Apple Speech or Apple
  Intelligence.

Provider requests are governed by that provider’s privacy terms. Copper does
not send recordings, transcripts, notes, calendar data, or camera frames to a
Copper-operated service.

## macOS permissions

Copper may request Microphone, Screen Recording, Accessibility, Speech
Recognition, Camera, Calendar, and Camera Extension permissions. Each is used
only for the feature described in the permission prompt. Optional permissions
can remain disabled, with the corresponding feature unavailable or reduced
(for example, microphone-only recording without Screen Recording permission).

## Questions

For privacy questions or reports, open an issue at
https://github.com/chitownjk/copper/issues.
