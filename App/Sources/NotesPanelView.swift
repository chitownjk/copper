import AppKit
import SwiftUI

struct NotesPanelView: View {
    @Bindable var controller: NotesController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            NotesEditorView(text: $controller.text, onChange: {
                controller.textChanged()
            })
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
            Text("Saved automatically")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Tab / ⇧Tab")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Plain-text notes editor that treats Tab / Shift-Tab as indent and
/// continues `- ` / `* ` lists on Return.
struct NotesEditorView: NSViewRepresentable {
    @Binding var text: String
    var onChange: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onChange: onChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay

        let textView = NotesTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.allowsUndo = true
        textView.string = text
        context.coordinator.textView = textView

        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onChange = onChange
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onChange: () -> Void
        weak var textView: NSTextView?

        init(text: Binding<String>, onChange: @escaping () -> Void) {
            self.text = text
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            let value = textView?.string ?? ""
            if text.wrappedValue != value {
                text.wrappedValue = value
            }
            onChange()
        }
    }
}

final class NotesTextView: NSTextView {
    override func insertTab(_ sender: Any?) {
        indentSelection(delta: 1)
    }

    override func insertBacktab(_ sender: Any?) {
        indentSelection(delta: -1)
    }

    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let loc = min(selectedRange().location, ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        var line = ns.substring(with: lineRange)
        if line.hasSuffix("\n") {
            line.removeLast()
        }

        var indentEnd = line.startIndex
        while indentEnd < line.endIndex {
            let ch = line[indentEnd]
            if ch == " " || ch == "\t" {
                indentEnd = line.index(after: indentEnd)
            } else {
                break
            }
        }
        let indent = String(line[..<indentEnd])
        let rest = String(line[indentEnd...])
        let marker: String
        if rest.hasPrefix("- ") {
            marker = "- "
        } else if rest.hasPrefix("* ") {
            marker = "* "
        } else {
            marker = ""
        }
        let content = rest.dropFirst(marker.count)

        if !marker.isEmpty && content.trimmingCharacters(in: .whitespaces).isEmpty {
            let replacement = indent
            if shouldChangeText(in: lineRange, replacementString: replacement) {
                replaceCharacters(in: lineRange, with: replacement)
                didChangeText()
                setSelectedRange(NSRange(location: lineRange.location + (replacement as NSString).length, length: 0))
            }
            return
        }

        super.insertNewline(sender)
        let prefix = indent + marker
        if !prefix.isEmpty {
            insertText(prefix, replacementRange: selectedRange())
        }
    }

    private func indentSelection(delta: Int) {
        let ns = string as NSString
        let selection = selectedRange()
        let lineRange = ns.lineRange(for: selection)
        let block = ns.substring(with: lineRange)
        let hadTrailingNewline = block.hasSuffix("\n")
        var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if hadTrailingNewline, lines.last == "" {
            lines.removeLast()
        }

        var firstLineShift = 0
        var newLines: [String] = []
        for (index, raw) in lines.enumerated() {
            var line = raw
            if delta > 0 {
                line = "  " + line
                if index == 0 { firstLineShift = 2 }
            } else if line.hasPrefix("  ") {
                line.removeFirst(2)
                if index == 0 { firstLineShift = -2 }
            } else if line.hasPrefix("\t") {
                line.removeFirst()
                if index == 0 { firstLineShift = -1 }
            }
            newLines.append(line)
        }

        var replacement = newLines.joined(separator: "\n")
        if hadTrailingNewline {
            replacement += "\n"
        }
        guard replacement != block else { return }
        if shouldChangeText(in: lineRange, replacementString: replacement) {
            replaceCharacters(in: lineRange, with: replacement)
            didChangeText()
            let newLocation = max(lineRange.location, selection.location + firstLineShift)
            setSelectedRange(NSRange(location: newLocation, length: selection.length))
        }
    }
}
