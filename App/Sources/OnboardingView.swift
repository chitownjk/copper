import SwiftUI

struct OnboardingView: View {
    @Bindable var checks: OnboardingChecks
    let onFinish: () -> Void
    let onSkip: () -> Void

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
        .tint(Brand.accent)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Copper")
                .font(.title2.weight(.semibold))
            Text("Start recording from the library or menu-bar waveform. Recordings stay on this Mac. Required checks unlock recording and dictation; camera, calendar, and summaries are optional.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if checks.allPass {
                Label("Required checks passed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                let required = checks.items.filter(\.isRequired)
                Text("\(required.filter { $0.status == .ok }.count) of \(required.count) required checks ready")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Re-check") { checks.refresh() }
            if checks.allPass {
                Button("Finish") { onFinish() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Skip for now") { onSkip() }
            }
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
                Text(item.isRequired ? "Required" : "Optional")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(item.isRequired ? Brand.accent : .secondary)
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
        case .requestCamera:               return "Grant"
        case .requestAccessibility:        return "Open Settings"
        case .requestSpeech:               return "Grant"
        case .openScreenRecordingSettings: return "Open Settings"
        case .requestCalendar:             return "Grant"
        case .openInternetAccounts:        return "Internet Accounts"
        case .installCameraExtension:      return "Install / Repair"
        case .downloadSpeechModel:         return "Download"
        }
    }
}
