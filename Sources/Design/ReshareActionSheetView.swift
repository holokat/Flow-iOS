import SwiftUI

struct ReshareActionSheetView: View {
    @Environment(\.dismiss) private var dismiss

    let isWorking: Bool
    let onRepost: () -> Void
    let onQuote: () -> Void

    var body: some View {
        NavigationStack {
            List {
                actionRow(title: "Repost", icon: "arrow.2.squarepath", showsProgress: isWorking, action: onRepost)
                actionRow(title: "Quote", icon: "quote.bubble", showsProgress: false, action: onQuote)
            }
            .navigationTitle("Re-share")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    ThemedToolbarDoneButton {
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(isWorking)
        .presentationDetents([.height(200), .medium])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func actionRow(
        title: String,
        icon: String,
        showsProgress: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer(minLength: 0)
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .disabled(isWorking)
    }
}
