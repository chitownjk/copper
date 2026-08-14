import SwiftUI

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } detail: {
            if let meeting = model.selectedMeeting {
                MeetingDetailView(model: model, meeting: meeting)
            } else {
                emptyDetail
            }
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
            .listStyle(.sidebar)
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
