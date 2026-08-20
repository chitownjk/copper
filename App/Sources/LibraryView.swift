import SwiftUI

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @Environment(AppState.self) private var appState

    var body: some View {
        // Not a nested NavigationSplitView — that collapses the
        // Calendar/Library sidebar when a meeting is selected.
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            Group {
                if let meeting = model.selectedMeeting {
                    MeetingDetailView(model: model, meeting: meeting)
                } else {
                    emptyDetail
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .onChange(of: model.searchQuery) { _, _ in
                        model.searchChanged()
                    }
                if !model.searchQuery.isEmpty {
                    Button {
                        model.searchQuery = ""
                        model.searchChanged()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.background.secondary)

            Divider()

            List(selection: Binding(
                get: { model.selectedMeetingId },
                set: { model.selectMeeting($0) }
            )) {
                if model.allMeetings.isEmpty {
                    Text("No meetings yet")
                        .foregroundStyle(.secondary)
                } else if model.visibleMeetings.isEmpty {
                    Text("No meetings match")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.visibleMeetings) { meeting in
                    MeetingRowView(
                        meeting: meeting,
                        onRetry: showsRowRetry(meeting) ? { model.retry(meeting) } : nil
                    )
                    .tag(meeting.id as String?)
                    .contextMenu {
                        Button("Delete Meeting", role: .destructive) {
                            model.confirmAndDelete(meeting)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) {
                            model.confirmAndDelete(meeting)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func showsRowRetry(_ meeting: MeetingRow) -> Bool {
        _ = model.audioRevision
        return CrashRecovery.isRetryable(
            meeting,
            hasTranscript: meeting.statusEnum == .ready,
            liveMeetingId: appState.currentSession?.meeting.id
        )
    }

    @ViewBuilder
    private var emptyDetail: some View {
        if model.allMeetings.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "waveform")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Brand.accent)
                Text("Record a meeting")
                    .font(.title2.weight(.semibold))
                Text("Recordings stay on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Start Recording") {
                    Task { await appState.startRecording() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Brand.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Select a meeting")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MeetingRowView: View {
    let meeting: MeetingRow
    var onRetry: (() -> Void)?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(formatDate(meeting.startedAt))
                    Text("·")
                    Text(meeting.statusEnum.displayName)
                        .foregroundStyle(meeting.statusEnum.displayColor)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let onRetry {
                Button("Retry") { onRetry() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDate(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}
