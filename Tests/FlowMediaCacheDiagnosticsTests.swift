import XCTest
@testable import Flow

final class FlowMediaCacheDiagnosticsTests: XCTestCase {
    func testImageDiagnosticsTrackNetworkThenImageMemoryHit() async {
        let rootDirectoryURL = makeTemporaryDirectory()
        let urlCache = makeURLCache()
        let data = makePNGData()
        let response = makeFetchedResponse(data: data)
        let cache = FlowImageCache(
            rootDirectoryURL: rootDirectoryURL,
            urlCache: urlCache,
            fetchImageData: { _, _ in response }
        )
        let url = URL(string: "https://example.com/photo.png")!

        let firstImage = await cache.image(for: url)
        let secondImage = await cache.image(for: url)
        let snapshot = await cache.diagnosticsSnapshot()

        XCTAssertNotNil(firstImage)
        XCTAssertNotNil(secondImage)
        XCTAssertEqual(snapshot.trackedRequestCount, 2)
        XCTAssertEqual(snapshot.networkFetchCount, 1)
        XCTAssertEqual(snapshot.imageMemoryHitCount, 1)
        XCTAssertEqual(snapshot.cacheHitCount, 1)
        XCTAssertEqual(snapshot.cacheMissCount, 1)
        XCTAssertEqual(snapshot.networkServedByteCount, Int64(data.count))
        XCTAssertEqual(snapshot.cacheServedByteCount, Int64(data.count))
        XCTAssertEqual(snapshot.cacheHitRate, 0.5, accuracy: 0.0001)
    }

    func testDiskHitIsReportedForNewCacheInstanceUsingPersistedMedia() async {
        let rootDirectoryURL = makeTemporaryDirectory()
        let urlCache = makeURLCache()
        let data = makePNGData()
        let url = URL(string: "https://example.com/avatar.jpg")!
        let response = makeFetchedResponse(data: data)

        let warmCache = FlowImageCache(
            rootDirectoryURL: rootDirectoryURL,
            urlCache: urlCache,
            fetchImageData: { _, _ in response }
        )
        _ = await warmCache.data(for: url)

        let diskBackedCache = FlowImageCache(
            rootDirectoryURL: rootDirectoryURL,
            urlCache: urlCache,
            fetchImageData: { _, _ in nil }
        )
        let cachedData = await diskBackedCache.data(for: url)
        let snapshot = await diskBackedCache.diagnosticsSnapshot()

        XCTAssertEqual(cachedData, data)
        XCTAssertEqual(snapshot.trackedRequestCount, 1)
        XCTAssertEqual(snapshot.diskHitCount, 1)
        XCTAssertEqual(snapshot.cacheHitCount, 1)
        XCTAssertEqual(snapshot.networkFetchCount, 0)
        XCTAssertEqual(snapshot.cacheServedByteCount, Int64(data.count))
        XCTAssertEqual(snapshot.cacheHitRate, 1.0, accuracy: 0.0001)
    }

