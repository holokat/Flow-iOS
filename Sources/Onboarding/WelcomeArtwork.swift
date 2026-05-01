import SwiftUI

enum WelcomeArtwork: String, CaseIterable, Identifiable, Hashable, Sendable {
    case cityConversation = "welcome-scene-city"
    case cozyBedroom = "welcome-scene-bedroom"
    case cafeConversation = "welcome-scene-cafe"
    case parkConversation = "welcome-scene-park"
    case terraceConversation = "welcome-scene-terrace"

    static let orderedCycle: [WelcomeArtwork] = [
        .cityConversation,
        .cozyBedroom,
        .cafeConversation,
        .parkConversation,
        .terraceConversation
    ]

    var id: String { rawValue }

    var assetName: String { rawValue }
}

struct WelcomeArtworkSelection: Hashable, Sendable {
    let artwork: WelcomeArtwork
    let primaryColorOption: AppPrimaryColorOption

    static func initial(primaryColorOption: AppPrimaryColorOption = AppPrimaryColorOption.random()) -> WelcomeArtworkSelection {
        WelcomeArtworkSelection(
            artwork: WelcomeArtwork.orderedCycle[0],
            primaryColorOption: primaryColorOption
        )
    }
}

enum WelcomeScratchRevealLayout {
    enum ScratchPhase {
        case activeScratch
        case scratchEnded
    }

    static let completionThreshold: Double = 0.90
    static let brushLineWidth: CGFloat = 82
    static let normalizedBrushRadius: CGFloat = 0.075
    static let coverageGridColumns = 18
    static let coverageGridRows = 30
    static let layerAdvanceDuration: TimeInterval = 0.18

    static func nextArtwork(
        after artwork: WelcomeArtwork,
        in sequence: [WelcomeArtwork] = WelcomeArtwork.orderedCycle
    ) -> WelcomeArtwork {
        guard !sequence.isEmpty else { return artwork }
        guard let currentIndex = sequence.firstIndex(of: artwork) else {
            return sequence[0]
        }
        return sequence[(currentIndex + 1) % sequence.count]
    }

    static func shouldAdvance(coverage: Double, phase: ScratchPhase = .scratchEnded) -> Bool {
        phase == .scratchEnded && coverage >= completionThreshold
    }

    static func normalizedLocation(_ location: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        return CGPoint(
            x: min(max(location.x / size.width, 0), 1),
            y: min(max(location.y / size.height, 0), 1)
        )
    }
}

enum WelcomeScratchHeartBurstTint: CaseIterable, Hashable {
    case coral
    case pink
    case amber
    case mint
    case sky
    case violet

    var color: Color {
        switch self {
        case .coral:
            Color(red: 1.00, green: 0.31, blue: 0.24)
        case .pink:
            Color(red: 1.00, green: 0.20, blue: 0.55)
        case .amber:
            Color(red: 1.00, green: 0.68, blue: 0.15)
        case .mint:
            Color(red: 0.16, green: 0.78, blue: 0.55)
        case .sky:
            Color(red: 0.20, green: 0.62, blue: 1.00)
        case .violet:
            Color(red: 0.62, green: 0.36, blue: 1.00)
        }
    }
}

struct WelcomeScratchHeartBurstParticle: Identifiable, Equatable {
    let id = UUID()
    let symbolName: String
    let tint: WelcomeScratchHeartBurstTint
    let xDrift: CGFloat
    let yTravel: CGFloat
    let sway: CGFloat
    let rotation: Double
    let startScale: CGFloat
    let endScale: CGFloat
    let size: CGFloat
    let duration: Double
    let delay: Double
    let opacity: Double
    let blur: CGFloat
    let bottomLift: CGFloat
}

enum WelcomeScratchHeartBurstLayout {
    static let particleCount = 22
    static let heartSymbolName = "heart.fill"
    static let heartTints: [WelcomeScratchHeartBurstTint] = WelcomeScratchHeartBurstTint.allCases

    static func particles(in viewportSize: CGSize) -> [WelcomeScratchHeartBurstParticle] {
        let width = max(viewportSize.width, 1)
        let height = max(viewportSize.height, 1)
        let count = max(particleCount, 1)

        return (0..<count).map { index in
            let progress = CGFloat(index) / CGFloat(max(count - 1, 1))
            let wave = CGFloat(sin(Double(index) * 1.71))
            let counterWave = CGFloat(cos(Double(index) * 0.83))
            let sideBias: CGFloat = index.isMultiple(of: 2) ? -0.05 : 0.05
            let yTravel = min(
                max(height * (0.51 + counterWave * 0.035), height * 0.44),
                height * 0.58
            )

            return WelcomeScratchHeartBurstParticle(
                symbolName: heartSymbolName,
                tint: heartTints[index % heartTints.count],
                xDrift: width * ((wave * 0.23) + ((progress - 0.5) * 0.1) + sideBias),
                yTravel: yTravel,
                sway: width * CGFloat(sin(Double(index) * 0.47)) * 0.05,
                rotation: Double(sin(Double(index) * 0.69)) * 28,
                startScale: 0.42 + CGFloat(index % 4) * 0.04,
                endScale: 1.02 + CGFloat(index % 5) * 0.09,
                size: 24 + CGFloat(index % 6) * 3,
                duration: 1.15 + Double(index % 7) * 0.055,
                delay: Double(index) * 0.018,
                opacity: 0.78 + Double(index % 5) * 0.035,
                blur: 0.5 + CGFloat(index % 4) * 0.22,
                bottomLift: 38 + CGFloat(index % 5) * 4
            )
        }
    }
}

