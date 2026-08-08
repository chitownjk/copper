import SwiftUI

struct LibraryView: View {
    @Bindable var model: LibraryModel

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
        .frame(minWidth: 820, minHeight: 520)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search meetings", text: $model.searchQuery)
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
            .padding(8)
            .background(.background.secondary)

            Divider()

            List(selection: Binding(
                get: { model.selectedMeetingId },
                set: { model.selectMeeting($0) }
            )) {
                ForEach(model.visibleMeetings) { meeting in
                    MeetingRowView(meeting: meeting).tag(meeting.id as String?)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Select a meeting")
                .font(.title3)
                .foregroundStyle(.secondary)
            if model.allMeetings.isEmpty {
                Text("Start a recording from the menu bar to populate your library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MeetingRowView: View {
    let meeting: MeetingRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(meeting.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(formatDate(meeting.startedAt))
                Text("·")
                Text(statusLabel(meeting.statusEnum))
                    .foregroundStyle(statusColor(meeting.statusEnum))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func formatDate(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: ts))
    }

    private func statusLabel(_ s: MeetingStatus) -> String {
        switch s {
        case .recording:    return "● recording"
        case .mixing:       return "mixing…"
        case .transcribing: return "transcribing…"
        case .summarizing:  return "summarizing…"
        case .ready:        return "ready"
        case .failed:       return "failed"
        }
    }

    private func statusColor(_ s: MeetingStatus) -> Color {
        switch s {
        case .recording:    return .red
        case .ready:        return .secondary
        case .failed:       return .orange
        default:            return .blue
        }
    }
}
