import SwiftUI

@MainActor
final class LiveReactsCoordinator: ObservableObject {
    @Published private(set) var emissions: [LiveReactionEmission] = []

    func emit(_ reaction: ActivityReaction) {
        let emission = LiveReactionEmission(
            reaction: reaction,
            horizontalDrift: CGFloat.random(in: 0.42...0.72) * (Bool.random() ? -1 : 1),
            sway: CGFloat.random(in: -0.18...0.18),
            rotation: Double.random(in: -28...28),
            startScale: CGFloat.random(in: 0.52...0.74),
            middleScaleMultiplier: CGFloat.random(in: 2.85...3.35),
            endScaleMultiplier: CGFloat.random(in: 4.1...5.2),
            size: CGFloat.random(in: 42...56),
            duration: Double.random(in: 3.0...4.1),
            opacity: Double.random(in: 0.78...0.98)
        )
        emissions.append(emission)
        AppHaptics.liveReactionTick()

        Task { [weak self] in
            let lifetime = UInt64((emission.duration + 0.25) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: lifetime)
            await MainActor.run {
                self?.emissions.removeAll { $0.id == emission.id }
            }
        }
    }

    func emitPreviewSequence() {
        let previewReactions: [ActivityReaction] = [
            ActivityReaction(content: "+", shortcode: nil, customEmojiImageURL: nil),
            ActivityReaction(content: "🔥", shortcode: nil, customEmojiImageURL: nil),
            ActivityReaction(content: "😂", shortcode: nil, customEmojiImageURL: nil),
            ActivityReaction(content: "😍", shortcode: nil, customEmojiImageURL: nil),
            ActivityReaction(content: "👏", shortcode: nil, customEmojiImageURL: nil)
        ]

        for (index, reaction) in previewReactions.enumerated() {
            Task { [weak self] in
                let delay = UInt64(index) * 220_000_000
                try? await Task.sleep(nanoseconds: delay)
                await MainActor.run {
                    self?.emit(reaction)
                }
            }
        }
    }
}

@MainActor
final class LiveReactsSubscriptionController: ObservableObject {
    private let liveSubscriber: any NostrLiveEventSubscribing
    private let relayClient: any NostrRelayEventFetching
    private var liveUpdatesTask: Task<Void, Never>?
    private var catchUpTask: Task<Void, Never>?
    private var catchUpEmissionTask: Task<Void, Never>?
    private var catchUpToken = 0
    private var subscriptionSignature: String?
    private var currentUserPubkey: String?
    private var readRelayURLs: [URL] = []
    private var isEnabled = false
    private var scenePhase: ScenePhase = .inactive
    private var onReaction: ((ActivityReaction) -> Void)?
    private var seenEventIDs = Set<String>()
    private var seenEventOrder: [String] = []
    private var pendingCatchUpReactions: [ActivityReaction] = []
    private var latestReactionCreatedAt: Int?

    private let maxTrackedEventIDs: Int
    private let catchUpMinimumInterval: TimeInterval
    private let catchUpDefaultLookbackSeconds: Int
    private let catchUpMaximumLookbackSeconds: Int
    private let catchUpCursorOverlapSeconds: Int
    private let catchUpLimit: Int
    private let catchUpTimeout: TimeInterval
    private let catchUpEmissionIntervalNanoseconds: UInt64
    private let maximumQueuedCatchUpReactions: Int
    private let now: () -> Date
    private var lastCatchUpByRelaySignature: [String: Date] = [:]

    init(
        liveSubscriber: any NostrLiveEventSubscribing = NostrLiveFeedSubscriber(),
        relayClient: any NostrRelayEventFetching = NostrRelayClient(),
        maxTrackedEventIDs: Int = 2_048,
        catchUpMinimumInterval: TimeInterval = 15,
        catchUpDefaultLookbackSeconds: Int = 30,
        catchUpMaximumLookbackSeconds: Int = 300,
        catchUpCursorOverlapSeconds: Int = 2,
        catchUpLimit: Int = 120,
        catchUpTimeout: TimeInterval = 4,
        catchUpEmissionIntervalNanoseconds: UInt64 = 220_000_000,
        maximumQueuedCatchUpReactions: Int = 12,
        now: @escaping () -> Date = Date.init
    ) {
        self.liveSubscriber = liveSubscriber
        self.relayClient = relayClient
        self.maxTrackedEventIDs = max(maxTrackedEventIDs, 1)
        self.catchUpMinimumInterval = max(catchUpMinimumInterval, 0)
        self.catchUpDefaultLookbackSeconds = max(catchUpDefaultLookbackSeconds, 0)
        self.catchUpMaximumLookbackSeconds = max(
            catchUpMaximumLookbackSeconds,
            catchUpDefaultLookbackSeconds
        )
        self.catchUpCursorOverlapSeconds = max(catchUpCursorOverlapSeconds, 0)
        self.catchUpLimit = max(catchUpLimit, 1)
        self.catchUpTimeout = max(catchUpTimeout, 0.1)
        self.catchUpEmissionIntervalNanoseconds = catchUpEmissionIntervalNanoseconds
        self.maximumQueuedCatchUpReactions = max(maximumQueuedCatchUpReactions, 1)
        self.now = now
    }