struct WelcomeScratchProgressGrid: Equatable {
    private let columns: Int
    private let rows: Int
    private var scratchedCellIndexes = Set<Int>()

    init(
        columns: Int = WelcomeScratchRevealLayout.coverageGridColumns,
        rows: Int = WelcomeScratchRevealLayout.coverageGridRows
    ) {
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
    }

    var coverage: Double {
        Double(scratchedCellIndexes.count) / Double(columns * rows)
    }

    mutating func scratch(at normalizedPoint: CGPoint, radius: CGFloat = WelcomeScratchRevealLayout.normalizedBrushRadius) {
        let clampedPoint = CGPoint(
            x: min(max(normalizedPoint.x, 0), 1),
            y: min(max(normalizedPoint.y, 0), 1)
        )
        let clampedRadius = max(radius, 0)

        for row in 0..<rows {
            for column in 0..<columns {
                let cellCenter = CGPoint(
                    x: (CGFloat(column) + 0.5) / CGFloat(columns),
                    y: (CGFloat(row) + 0.5) / CGFloat(rows)
                )
                let deltaX = cellCenter.x - clampedPoint.x
                let deltaY = cellCenter.y - clampedPoint.y
                guard hypot(deltaX, deltaY) <= clampedRadius else { continue }
                scratchedCellIndexes.insert((row * columns) + column)
            }
        }
    }
}

struct WelcomeArtworkBackgroundView: View {
    let artwork: WelcomeArtwork
    var overlayOpacity: Double = 0.22

