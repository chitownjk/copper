import SwiftUI

struct NotesPanelView: View {
    @Bindable var controller: NotesController

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            TextEditor(text: $controller.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .onChange(of: controller.text) { _, _ in
                    controller.textChanged()
                }
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
            Text("Notes — saved automatically")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