    deinit {
        liveUpdatesTask?.cancel()
        catchUpTask?.cancel()
        catchUpEmissionTask?.cancel()
    }

    func update(
        currentUserPubkey: String?,
        readRelayURLs: [URL],
        isEnabled: Bool,
        scenePhase: ScenePhase,
        onReaction: ((ActivityReaction) -> Void)? = nil
    ) {
        let normalizedUser = normalizePubkey(currentUserPubkey)
        let normalizedRelays = normalizedRelayURLs(readRelayURLs)
        let userChanged = normalizedUser != self.currentUserPubkey

        self.currentUserPubkey = normalizedUser
        self.readRelayURLs = normalizedRelays
        self.isEnabled = isEnabled
        self.scenePhase = scenePhase

        if let onReaction {
            self.onReaction = onReaction
        }

        if userChanged {
            resetSeenEventTracking()
        }

        refreshSubscription(forceRestart: userChanged)
    }

    private func refreshSubscription(forceRestart: Bool = false) {
        guard isEnabled,
              scenePhase == .active,
              let user = currentUserPubkey,
              !user.isEmpty,
              !readRelayURLs.isEmpty else {
            stopSubscription(resetSeenEvents: !isEnabled || currentUserPubkey == nil)
            return
        }

        let liveSince = recoverySince(timestamp: Int(now().timeIntervalSince1970))
        let filter = NostrFilter(
            kinds: [7],
            since: liveSince,
            tagFilters: ["p": [user]]
        )
        let signature = readRelayURLs
            .map { $0.absoluteString.lowercased() }
            .sorted()
            .joined(separator: "|") + "|\(user)|\(scenePhase == .active)"
        let relays = readRelayURLs

        if !forceRestart,
           liveUpdatesTask != nil,
           subscriptionSignature == signature {
            return
        }

        stopSubscription(resetSeenEvents: false)
        subscriptionSignature = signature

        liveUpdatesTask = Task { [weak self] in
            guard let self else { return }

            await withTaskGroup(of: Void.self) { group in
                for relayURL in relays {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        await self.liveSubscriber.run(
                            relayURL: relayURL,
                            filter: filter,
                            onNewEvent: { [weak self] event in
                                guard let self else { return }
                                await self.handleIncomingReactionEvent(event)
                            },
                            onStatus: { [weak self] _ in
                                guard let self else { return }
                                await self.scheduleCatchUp(
                                    relays: relays,
                                    filter: filter
                                )
                            }
                        )
                    }
                }
                await group.waitForAll()
            }
        }

