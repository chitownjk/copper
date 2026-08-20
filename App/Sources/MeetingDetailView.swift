import SwiftUI
import MeetingCore
import AppKit
import MeetingProviders

enum DetailTab: String, CaseIterable, Identifiable {
    case summary, notes, transcript
    var id: String { rawValue }
    var label: String {
        switch self {
        case .summary:    return "Summary"
        case .notes:      return "Notes"
        case .transcript: return "Transcript"
        }
    }
}

struct MeetingDetailView: View {
    @Bindable var model: LibraryModel
    let meeting: MeetingRow
    @Environment(AppState.self) private var appState

    @State private var tab: DetailTab = .summary
    @State private var titleDraft: String = ""
    @State private var titleEditing: Bool = false
    @State private var player = MeetingAudioPlayer()

    private var canRetry: Bool {
        _ = model.audioRevision
        return CrashRecovery.isRetryable(
            meeting,
            hasTranscript: !model.detailSegments.isEmpty,
            liveMeetingId: appState.currentSession?.meeting.id
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            playerBar
            Divider()
            content
        }
        .onChange(of: meeting.id) { _, _ in
            titleDraft = meeting.title
            titleEditing = false
            tab = .summary
            reloadPlayer()
        }
        .onChange(of: model.audioRevision) { _, _ in
            reloadPlayer()
        }
        .onChange(of: meeting.status) { _, _ in
            // Mix lands during .mixing / .transcribing. The play button
            // appears as soon as mixed.wav exists, but the player was
            // loaded earlier with nothing — click no-ops until we reload.
            reloadPlayer()
        }
        .onAppear {
            titleDraft = meeting.title
            reloadPlayer()
        }
        .onDisappear {
            player.stop()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Group {
                    if titleEditing {
                        TextField("Title", text: $titleDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { commitTitle() }
                    } else {
                        Text(meeting.title)
                            .font(.title2.weight(.semibold))
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .onTapGesture(count: 2) {
                                titleDraft = meeting.title
                                titleEditing = true
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                if canRetry {
                    Button("Retry") {
                        model.retry(meeting)
                    }
                    .disabled(model.isRetrying)
                    if model.isRetrying {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Menu {
                    Button("Export as Markdown…") { exportMarkdown() }
                    Button("Reveal Recording in Finder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: meeting.audioDir))
                    }
                    if model.meetingHasAudio(meeting) {
                        Button("Delete Audio") {
                            model.deleteAudio(meeting)
                        }
                    }
                    Divider()
                    Button("Delete Meeting", role: .destructive) {
                        model.confirmAndDelete(meeting)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 32)
                .layoutPriority(2)
            }

            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    Text(formatDate(meeting.startedAt))
                    if let ended = meeting.endedAt {
                        Text("·")
                        Text(formatDuration(start: meeting.startedAt, end: ended))
                    }
                    Text("·")
                    Text(meeting.statusEnum.displayName)
                        .foregroundStyle(meeting.statusEnum.displayColor)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)

                Spacer(minLength: 8)

                Picker("", selection: $tab) {
                    ForEach(DetailTab.allCases) { t in
                        Text(t.label).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .fixedSize(horizontal: true, vertical: false)
                .tint(Brand.accent)
                .layoutPriority(2)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    /// Slim listen-back bar, visible on every tab. mixed.wav only — stems
    /// are never the playback source, even if they still exist.
    @ViewBuilder
    private var playerBar: some View {
        if hasVerifiedMix {
            HStack(spacing: 12) {
                Button {
                    if !player.isLoaded { reloadPlayer() }
                    player.toggle()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 22)
                }
                .buttonStyle(.plain)
                .help(player.isPlaying ? "Pause" : "Play")

                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 0.001)
                )

                Text("\(formatTimestampMs(Int(player.currentTime * 1000))) · \(formatTimestampMs(Int(player.duration * 1000)))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        } else if meeting.statusEnum == .ready {
            Text("Audio deleted")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
        }
    }

    private var hasVerifiedMix: Bool {
        _ = model.audioRevision
        return RecordingArtifacts.isMixVerified(in: URL(fileURLWithPath: meeting.audioDir))
    }

    private func reloadPlayer() {
        let dir = URL(fileURLWithPath: meeting.audioDir)
        if RecordingArtifacts.isMixVerified(in: dir) {
            player.load(url: RecordingArtifacts.mixedURL(in: dir))
        } else {
            player.stop()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .summary:    summaryView
        case .notes:      notesView
        case .transcript: transcriptView
        }
    }

    private var summaryView: some View {
        VStack(spacing: 0) {
            summaryActionBar
            Divider()
            ScrollView {
                if model.detailSummary.isEmpty {
                    placeholder("No summary yet — recording may still be processing.")
                } else {
                    Text(model.detailSummary)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { model.emailDraft != nil },
            set: { if !$0 { model.emailDraft = nil } }
        )) {
            EmailDraftSheet(draft: model.emailDraft ?? "")
        }
    }

    /// E2.6. Disabled while a transcript is missing — there is nothing to
    /// summarize — and while an action is already running.
    private var summaryActionBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(SummaryTemplateStore.all) { template in
                    Button(template.name) {
                        model.regenerateSummary(template: template)
                    }
                }
            } label: {
                Label("Regenerate", systemImage: "arrow.clockwise")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button("Shorter") {
                model.regenerateSummary(template: .shorter)
            }

            Button("As follow-up email") {
                model.generateFollowUpEmail()
            }

            if model.isGeneratingSummaryAction {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 4)
            }
            Spacer()
        }
        .controlSize(.small)
        .disabled(model.isGeneratingSummaryAction || model.detailSegments.isEmpty)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var notesView: some View {
        ScrollView {
            if model.detailNotes.isEmpty {
                placeholder("No notes captured for this meeting.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.detailNotes, id: \.id) { note in
                        let currentMs = Int(player.currentTime * 1000)
                        let highlighted = hasVerifiedMix && currentMs >= note.tsMs && currentMs < note.tsMs + 3000
                        Button {
                            guard hasVerifiedMix else { return }
                            player.seek(to: Double(note.tsMs) / 1000)
                            if !player.isPlaying { player.play() }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text(formatTimestampMs(note.tsMs))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .leading)
                                Text(String(repeating: "  ", count: max(0, note.indentLevel)) + "• \(note.text)")
                                    .font(.system(size: 13, weight: highlighted ? .medium : .regular))
                                    .multilineTextAlignment(.leading)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                highlighted
                                    ? Brand.accent.opacity(0.16)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasVerifiedMix)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var transcriptView: some View {
        ScrollView {
            if model.detailSegments.isEmpty {
                VStack(spacing: 12) {
                    Text("No transcript available.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    if canRetry {
                        Button("Retry Transcription") {
                            model.retry(meeting)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRetrying)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.detailSegments, id: \.id) { seg in
                        let currentMs = Int(player.currentTime * 1000)
                        let highlighted = currentMs >= seg.startMs && currentMs < seg.endMs
                        Button {
                            player.seek(to: Double(seg.startMs) / 1000)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text(formatTimestampMs(seg.startMs))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 70, alignment: .leading)
                                Text(seg.text)
                                    .font(.system(size: 13, weight: highlighted ? .medium : .regular))
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                highlighted
                                    ? Brand.accent.opacity(0.16)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != meeting.title else {
            titleEditing = false
            return
        }
        Task {
            await model.renameSelected(to: trimmed)
            titleEditing = false
        }
    }

    private func exportMarkdown() {
        let md = MarkdownExporter.compose(
            title: meeting.title,
            startedAt: meeting.startedAt,
            summary: model.detailSummary,
            notes: model.detailNotes,
            segments: model.detailSegments
        )
        let safeName = meeting.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|"))
            .joined(separator: "-")
        MarkdownExporter.saveWithPanel(suggestedName: safeName, contents: md)
    }

    private func formatDate(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    private func formatDuration(start: Double, end: Double) -> String {
        let secs = max(0, Int(end - start))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

/// The "As follow-up email" result: copyable, never stored (E2.6).
private struct EmailDraftSheet: View {
    let draft: String
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Follow-up email")
                .font(.headline)
            ScrollView {
                Text(draft)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Text("This draft isn’t saved with the meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(draft, forType: .string)
                    copied = true
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480, height: 400)
    }
}
