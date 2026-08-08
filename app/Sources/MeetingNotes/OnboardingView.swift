import SwiftUI

struct OnboardingView: View {
    @Bindable var checks: OnboardingChecks

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(checks.items) { item in
                        CheckRow(item: item) { action in
                            Task { await checks.perform(action) }
                        }
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 540, height: 540)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Setup")
                .font(.title2.weight(.semibold))
            Text("Grant the permissions and install the tools below to enable recording, transcription, and summarization.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if checks.allPass {
                Label("All checks passed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Text("\(checks.items.filter { $0.status == .ok }.count) of \(checks.items.count) ready")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Re-check") { checks.refresh() }
        }
        .padding(12)
    }
}

private struct CheckRow: View {
    let item: CheckItem
    let onAction: (CheckAction) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if let action = item.action {
                Button(actionLabel(action)) { onAction(action) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .missing:
            Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange)
        case .unknown:
            Image(systemName: "circle").foregroundStyle(.secondary)
        }
    }

    private func actionLabel(_ action: CheckAction) -> String {
        switch action {
        case .requestMic:                  return "Grant"
        case .openScreenRecordingSettings: return "Open Settings"
        case .requestCalendar:             return "Grant"
        case .openInstallInstructions:     return "Install Help"
        case .downloadSpeechModel:         return "Download"
        }
    }
}