        scheduleCatchUp(relays: relays, filter: filter, force: true)
    }

    private func stopSubscription(resetSeenEvents: Bool) {
        liveUpdatesTask?.cancel()
        liveUpdatesTask = nil
        catchUpTask?.cancel()
        catchUpTask = nil
        catchUpEmissionTask?.cancel()
        catchUpEmissionTask = nil
        pendingCatchUpReactions = []
        subscriptionSignature = nil

        if resetSeenEvents {
            resetSeenEventTracking()
            lastCatchUpByRelaySignature = [:]
        }
    }

    private func scheduleCatchUp(
        relays: [URL],
        filter: NostrFilter,
        force: Bool = false
    ) {
        guard catchUpTask == nil else { return }
        let currentTime = now()
        let dueRelays = relays.filter { relayURL in
            let signature = relayURL.absoluteString.lowercased()
            guard !force else { return true }
            guard let lastFetch = lastCatchUpByRelaySignature[signature] else { return true }
            return currentTime.timeIntervalSince(lastFetch) >= catchUpMinimumInterval
        }
        guard !dueRelays.isEmpty else { return }

        dueRelays.forEach { relayURL in
            lastCatchUpByRelaySignature[relayURL.absoluteString.lowercased()] = currentTime
        }

        catchUpToken &+= 1
        let token = catchUpToken
        catchUpTask = Task(priority: .utility) { [weak self, dueRelays, filter] in
            guard let self else { return }
            await self.performCatchUp(relays: dueRelays, filter: filter)
            await MainActor.run { [weak self] in
                guard let self, self.catchUpToken == token else { return }
                self.catchUpTask = nil
            }
        }
    }

    private func performCatchUp(relays: [URL], filter: NostrFilter) async {
        guard !relays.isEmpty else { return }

        let catchUpUntil = Int(now().timeIntervalSince1970)
        let catchUpSince = recoverySince(timestamp: catchUpUntil)
        let relayClient = relayClient
        let timeout = catchUpTimeout
        var catchUpFilter = filter
        catchUpFilter.since = catchUpSince
        catchUpFilter.until = catchUpUntil
        catchUpFilter.limit = max(catchUpFilter.limit ?? 0, catchUpLimit)
        let fetchFilter = catchUpFilter

        var recoveredEvents: [NostrEvent] = []
        await withTaskGroup(of: [NostrEvent].self) { group in
            for relayURL in relays {
                group.addTask {
                    do {
                        return try await relayClient.fetchEvents(
                            relayURL: relayURL,
                            filter: fetchFilter,
                            timeout: timeout
                        )
                    } catch {
                        return []
                    }
                }
            }

            for await events in group {
                guard !Task.isCancelled else { return }
                recoveredEvents.append(contentsOf: events)
            }
        }

        guard !Task.isCancelled else { return }
        recoveredEvents.sort {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id < $1.id
        }

        var reactions: [ActivityReaction] = []
        for event in recoveredEvents {
            if let reaction = registerReactionEvent(event) {
                reactions.append(reaction)
            }
        }
        enqueueCatchUpReactions(reactions)
    }

    private func handleIncomingReactionEvent(_ event: NostrEvent) async {
        guard let reaction = registerReactionEvent(event) else { return }
        onReaction?(reaction)
    }

    private func registerReactionEvent(_ event: NostrEvent) -> ActivityReaction? {
        guard event.kind == 7 else { return nil }
        guard let user = currentUserPubkey, !user.isEmpty else { return nil }
        guard event.mentionedPubkeys.contains(where: { $0.lowercased() == user }) else { return nil }
        guard normalizePubkey(event.pubkey) != user else { return nil }

        let normalizedEventID = event.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEventID.isEmpty else { return nil }
        guard registerSeenEventID(normalizedEventID) else { return nil }

        guard let reaction = event.activityAction?.reaction else { return nil }
        latestReactionCreatedAt = max(latestReactionCreatedAt ?? 0, event.createdAt)
        return reaction
    }

    private func enqueueCatchUpReactions(_ reactions: [ActivityReaction]) {
        guard !reactions.isEmpty else { return }

        pendingCatchUpReactions.append(contentsOf: reactions)
        if pendingCatchUpReactions.count > maximumQueuedCatchUpReactions {
            pendingCatchUpReactions.removeFirst(
                pendingCatchUpReactions.count - maximumQueuedCatchUpReactions
            )
        }
        guard catchUpEmissionTask == nil else { return }

        catchUpEmissionTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled, !self.pendingCatchUpReactions.isEmpty {
                let reaction = self.pendingCatchUpReactions.removeFirst()
                self.onReaction?(reaction)

                if !self.pendingCatchUpReactions.isEmpty {
                    try? await Task.sleep(
                        nanoseconds: self.catchUpEmissionIntervalNanoseconds
                    )
                }
            }

            if !Task.isCancelled {
                self.catchUpEmissionTask = nil
            }
        }
    }

    private func recoverySince(timestamp: Int) -> Int {
        let maximumLookbackFloor = max(timestamp - catchUpMaximumLookbackSeconds, 0)
        guard let latestReactionCreatedAt else {
            return max(timestamp - catchUpDefaultLookbackSeconds, 0)
        }

        let cursor = min(
            max(latestReactionCreatedAt - catchUpCursorOverlapSeconds, 0),
            timestamp
        )
        return max(cursor, maximumLookbackFloor)
    }

    private func registerSeenEventID(_ eventID: String) -> Bool {
        guard seenEventIDs.insert(eventID).inserted else { return false }

        seenEventOrder.append(eventID)
        if seenEventOrder.count > maxTrackedEventIDs,
           let removedEventID = seenEventOrder.first {
            seenEventOrder.removeFirst()
            seenEventIDs.remove(removedEventID)
        }
        return true
    }

    private func resetSeenEventTracking() {
        seenEventIDs = []
        seenEventOrder = []
        latestReactionCreatedAt = nil
    }

    private func normalizePubkey(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func normalizedRelayURLs(_ relayURLs: [URL]) -> [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []

        for relayURL in relayURLs {
            let normalized = relayURL.absoluteString.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(relayURL)
        }

        return ordered
    }
}

