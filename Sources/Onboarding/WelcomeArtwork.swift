import SwiftUI

enum WelcomeArtwork: String, CaseIterable, Identifiable, Hashable, Sendable {
    case cityConversation = "welcome-scene-city"
    case cozyBedroom = "welcome-scene-bedroom"
    case cafeConversation = "welcome-scene-cafe"

    static let orderedCycle: [WelcomeArtwork] = [
        .cityConversation,
        .cozyBedroom,
        .cafeConversation
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

    static let completionThreshold: Double = 0.99
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
