import Combine
import XCTest
@testable import Flow

final class FlowNetworkPathMonitorTests: XCTestCase {
    @MainActor
    func testFakePathUpdateFlipsCurrentWiFiValue() {
        let pathMonitor = FakeFlowNetworkPathMonitoring(
            currentPath: FlowNetworkPathSnapshot(isSatisfied: false, usesWiFi: false)
        )
        let monitor = FlowNetworkPathMonitor(pathMonitor: pathMonitor)

        XCTAssertFalse(monitor.isCurrentlyUsingWiFi)

        pathMonitor.send(FlowNetworkPathSnapshot(isSatisfied: true, usesWiFi: true))

        XCTAssertTrue(monitor.isCurrentlyUsingWiFi)
    }

    @MainActor
    func testFakePathUpdatePublishesWiFiValueOnMainActor() async {
        let pathMonitor = FakeFlowNetworkPathMonitoring(
            currentPath: FlowNetworkPathSnapshot(isSatisfied: false, usesWiFi: false)
        )
        let monitor = FlowNetworkPathMonitor(pathMonitor: pathMonitor)
        let publishedValue = expectation(description: "published Wi-Fi update")
        var receivedValue: Bool?
        var receivedOnMainThread = false
        let cancellable = monitor.$isUsingWiFi
            .dropFirst()
            .sink { value in
                receivedValue = value
                receivedOnMainThread = Thread.isMainThread
                publishedValue.fulfill()
            }

        pathMonitor.send(FlowNetworkPathSnapshot(isSatisfied: true, usesWiFi: true))
        await fulfillment(of: [publishedValue], timeout: 1.0)
        withExtendedLifetime(cancellable) {}

        XCTAssertEqual(receivedValue, true)
        XCTAssertTrue(receivedOnMainThread)
        XCTAssertEqual(receivedValue, monitor.isCurrentlyUsingWiFi)
    }
}

private final class FakeFlowNetworkPathMonitoring: FlowNetworkPathMonitoring, @unchecked Sendable {
    var currentPath: FlowNetworkPathSnapshot
    var pathUpdateHandler: (@Sendable (FlowNetworkPathSnapshot) -> Void)?

    init(currentPath: FlowNetworkPathSnapshot) {
        self.currentPath = currentPath
    }

    func start(queue: DispatchQueue) {}

    func send(_ path: FlowNetworkPathSnapshot) {
        currentPath = path
        pathUpdateHandler?(path)
    }
}
