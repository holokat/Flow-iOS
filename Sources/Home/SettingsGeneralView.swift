import SwiftUI

struct SettingsGeneralView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    @State private var previewQuote: BreakReminderQuote?
    @State private var lastPreviewQuoteID: String?
    @StateObject private var liveReactsPreviewCoordinator = LiveReactsCoordinator()

    var body: some View {
        ThemedSettingsForm {
            Section {
                LabeledContent {
                    Picker("Break Reminder", selection: breakReminderIntervalBinding) {
                        ForEach(BreakReminderInterval.allCases) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                } label: {
                    HStack(spacing: 6) {
                        Text("Break Reminder")
                        SettingsInfoButton(
                            title: "Break Reminder",
                            message: "Halo shows a gentle reminder after it has stayed open for the selected time. Leaving the app or dismissing the reminder resets the timer."
                        )
                    }
                }

                Button {
                    presentPreviewReminder()
                } label: {
                    Label("Preview Reminder", systemImage: "hourglass.bottomhalf.filled")
                }

                SettingsToggleRow(
                    title: "Reaction Fountain",
                    isOn: Binding(
                        get: { appSettings.liveReactsEnabled },
                        set: { appSettings.liveReactsEnabled = $0 }
                    ),
                    footer: "Animate live reactions.",
                    info: "Reactions rise from the Pulse tab area while Halo is open."
                )

                Button {
                    liveReactsPreviewCoordinator.emitPreviewSequence()
                } label: {
                    Label("Preview Fountain", systemImage: "sparkles")
                }

                SettingsToggleRow(
                    title: "Floating Compose Button",
                    isOn: Binding(
                        get: { appSettings.floatingComposeButtonEnabled },
                        set: { appSettings.floatingComposeButtonEnabled = $0 }
                    ),
                    footer: "Show compose in the corner.",
                    info: nil
                )

                SettingsToggleRow(
                    title: "Hide NSFW Content",
                    isOn: Binding(
                        get: { appSettings.hideNSFWContent },
                        set: { appSettings.hideNSFWContent = $0 }
                    ),
                    footer: "Hide notes tagged NSFW.",
                    info: nil
                )

                SettingsToggleRow(
                    title: "Text Only Mode",
                    isOn: Binding(
                        get: { appSettings.textOnlyMode },
                        set: { appSettings.textOnlyMode = $0 }
                    ),
                    footer: "Replace media with placeholders.",
                    info: "Removes images and videos from notes and profiles to save bandwidth."
                )

                SettingsToggleRow(
                    title: "Slow Connection Mode",
                    isOn: Binding(
                        get: { appSettings.slowConnectionMode },
                        set: { appSettings.slowConnectionMode = $0 }
                    ),
                    footer: "Use a lighter relay setup.",
                    info: "Connects only to relay.damus.io and hides reactions to reduce relay load."
                )
            } header: {
                Text("General")
            } footer: {
                Text("Preview lets you test the reminder right away.")
            }

        }
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if let previewQuote {
                BreakReminderOverlayPresentation(
                    quote: previewQuote,
                    onDismiss: dismissPreviewReminder
                )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            GeometryReader { proxy in
                let previewWidth = max(84, min(proxy.size.width * 0.26, 118))

                LiveReactsOverlayHost(coordinator: liveReactsPreviewCoordinator)
                    .frame(width: previewWidth, height: 250, alignment: .bottom)
                    .offset(x: -18, y: -18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .allowsHitTesting(false)
        }
    }

    private var breakReminderIntervalBinding: Binding<BreakReminderInterval> {
        Binding(
            get: { appSettings.breakReminderInterval },
            set: { appSettings.breakReminderInterval = $0 }
        )
    }

    private func presentPreviewReminder() {
        let quote = BreakReminderQuote.next(excluding: lastPreviewQuoteID)
        lastPreviewQuoteID = quote.id

        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            previewQuote = quote
        }
    }

    private func dismissPreviewReminder() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
            previewQuote = nil
        }
    }
}