    var body: some View {
        ZStack {
            Image(artwork.assetName)
                .resizable()
                .scaledToFill()

            LinearGradient(
                colors: [
                    Color.black.opacity(0.08),
                    Color.black.opacity(overlayOpacity * 0.5),
                    Color.black.opacity(overlayOpacity)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct WelcomeScratchRevealBackgroundView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let initialArtwork: WelcomeArtwork
    var overlayOpacity: Double = 0.22

    @State private var currentArtwork: WelcomeArtwork
    @State private var completedStrokeBatches: [[CGPoint]] = []
    @State private var activeStroke: [CGPoint] = []
    @State private var progressGrid = WelcomeScratchProgressGrid()
    @State private var isAdvancingLayer = false
    @State private var heartBurstTrigger = 0

    init(initialArtwork: WelcomeArtwork, overlayOpacity: Double = 0.22) {
        self.initialArtwork = initialArtwork
        self.overlayOpacity = overlayOpacity
        _currentArtwork = State(initialValue: initialArtwork)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                WelcomeArtworkBackgroundView(
                    artwork: nextArtwork,
                    overlayOpacity: overlayOpacity
                )

                WelcomeArtworkBackgroundView(
                    artwork: currentArtwork,
                    overlayOpacity: overlayOpacity
                )
                .mask {
                    WelcomeScratchMask(
                        completedStrokeBatches: completedStrokeBatches,
                        activeStroke: activeStroke,
                        lineWidth: WelcomeScratchRevealLayout.brushLineWidth
                    )
                }

                WelcomeScratchHeartBurstOverlay(
                    trigger: heartBurstTrigger,
                    reduceMotion: reduceMotion
                )
            }
            .contentShape(Rectangle())
            .gesture(scratchGesture(in: geometry.size))
            .onChange(of: initialArtwork) { _, newValue in
                currentArtwork = newValue
                resetScratchState()
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scratchable welcome artwork")
        .accessibilityHint("Drag over the artwork to reveal another scene.")
    }

    private var nextArtwork: WelcomeArtwork {
        WelcomeScratchRevealLayout.nextArtwork(after: currentArtwork)
    }

    private func scratchGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                scratch(at: value.location, in: size)
            }
            .onEnded { value in
                finishScratch(at: value.location, in: size)
            }
    }

    private func scratch(at location: CGPoint, in size: CGSize) {
        guard !isAdvancingLayer else { return }

        let normalizedPoint = WelcomeScratchRevealLayout.normalizedLocation(location, in: size)
        appendScratchPoint(normalizedPoint)
        progressGrid.scratch(at: normalizedPoint)
    }

    private func finishScratch(at location: CGPoint, in size: CGSize) {
        guard !isAdvancingLayer else { return }

        if activeStroke.isEmpty {
            let normalizedPoint = WelcomeScratchRevealLayout.normalizedLocation(location, in: size)
            appendScratchPoint(normalizedPoint)
            progressGrid.scratch(at: normalizedPoint)
        }

        if !activeStroke.isEmpty {
            completedStrokeBatches.append(activeStroke)
            activeStroke = []
        }

        guard WelcomeScratchRevealLayout.shouldAdvance(
            coverage: progressGrid.coverage,
            phase: .scratchEnded
        ) else { return }
        advanceLayer()
    }

    private func appendScratchPoint(_ point: CGPoint) {
        guard activeStroke.last.map({ hypot($0.x - point.x, $0.y - point.y) > 0.004 }) ?? true else {
            return
        }
        activeStroke.append(point)
    }

    private func advanceLayer() {
        isAdvancingLayer = true
        if !reduceMotion {
            heartBurstTrigger += 1
        }

        let applyAdvance = {
            currentArtwork = nextArtwork
            resetScratchState()
            isAdvancingLayer = false
        }

        if reduceMotion {
            applyAdvance()
        } else {
            withAnimation(.easeOut(duration: WelcomeScratchRevealLayout.layerAdvanceDuration)) {
                applyAdvance()
            }
        }
    }

    private func resetScratchState() {
        completedStrokeBatches = []
        activeStroke = []
        progressGrid = WelcomeScratchProgressGrid()
    }
}

private struct WelcomeScratchHeartBurstOverlay: View {
    let trigger: Int
    let reduceMotion: Bool

    @State private var particles: [WelcomeScratchHeartBurstParticle] = []

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                ForEach(particles) { particle in
                    WelcomeScratchHeartParticleView(particle: particle)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
            .onChange(of: trigger) { _, _ in
                emitBurst(in: geometry.size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @MainActor
    private func emitBurst(in size: CGSize) {
        guard !reduceMotion else { return }

        let freshParticles = WelcomeScratchHeartBurstLayout.particles(in: size)
        particles.append(contentsOf: freshParticles)

        for particle in freshParticles {
            Task {
                let lifetime = UInt64((particle.delay + particle.duration + 0.3) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: lifetime)
                await MainActor.run {
                    particles.removeAll { $0.id == particle.id }
                }
            }
        }
    }
}

private struct WelcomeScratchHeartParticleView: View {
    let particle: WelcomeScratchHeartBurstParticle

    @State private var isVisible = false
    @State private var isAnimating = false

    var body: some View {
        Image(systemName: particle.symbolName)
            .font(.system(size: particle.size, weight: .black))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(particle.tint.color)
            .opacity(isVisible ? (isAnimating ? 0 : particle.opacity) : 0)
            .scaleEffect(isAnimating ? particle.endScale : particle.startScale)
            .offset(
                x: isAnimating ? particle.xDrift + particle.sway : 0,
                y: isAnimating ? -(particle.yTravel + particle.bottomLift) : -particle.bottomLift
            )
            .rotationEffect(.degrees(isAnimating ? particle.rotation : particle.rotation * 0.18))
            .blur(radius: isAnimating ? particle.blur : 0)
            .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 5)
            .onAppear {
                Task {
                    if particle.delay > 0 {
                        let delay = UInt64(particle.delay * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    await MainActor.run {
                        isVisible = true
                    }
                    await Task.yield()
                    await MainActor.run {
                        withAnimation(.easeOut(duration: particle.duration)) {
                            isAnimating = true
                        }
                    }
                }
            }
    }
}

private struct WelcomeScratchMask: View {
    let completedStrokeBatches: [[CGPoint]]
    let activeStroke: [CGPoint]
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Color.white

            WelcomeScratchStrokeCanvas(
                completedStrokeBatches: completedStrokeBatches,
                activeStroke: activeStroke,
                lineWidth: lineWidth
            )
            .blendMode(.destinationOut)
        }
        .compositingGroup()
    }
}

private struct WelcomeScratchStrokeCanvas: View {
    let completedStrokeBatches: [[CGPoint]]
    let activeStroke: [CGPoint]
    let lineWidth: CGFloat

    var body: some View {
        Canvas { context, size in
            for stroke in completedStrokeBatches where !stroke.isEmpty {
                context.stroke(
                    path(for: stroke, in: size),
                    with: .color(.black),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            }

            if !activeStroke.isEmpty {
                context.stroke(
                    path(for: activeStroke, in: size),
                    with: .color(.black),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .drawingGroup(opaque: false, colorMode: .linear)
    }

    private func path(for normalizedPoints: [CGPoint], in size: CGSize) -> Path {
        var path = Path()
        guard let firstPoint = normalizedPoints.first else { return path }

        path.move(to: denormalized(firstPoint, in: size))

        if normalizedPoints.count == 1 {
            path.addLine(to: denormalized(firstPoint, in: size))
        } else {
            for point in normalizedPoints.dropFirst() {
                path.addLine(to: denormalized(point, in: size))
            }
        }

        return path
    }

    private func denormalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }
}
