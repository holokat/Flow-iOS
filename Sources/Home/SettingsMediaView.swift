import SwiftUI

struct SettingsMediaView: View {
    @EnvironmentObject private var appSettings: AppSettingsStore
    @State private var mediaCacheSizeDescription = "Calculating..."
    @State private var isClearingMediaCache = false
    @State private var isShowingClearMediaCacheConfirmation = false

    var body: some View {
        ThemedSettingsForm {
            Section {
                SettingsToggleRow(
                    title: "Blur Media From People I Don't Follow",
                    isOn: Binding(
                        get: { appSettings.blurMediaFromUnfollowedAuthors },
                        set: { appSettings.blurMediaFromUnfollowedAuthors = $0 }
                    ),
                    footer: "Images and videos from accounts you don't follow stay blurred until you tap to reveal them."
                )
            } header: {
                Text("Media")
            } footer: {
                Text("This only applies while you're signed in and does not blur your own posts.")
            }

            Section {
                SettingsToggleRow(
                    title: "Media Efficiency",
                    isOn: Binding(
                        get: { appSettings.mediaEfficiencyEnabled },
                        set: { appSettings.mediaEfficiencyEnabled = $0 }
                    ),
                    footer: "Use less data and battery."
                )

                SettingsToggleRow(
                    title: "File Size Limits",
                    isOn: Binding(
                        get: { appSettings.mediaFileSizeLimitsEnabled },
                        set: { appSettings.mediaFileSizeLimitsEnabled = $0 }
                    ),
                    footer: "Ask before loading very large images."
                )
                .disabled(!appSettings.mediaEfficiencyEnabled)
                .opacity(appSettings.mediaEfficiencyEnabled ? 1 : 0.55)

                SettingsToggleRow(
                    title: "Pause Large GIFs",
                    isOn: Binding(
                        get: { appSettings.largeGIFAutoplayLimitEnabled },
                        set: { appSettings.largeGIFAutoplayLimitEnabled = $0 }
                    ),
                    footer: "Show large GIFs as still previews."
                )
                .disabled(!appSettings.mediaEfficiencyEnabled)
                .opacity(appSettings.mediaEfficiencyEnabled ? 1 : 0.55)
            } header: {
                Text("Media Efficiency")
            } footer: {
                Text("You can turn these off anytime.")
            }

            Section {
                LabeledContent("Stored Media") {
                    if isClearingMediaCache {
                        ProgressView()
                    } else {
                        Text(mediaCacheSizeDescription)
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    SettingsDetailNavigationHost(title: "Diagnostics") {
                        SettingsMediaDiagnosticsView()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Diagnostics")
                            .foregroundStyle(.primary)

                        Text("Media cache and request stats.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }

                Button(role: .destructive) {
                    isShowingClearMediaCacheConfirmation = true
                } label: {
                    Text(isClearingMediaCache ? "Clearing..." : "Clear Media Cache")
                }
                .disabled(isClearingMediaCache)
            } header: {
                Text("Cache")
            } footer: {
                Text("Avatars and note images stay on disk so repeat visits and scrolling feel faster. Clearing this only removes cached media bytes, not your account or notes.")
            }
        }
        .navigationTitle("Media")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Clear Media Cache?", isPresented: $isShowingClearMediaCacheConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                clearMediaCache()
            }
        } message: {
            Text("This will remove cached avatars and note images from this device. Your account and notes will not be affected.")
        }
        .task {
            await refreshMediaCacheSize()
        }
    }

    private func refreshMediaCacheSize() async {
        let bytes = await FlowImageCache.shared.totalCacheSizeBytes()
        let description = bytes > 0
            ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            : "Empty"
        await MainActor.run {
            mediaCacheSizeDescription = description
        }
    }

    private func clearMediaCache() {
        guard !isClearingMediaCache else { return }
        isClearingMediaCache = true

        Task {
            await FlowImageCache.shared.clearAllCachedImages()
            await FlowImageCache.shared.resetDiagnostics()
            await refreshMediaCacheSize()
            await MainActor.run {
                isClearingMediaCache = false
            }
        }
    }
}

private struct SettingsMediaDiagnosticsView: View {
    @State private var diagnostics = FlowMediaCacheDiagnostics()
    @State private var mediaCacheBytes: Int64 = 0

    var body: some View {
        ThemedSettingsForm {
            Section {
                DiagnosticMetricRow(
                    title: "Stored Media",
                    value: byteDescription(mediaCacheBytes),
                    info: "Bytes currently stored on disk by Halo's shared media cache."
                )
                DiagnosticMetricRow(
                    title: "Cache Hit Rate",
                    value: cacheHitRateDescription,
                    info: "Share of tracked media requests served locally instead of the network in this app session."
                )
            } header: {
                Text("Cache")
            }

            Section {
                DiagnosticMetricRow(
                    title: "Disk Hits",
                    value: diagnostics.diskHitCount.formatted(),
                    info: "Tracked media requests served straight from on-device cache."
                )
                DiagnosticMetricRow(
                    title: "Network Fetches",
                    value: diagnostics.networkFetchCount.formatted(),
                    info: "Tracked media requests that went to the network this session."
                )
                DiagnosticMetricRow(
                    title: "Network Failures",
                    value: diagnostics.networkFailureCount.formatted(),
                    info: "Tracked media requests that failed over the network this session."
                )
                DiagnosticMetricRow(
                    title: "Cached Payload",
                    value: byteDescription(diagnostics.cacheServedByteCount),
                    info: "Bytes served locally from the shared media cache this session."
                )
                DiagnosticMetricRow(
                    title: "Network Payload",
                    value: byteDescription(diagnostics.networkServedByteCount),
                    info: "Bytes downloaded for tracked media requests this session."
                )
            } header: {
                Text("Media Requests")
            }

            Section {
                Button("Reset Session Diagnostics", role: .destructive) {
                    resetDiagnostics()
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshDiagnostics()
        }
        .refreshable {
            await refreshDiagnostics()
        }
    }

    private var cacheHitRateDescription: String {
        guard diagnostics.trackedRequestCount > 0 else { return "No data yet" }
        return diagnostics.cacheHitRate.formatted(
            .percent.precision(.fractionLength(1))
        )
    }

    private func byteDescription(_ byteCount: Int64) -> String {
        guard byteCount > 0 else { return "0 bytes" }
        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private func refreshDiagnostics() async {
        let snapshot = await FlowImageCache.shared.diagnosticsSnapshot()
        let totalCacheBytes = await FlowImageCache.shared.totalCacheSizeBytes()
        await MainActor.run {
            diagnostics = snapshot
            mediaCacheBytes = totalCacheBytes
        }
    }

    private func resetDiagnostics() {
        Task {
            await FlowImageCache.shared.resetDiagnostics()
            await refreshDiagnostics()
        }
    }
}

private struct DiagnosticMetricRow: View {
    let title: String
    let value: String
    let info: String?

    var body: some View {
        LabeledContent {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                if let info, !info.isEmpty {
                    SettingsInfoButton(title: title, message: info)
                }
            }
        }
    }
}
