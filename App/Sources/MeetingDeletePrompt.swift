import AppKit
import MeetingCore

/// One delete confirmation for the meeting detail menu and the library list.
/// Default action removes audio; keeping gigabytes on disk is an explicit choice.
enum MeetingDeletePrompt {
    enum Choice {
        case deleteEverything
        case keepAudio
        case cancel
    }

    @MainActor
    static func run(for meeting: MeetingRow) -> Choice {
        let bytes = RecordingArtifacts.audioBytes(in: URL(fileURLWithPath: meeting.audioDir))
        let alert = NSAlert()
        alert.messageText = "Delete this meeting?"
        alert.alertStyle = .warning

        if bytes > 0 {
            alert.informativeText =
                "Notes, transcript, summary, and audio will be permanently deleted. "
                + "This meeting’s recordings use \(DiskSpace.describe(bytes)) on disk."
            alert.addButton(withTitle: "Delete Everything")
            alert.addButton(withTitle: "Delete Meeting, Keep Audio")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .deleteEverything
            case .alertSecondButtonReturn: return .keepAudio
            default: return .cancel
            }
        } else {
            alert.informativeText =
                "Notes, transcript, and summary will be permanently deleted. "
                + "There are no audio files on disk."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .deleteEverything : .cancel
        }
    }
}