struct LiveReactionEmission: Identifiable, Equatable {
    let id = UUID()
    let reaction: ActivityReaction
    let horizontalDrift: CGFloat
    let sway: CGFloat
    let rotation: Double
    let startScale: CGFloat
    let middleScaleMultiplier: CGFloat
    let endScaleMultiplier: CGFloat
    let size: CGFloat
    let duration: Double
    let opacity: Double
}

struct LiveReactsOverlayHost: View {
    @ObservedObject var coordinator: LiveReactsCoordinator

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                ForEach(coordinator.emissions) { emission in
                    LiveReactionParticleView(
                        emission: emission,
                        containerSize: geometry.size
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct LiveReactionParticleView: View {
    let emission: LiveReactionEmission
    let containerSize: CGSize

    @State private var progress: CGFloat = 0

    var body: some View {
        particle
            .modifier(
                LiveReactionFountainModifier(
                    progress: progress,
                    emission: emission,
                    containerSize: containerSize
                )
            )
            .onAppear {
                withAnimation(.easeOut(duration: emission.duration)) {
                    progress = 1
                }
            }
    }

    @ViewBuilder
    private var particle: some View {
        if let customEmojiURL = emission.reaction.customEmojiImageURL {
            CachedAsyncImage(url: customEmojiURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                default:
                    fallbackParticle
                }
            }
            .frame(width: emission.size, height: emission.size)
            .shadow(color: Color.black.opacity(0.16), radius: 6, x: 0, y: 4)
        } else {
            fallbackParticle
        }
    }

    @ViewBuilder
    private var fallbackParticle: some View {
        let value = emission.reaction.displayValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value == "+" {
            Image(systemName: "heart.fill")
                .font(.system(size: emission.size * 0.78, weight: .semibold))
                .foregroundStyle(.pink)
                .frame(width: emission.size, height: emission.size)
                .background(Color.pink.opacity(0.14), in: Circle())
                .shadow(color: Color.black.opacity(0.14), radius: 6, x: 0, y: 4)
        } else {
            Text(value)
                .font(.system(size: emission.size * 0.92))
                .frame(width: emission.size * 1.1, height: emission.size * 1.1)
                .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 4)
        }
    }
}

private struct LiveReactionFountainModifier: ViewModifier {
    let progress: CGFloat
    let emission: LiveReactionEmission
    let containerSize: CGSize

    func body(content: Content) -> some View {
        let transform = fountainTransform

        content
            .opacity(transform.opacity)
            .scaleEffect(transform.scale)
            .offset(x: transform.x, y: transform.y)
            .rotationEffect(.degrees(transform.rotation))
            .blur(radius: transform.blur)
    }

    private var fountainTransform: (x: CGFloat, y: CGFloat, scale: CGFloat, opacity: Double, rotation: Double, blur: CGFloat) {
        let clampedProgress = min(max(progress, 0), 1)
        let fullWidthScale = max(emission.startScale, containerSize.width / max(emission.size, 1))
        let middleScale = fullWidthScale * emission.middleScaleMultiplier
        let endScale = fullWidthScale * emission.endScaleMultiplier
        let finalFootprint = emission.size * endScale
        let travelDistance = containerSize.height + finalFootprint * 0.6 + 48
        let middleProgress = min(max((containerSize.height * 0.5) / max(travelDistance, 1), 0.18), 0.44)

        let scale: CGFloat
        if clampedProgress <= middleProgress {
            let phaseProgress = clampedProgress / max(middleProgress, 0.001)
            scale = emission.startScale + (middleScale - emission.startScale) * phaseProgress
        } else {
            let phaseProgress = (clampedProgress - middleProgress) / max(1 - middleProgress, 0.001)
            scale = middleScale + (endScale - middleScale) * phaseProgress
        }

        let drift = containerSize.width * emission.horizontalDrift
        let sway = sin(clampedProgress * .pi * 2.6) * containerSize.width * emission.sway
        let fadeOutProgress = max(0, (clampedProgress - 0.88) / 0.12)

        return (
            x: drift * clampedProgress + sway,
            y: -travelDistance * clampedProgress,
            scale: scale,
            opacity: emission.opacity * Double(1 - fadeOutProgress),
            rotation: emission.rotation * Double(clampedProgress),
            blur: clampedProgress > 0.86 ? (clampedProgress - 0.86) * 6 : 0
        )
    }
}