    func testURLCacheHitIsReportedWithoutTouchingNetworkFetcher() async {
        let rootDirectoryURL = makeTemporaryDirectory()
        let urlCache = makeURLCache()
        let data = makePNGData()
        let url = URL(string: "https://example.com/banner.webp")!
        let request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 30
        )
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        )!

        urlCache.storeCachedResponse(
            CachedURLResponse(response: response, data: data),
            for: request
        )

        let cache = FlowImageCache(
            rootDirectoryURL: rootDirectoryURL,
            urlCache: urlCache,
            fetchImageData: { _, _ in nil }
        )

        let cachedData = await cache.data(for: url)
        let snapshot = await cache.diagnosticsSnapshot()

        XCTAssertEqual(cachedData, data)
        XCTAssertEqual(snapshot.trackedRequestCount, 1)
        XCTAssertEqual(snapshot.urlCacheHitCount, 1)
        XCTAssertEqual(snapshot.cacheHitCount, 1)
        XCTAssertEqual(snapshot.networkFetchCount, 0)
        XCTAssertEqual(snapshot.cacheServedByteCount, Int64(data.count))
        XCTAssertEqual(snapshot.cacheHitRate, 1.0, accuracy: 0.0001)
    }

    func testPrefetchWarmsCacheWithoutChangingDiagnosticsUntilTrackedLoad() async {
        let rootDirectoryURL = makeTemporaryDirectory()
        let urlCache = makeURLCache()
        let data = makePNGData()
        let response = makeFetchedResponse(data: data)
        let cache = FlowImageCache(
            rootDirectoryURL: rootDirectoryURL,
            urlCache: urlCache,
            fetchImageData: { _, _ in response }
        )
        let url = URL(string: "https://example.com/prefetch.png")!

        await cache.prefetch(urls: [url])
        let snapshotAfterPrefetch = await cache.diagnosticsSnapshot()
        let image = await cache.image(for: url)
        let snapshotAfterTrackedLoad = await cache.diagnosticsSnapshot()

        XCTAssertEqual(snapshotAfterPrefetch, FlowMediaCacheDiagnostics())
        XCTAssertNotNil(image)
        XCTAssertEqual(snapshotAfterTrackedLoad.trackedRequestCount, 1)
        XCTAssertEqual(snapshotAfterTrackedLoad.dataMemoryHitCount, 1)
        XCTAssertEqual(snapshotAfterTrackedLoad.cacheHitRate, 1.0, accuracy: 0.0001)
    }

    func testGIFURLsDecodeToStaticImages() async {
        let rootDirectoryURL = makeTemporaryDirectory()
        let urlCache = makeURLCache()
        let data = makeGIFData()
        let response = makeFetchedResponse(data: data, contentType: "image/gif")
        let cache = FlowImageCache(
            rootDirectoryURL: rootDirectoryURL,
            urlCache: urlCache,
            fetchImageData: { _, _ in response }
        )
        let url = URL(string: "https://example.com/animated.gif")!

        let image = await cache.image(for: url)

        XCTAssertNotNil(image)
        XCTAssertNil(image?.images)
        XCTAssertGreaterThan(image?.size.width ?? 0, 0)
        XCTAssertGreaterThan(image?.size.height ?? 0, 0)
    }

    func testResetDiagnosticsClearsSessionMetrics() async {
        let rootDirectoryURL = makeTemporaryDirectory()
        let urlCache = makeURLCache()
        let data = makePNGData()
        let response = makeFetchedResponse(data: data)
        let cache = FlowImageCache(
            rootDirectoryURL: rootDirectoryURL,
            urlCache: urlCache,
            fetchImageData: { _, _ in response }
        )
        let url = URL(string: "https://example.com/reset.jpg")!

        _ = await cache.data(for: url)
        let snapshotBeforeReset = await cache.diagnosticsSnapshot()
        await cache.resetDiagnostics()
        let snapshotAfterReset = await cache.diagnosticsSnapshot()

        XCTAssertEqual(snapshotBeforeReset.trackedRequestCount, 1)
        XCTAssertEqual(snapshotBeforeReset.networkFetchCount, 1)
        XCTAssertEqual(snapshotAfterReset, FlowMediaCacheDiagnostics())
    }

    func testInvalidHTMLResponsesAreRejectedAndNegativeCached() async {
        let rootDirectoryURL = makeTemporaryDirectory()
        let urlCache = makeURLCache()
        let url = URL(string: "https://void.cat/bad-image.webp")!
        let invalidResponseData = Data("<!DOCTYPE html><html>nope</html>".utf8)
        let fetchCount = LockedCounter()
        let response = makeFetchedResponse(
            data: invalidResponseData,
            contentType: "text/html"
        )
        let cache = FlowImageCache(
            rootDirectoryURL: rootDirectoryURL,
            urlCache: urlCache,
            fetchImageData: { _, _ in
                await fetchCount.increment()
                return response
            }
        )

        let firstLoad = await cache.data(for: url)
        let secondLoad = await cache.data(for: url)
        let snapshot = await cache.diagnosticsSnapshot()
        let observedFetchCount = await fetchCount.value()

        XCTAssertNil(firstLoad)
        XCTAssertNil(secondLoad)
        XCTAssertEqual(observedFetchCount, 1)
        XCTAssertEqual(snapshot.trackedRequestCount, 2)
        XCTAssertEqual(snapshot.networkFailureCount, 1)
        XCTAssertEqual(snapshot.networkFetchCount, 0)
        XCTAssertEqual(snapshot.cacheHitCount, 0)
    }

    func testProfileImageDataRejectsOversizedResponsesAndBacksOff() async {
        let rootDirectoryURL = makeTemporaryDirectory()
        let urlCache = makeURLCache()
        let url = URL(string: "https://example.com/huge-avatar.png")!
        let oversizedData = makeOversizedPNGData()
        let fetchCount = LockedCounter()
        let response = makeFetchedResponse(data: oversizedData)
        let cache = FlowImageCache(
            rootDirectoryURL: rootDirectoryURL,
            urlCache: urlCache,
            fetchImageData: { _, _ in
                await fetchCount.increment()
                return response
            }
        )

        let firstLoad = await cache.profileImageData(for: url)
        let secondLoad = await cache.profileImageData(for: url)
        let snapshot = await cache.diagnosticsSnapshot()
        let observedFetchCount = await fetchCount.value()

        XCTAssertNil(firstLoad)
        XCTAssertNil(secondLoad)
        XCTAssertEqual(observedFetchCount, 1)
        XCTAssertEqual(snapshot.trackedRequestCount, 2)
        XCTAssertEqual(snapshot.networkFailureCount, 1)
        XCTAssertEqual(snapshot.networkFetchCount, 0)
    }

    func testProfileImageLimitDoesNotBlockStandardImageDataLoads() async {
        let rootDirectoryURL = makeTemporaryDirectory()
        let urlCache = makeURLCache()
        let url = URL(string: "https://example.com/large-note-image.png")!
        let oversizedData = makeOversizedPNGData()
        let response = makeFetchedResponse(data: oversizedData)
        let cache = FlowImageCache(
            rootDirectoryURL: rootDirectoryURL,
            urlCache: urlCache,
            fetchImageData: { _, _ in response }
        )

        let profileLoad = await cache.profileImageData(for: url)
        let standardLoad = await cache.data(for: url)

        XCTAssertNil(profileLoad)
        XCTAssertEqual(standardLoad, oversizedData)
    }

    func testFeedThumbnailLimitRejectsOversizedResponsesAndBacksOff() async {
        let rootDirectoryURL = makeTemporaryDirectory()
        let urlCache = makeURLCache()
        let url = URL(string: "https://example.com/huge-feed-image.png")!
        let oversizedData = makeOversizedPNGData(extraBytes: 3 * 1_024 * 1_024)
        let fetchCount = LockedCounter()
        let response = makeFetchedResponse(data: oversizedData)
        let cache = FlowImageCache(
            rootDirectoryURL: rootDirectoryURL,
            urlCache: urlCache,
            fetchImageData: { _, _ in
                await fetchCount.increment()
                return response
            }
        )

        let firstLoad = await cache.data(for: url, kind: .feedThumbnail)
        let secondLoad = await cache.data(for: url, kind: .feedThumbnail)
        let snapshot = await cache.diagnosticsSnapshot()
        let observedFetchCount = await fetchCount.value()

        XCTAssertNil(firstLoad)
        XCTAssertNil(secondLoad)
        XCTAssertEqual(observedFetchCount, 1)
        XCTAssertEqual(snapshot.trackedRequestCount, 2)
        XCTAssertEqual(snapshot.networkFailureCount, 1)
        XCTAssertEqual(snapshot.networkFetchCount, 0)
    }

    func testFeedThumbnailLimitIsIgnoredOnWiFi() async {
        let rootDirectoryURL = makeTemporaryDirectory()
        let urlCache = makeURLCache()
        let url = URL(string: "https://example.com/huge-wifi-feed-image.png")!
        let oversizedData = makeOversizedPNGData(extraBytes: 3 * 1_024 * 1_024)
        let observedMaxByteCount = LockedOptionalInt()
        let response = makeFetchedResponse(data: oversizedData)
        let cache = FlowImageCache(
            rootDirectoryURL: rootDirectoryURL,
            urlCache: urlCache,
            fetchImageData: { _, maxByteCount in
                await observedMaxByteCount.set(maxByteCount)
                return response
            },
            isUsingWiFiConnection: { true }
        )

        let load = await cache.data(for: url, kind: .feedThumbnail)
        let maxByteCount = await observedMaxByteCount.value()

        XCTAssertEqual(load, oversizedData)
        XCTAssertNil(maxByteCount)
    }

    func testProfileImageLimitIsIgnoredOnWiFi() async {
        let rootDirectoryURL = makeTemporaryDirectory()
        let urlCache = makeURLCache()
        let url = URL(string: "https://example.com/huge-wifi-avatar.png")!
        let oversizedData = makeOversizedPNGData()
        let observedMaxByteCount = LockedOptionalInt()
        let response = makeFetchedResponse(data: oversizedData)
        let cache = FlowImageCache(
            rootDirectoryURL: rootDirectoryURL,
            urlCache: urlCache,
            fetchImageData: { _, maxByteCount in
                await observedMaxByteCount.set(maxByteCount)
                return response
            },
            isUsingWiFiConnection: { true }
        )

        let load = await cache.profileImageData(for: url)
        let maxByteCount = await observedMaxByteCount.value()

        XCTAssertEqual(load, oversizedData)
        XCTAssertNil(maxByteCount)
    }

    func testProfileImageLimitStillAppliesOffWiFi() async {
        let rootDirectoryURL = makeTemporaryDirectory()
        let urlCache = makeURLCache()
        let url = URL(string: "https://example.com/huge-cellular-avatar.png")!
        let oversizedData = makeOversizedPNGData()
        let response = makeFetchedResponse(data: oversizedData)
        let cache = FlowImageCache(
            rootDirectoryURL: rootDirectoryURL,
            urlCache: urlCache,
            fetchImageData: { _, _ in response },
            isUsingWiFiConnection: { false }
        )

        let load = await cache.profileImageData(for: url)

        XCTAssertNil(load)
    }

    func testFeedThumbnailLimitCanBeBypassedForExplicitLoad() async {
        let rootDirectoryURL = makeTemporaryDirectory()
        let urlCache = makeURLCache()
        let url = URL(string: "https://example.com/tap-to-load-image.png")!
        let oversizedData = makeOversizedPNGData(extraBytes: 3 * 1_024 * 1_024)
        let fetchCount = LockedCounter()
        let response = makeFetchedResponse(data: oversizedData)
        let cache = FlowImageCache(
            rootDirectoryURL: rootDirectoryURL,
            urlCache: urlCache,
            fetchImageData: { _, _ in
                await fetchCount.increment()
                return response
            }
        )

        let cappedLoad = await cache.data(for: url, kind: .feedThumbnail)
        let explicitLoad = await cache.data(
            for: url,
            kind: .feedThumbnail,
            enforceNetworkByteLimit: false
        )
        let observedFetchCount = await fetchCount.value()

        XCTAssertNil(cappedLoad)
        XCTAssertEqual(explicitLoad, oversizedData)
        XCTAssertEqual(observedFetchCount, 2)
    }

    func testProfileImageLimitAllowsAlreadyCachedOversizedData() async {
        let rootDirectoryURL = makeTemporaryDirectory()
        let urlCache = makeURLCache()
        let url = URL(string: "https://example.com/cached-avatar.png")!
        let oversizedData = makeOversizedPNGData()
        let fetchCount = LockedCounter()
        let response = makeFetchedResponse(data: oversizedData)
        let cache = FlowImageCache(
            rootDirectoryURL: rootDirectoryURL,
            urlCache: urlCache,
            fetchImageData: { _, _ in
                await fetchCount.increment()
                return response
            }
        )

        let standardLoad = await cache.data(for: url)
        let profileLoad = await cache.profileImageData(for: url)
        let observedFetchCount = await fetchCount.value()

        XCTAssertEqual(standardLoad, oversizedData)
        XCTAssertEqual(profileLoad, oversizedData)
        XCTAssertEqual(observedFetchCount, 1)
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeURLCache() -> URLCache {
        URLCache(
            memoryCapacity: 2 * 1_024 * 1_024,
            diskCapacity: 2 * 1_024 * 1_024,
            diskPath: nil
        )
    }

    private func makePNGData() -> Data {
        Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAAaADAAQAAAABAAAAAQAAAAD5Ip3+AAAADElEQVQIHWNg+P8fAAMBAf8kN8l+AAAAAElFTkSuQmCC"
        ) ?? Data([0x89, 0x50, 0x4E, 0x47])
    }

    private func makeGIFData() -> Data {
        Data(
            base64Encoded: "R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="
        ) ?? Data([0x47, 0x49, 0x46])
    }

    private func makeOversizedPNGData(extraBytes: Int = 2 * 1_024 * 1_024) -> Data {
        var data = makePNGData()
        data.append(Data(repeating: 0, count: extraBytes))
        return data
    }

    private func makeFetchedResponse(
        data: Data,
        statusCode: Int = 200,
        contentType: String = "image/png"
    ) -> FlowMediaFetchedResponse {
        FlowMediaFetchedResponse(
            data: data,
            statusCode: statusCode,
            contentType: contentType
        )
    }
}

private actor LockedCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

private actor LockedOptionalInt {
    private var storedValue: Int?

    func set(_ value: Int?) {
        storedValue = value
    }

    func value() -> Int? {
        storedValue
    }
}
