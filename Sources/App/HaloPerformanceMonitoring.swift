import Foundation
import MetricKit
import OSLog
#if canImport(StateReporting)
import StateReporting
#endif

enum HaloPerformanceState: String, Sendable {
    case launching
    case onboarding
    case home
    case homeFeedLoading = "home_feed_loading"
    case search
    case composer
    case publishing
    case haloLink = "halo_link"
    case activity
    case background
}

/// Reports coarse app states only. Never add note text, account identifiers,
/// relay URLs, search terms, or message metadata here.
@MainActor
final class HaloPerformanceMonitor {
    static let shared = HaloPerformanceMonitor()

    private let logger = Logger(
        subsystem: "com.21media.haloapp",
        category: "PerformanceState"
    )
    private let signposter = OSSignposter(
        subsystem: "com.21media.haloapp",
        category: "PerformanceState"
    )
    private var currentSignpost: OSSignpostIntervalState?
    private var currentState: HaloPerformanceState?
    private var lastInteractiveState: HaloPerformanceState?
    private var reporter27: AnyObject?
    private var metricListener27: AnyObject?

    private init() {}

    func start(signedIn: Bool) {
        #if canImport(StateReporting)
        if #available(iOS 27.0, *) {
            if reporter27 == nil {
                reporter27 = HaloStateReporter27()
            }
            if metricListener27 == nil {
                let listener = HaloMetricListener27()
                listener.start()
                metricListener27 = listener
            }
        }
        #endif

        transition(.launching, signedIn: signedIn)
    }

    func transition(_ state: HaloPerformanceState, signedIn: Bool) {
        guard currentState != state else { return }

        if let currentSignpost {
            signposter.endInterval("HaloAppState", currentSignpost)
        }
        currentSignpost = signposter.beginInterval(
            "HaloAppState",
            "state=\(state.rawValue, privacy: .public)"
        )
        currentState = state
        if state != .background {
            lastInteractiveState = state
        }

        logger.debug("App performance state: \(state.rawValue, privacy: .public)")

        #if canImport(StateReporting)
        if #available(iOS 27.0, *),
           let reporter = reporter27 as? HaloStateReporter27 {
            reporter.transition(to: state, signedIn: signedIn)
        }
        #endif
    }

    func sceneDidBecomeActive(signedIn: Bool) {
        let resumedState = signedIn ? (lastInteractiveState ?? .home) : .onboarding
        transition(resumedState, signedIn: signedIn)
    }
}

#if canImport(StateReporting)
@available(iOS 27.0, *)
private struct HaloStateStableMetadata: ReportableMetadata {
    let signedIn: Bool

    var metadataDictionary: [String: ReportableMetadataValue] {
        ["signed_in": ReportableMetadataValue(signedIn)]
    }
}

@available(iOS 27.0, *)
private final class HaloStateReporter27 {
    static let domain = "com.21media.haloapp.user-journey"

    private let reporter = StateReporter<HaloStateStableMetadata, Never>.reporter(
        for: domain,
        stableMetadata: HaloStateStableMetadata.self
    )

    func transition(to state: HaloPerformanceState, signedIn: Bool) {
        reporter.reportTransition(
            to: state.rawValue,
            stableMetadata: HaloStateStableMetadata(signedIn: signedIn)
        )
    }
}

@available(iOS 27.0, *)
private final class HaloMetricListener27 {
    private let logger = Logger(
        subsystem: "com.21media.haloapp",
        category: "MetricKit"
    )
    private let archive = HaloMetricReportArchive27()
    private let manager = MetricManager(
        enabledStateReportingDomains: [
            StateReportingDomain(rawValue: HaloStateReporter27.domain)
        ]
    )
    private var metricTask: Task<Void, Never>?
    private var diagnosticTask: Task<Void, Never>?

    func start() {
        guard metricTask == nil, diagnosticTask == nil else { return }

        metricTask = Task { [manager, archive, logger] in
            for await report in manager.metricReports {
                await archive.store(report)
                logger.info(
                    "Archived MetricKit report with \(report.stateEntries.count, privacy: .public) state entries and \(report.intervalEntries.count, privacy: .public) interval entries"
                )
            }
        }

        diagnosticTask = Task { [manager, archive, logger] in
            for await report in manager.diagnosticReports {
                await archive.store(report)
                logger.info("Archived MetricKit diagnostic report")
            }
        }
    }

    deinit {
        metricTask?.cancel()
        diagnosticTask?.cancel()
    }
}

@available(iOS 27.0, *)
private actor HaloMetricReportArchive27 {
    private enum ReportKind: String {
        case metric
        case diagnostic
    }

    private let fileManager = FileManager.default
    private let maximumReportCountPerKind = 12
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    func store(_ report: MetricReport) {
        do {
            encoder.userInfo[MetricReport.encodingFormatKey] = MetricReport.EncodingFormat.byStateReportingDomain
            try store(encoder.encode(report), kind: .metric)
        } catch {
            Logger(subsystem: "com.21media.haloapp", category: "MetricKit")
                .error("Could not archive MetricKit report: \(error.localizedDescription, privacy: .public)")
        }
    }

    func store(_ report: DiagnosticReport) {
        do {
            try store(encoder.encode(report), kind: .diagnostic)
        } catch {
            Logger(subsystem: "com.21media.haloapp", category: "MetricKit")
                .error("Could not archive MetricKit diagnostic: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func store(_ data: Data, kind: ReportKind) throws {
        let directory = try reportDirectory()
        let timestamp = Int(Date().timeIntervalSince1970)
        let destination = directory.appendingPathComponent(
            "\(kind.rawValue)-\(timestamp)-\(UUID().uuidString).json"
        )
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try pruneReports(in: directory, kind: kind)
    }

    private func reportDirectory() throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent("HaloMetricReports", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
        return directory
    }

    private func pruneReports(in directory: URL, kind: ReportKind) throws {
        let reports = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("\(kind.rawValue)-") }
        .sorted {
            let lhsDate = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let rhsDate = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (lhsDate ?? .distantPast) > (rhsDate ?? .distantPast)
        }

        for report in reports.dropFirst(maximumReportCountPerKind) {
            try fileManager.removeItem(at: report)
        }
    }
}
#endif
