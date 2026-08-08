import Foundation
import AppKit

enum MarkdownExporter {
    static func compose(
        title: String,
        startedAt: Double,
        summary: String,
        notes: [NoteEntryRow],
        segments: [SegmentRow]
    ) -> String {
        let date = Date(timeIntervalSince1970: startedAt)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var out = "# \(title)\n\n"
        out += "_\(formatter.string(from: date))_\n\n"

        if !summary.isEmpty {
            out += "## Summary\n\n"
            out += summary
            out += "\n\n"
        }

        if !notes.isEmpty {
            out += "## Notes\n\n"
            for note in notes {
                let ts = formatTimestampMs(note.tsMs)
                let indent = String(repeating: "  ", count: max(0, note.indentLevel))
                out += "\(indent)- [\(ts)] \(note.text)\n"
            }
            out += "\n"
        }

        if !segments.isEmpty {
            out += "## Transcript\n\n"
            for seg in segments {
                let ts = formatTimestampMs(seg.startMs)
                out += "**[\(ts)]** \(seg.text)\n\n"
            }
        }

        return out
    }

    @MainActor
    static func saveWithPanel(suggestedName: String, contents: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(suggestedName).md"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
