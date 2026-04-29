import Foundation
import Network

struct FlowNetworkPathSnapshot: Equatable, Sendable {
    let isSatisfied: Bool
    let usesWiFi: Bool
}

protocol FlowNetworkPathMonitoring: AnyObject, Sendable {
    var currentPath: FlowNetworkPathSnapshot { get }
    var pathUpdateHandler: (@Sendable (FlowNetworkPathSnapshot) -> Void)? { get set }
    func start(queue: DispatchQueue)
}

final class FlowNetworkPathMonitor: ObservableObject, @unchecked Sendable {
    static let shared = FlowNetworkPathMonitor()

    @Published private(set) var isUsingWiFi = false

    private let pathMonitor: any FlowNetworkPathMonitoring
    private let queue = DispatchQueue(label: "com.21media.haloapp.network-path-monitor")
    private let lock = NSLock()
    private var currentIsUsingWiFi = false

    init(pathMonitor: any FlowNetworkPathMonitoring = NWFlowNetworkPathMonitor()) {
        self.pathMonitor = pathMonitor
        pathMonitor.pathUpdateHandler = { [weak self] snapshot in
            self?.update(snapshot)
        }
        pathMonitor.start(queue: queue)
        update(pathMonitor.currentPath)
    }

    var isCurrentlyUsingWiFi: Bool {
        lock.lock()
        defer { lock.unlock() }
        return currentIsUsingWiFi
    }

    private func update(_ snapshot: FlowNetworkPathSnapshot) {
        let nextIsUsingWiFi = snapshot.isSatisfied && snapshot.usesWiFi

        lock.lock()
        let didChange = currentIsUsingWiFi != nextIsUsingWiFi
        currentIsUsingWiFi = nextIsUsingWiFi
        lock.unlock()

        guard didChange else { return }

        DispatchQueue.main.async { [weak self] in
            self?.isUsingWiFi = nextIsUsingWiFi
        }
    }
}

private final class NWFlowNetworkPathMonitor: FlowNetworkPathMonitoring, @unchecked Sendable {
    private let monitor: NWPathMonitor

    var pathUpdateHandler: (@Sendable (FlowNetworkPathSnapshot) -> Void)?

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            self?.pathUpdateHandler?(Self.snapshot(from: path))
        }
    }

    var currentPath: FlowNetworkPathSnapshot {
        Self.snapshot(from: monitor.currentPath)
    }

    func start(queue: DispatchQueue) {
        monitor.start(queue: queue)
    }

    private static func snapshot(from path: NWPath) -> FlowNetworkPathSnapshot {
        FlowNetworkPathSnapshot(
            isSatisfied: path.status == .satisfied,
            usesWiFi: path.usesInterfaceType(.wifi)
        )
    }
}
