import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UIKit

enum FlowMediaCache {
    static let sharedURLCacheMemoryCapacity = 64 * 1_024 * 1_024
    static let sharedURLCacheDiskCapacity = 256 * 1_024 * 1_024
    static let sharedURLCacheDirectory = "flow-url-cache"

    static func configureSharedURLCache() {
        let current = URLCache.shared
        if current.memoryCapacity >= sharedURLCacheMemoryCapacity,
           current.diskCapacity >= sharedURLCacheDiskCapacity {
            return
        }

        URLCache.shared = URLCache(
            memoryCapacity: sharedURLCacheMemoryCapacity,
            diskCapacity: sharedURLCacheDiskCapacity,
            diskPath: sharedURLCacheDirectory
        )
    }
}

struct FlowMediaCacheDiagnostics: Equatable, Sendable {
    var trackedRequestCount = 0
    var imageMemoryHitCount = 0
    var dataMemoryHitCount = 0
    var diskHitCount = 0
    var urlCacheHitCount = 0
    var networkFetchCount = 0
    var networkFailureCount = 0
    var cacheServedByteCount: Int64 = 0
    var networkServedByteCount: Int64 = 0

    var cacheHitCount: Int {
        imageMemoryHitCount + dataMemoryHitCount + diskHitCount + urlCacheHitCount
    }

    var cacheMissCount: Int {
        max(0, trackedRequestCount - cacheHitCount)
    }

    var cacheHitRate: Double {
        guard trackedRequestCount > 0 else { return 0 }
        return Double(cacheHitCount) / Double(trackedRequestCount)
    }
}

private enum FlowMediaCacheDiagnosticsTracking {
    case tracked
    case untracked

    var shouldRecord: Bool {
        self == .tracked
    }
}

private enum FlowMediaCacheHitSource {
    case imageMemory
    case dataMemory
    case disk
    case urlCache
}

struct FlowMediaFetchedResponse: Sendable {
    let data: Data
    let statusCode: Int?
    let contentType: String?
    var exceededByteLimit = false
}

enum FlowImageCacheRequestKind: Hashable, Sendable {
    case standard
    case profileImage
    case avatar
    case profileImageFullscreen
    case profileBanner
    case feedThumbnail
    case fullscreen

    static let profileImageByteLimit = 2 * 1_024 * 1_024
    static let profileImageWiFiByteLimit = 4 * 1_024 * 1_024
    static let feedImageByteLimit = 3 * 1_024 * 1_024
    static let largeGIFAutoplayByteLimit = 2 * 1_024 * 1_024

    var decodeMaxPixelSize: CGFloat {
        switch self {
        case .avatar, .profileImage:
            return 256
        case .profileImageFullscreen:
            return 2_048
        case .profileBanner:
            return 1_600
        case .feedThumbnail:
            return 1_200
        case .standard, .fullscreen:
            return 2_048
        }
    }

    func maxByteCount(enforcingNetworkLimit: Bool, usingWiFi: Bool = false) -> Int? {
        guard enforcingNetworkLimit else { return nil }

        switch self {
        case .standard:
            return nil
        case .profileImage, .avatar, .profileImageFullscreen:
            return usingWiFi ? Self.profileImageWiFiByteLimit : Self.profileImageByteLimit
        case .profileBanner, .feedThumbnail:
            return Self.feedImageByteLimit
        case .fullscreen:
            return nil
        }
    }
}

final class FlowMediaAspectRatioCache {
    static let shared = FlowMediaAspectRatioCache()

    private static let storageKey = "flow.mediaAspectRatios.v1"
    private static let maxPersistedRatios = 2_048

    private let cache = NSCache<NSString, NSNumber>()
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var persistedRatios: [String: Double]

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.persistedRatios = Self.loadPersistedRatios(from: defaults)
        cache.countLimit = 512
    }

    func ratio(for url: URL) -> CGFloat? {
        let key = Self.cacheKey(for: url)
        if let cached = cache.object(forKey: key as NSString) {
            let ratio = CGFloat(truncating: cached)
            guard ratio.isFinite, ratio > 0 else { return nil }
            return ratio
        }

        lock.lock()
        let persisted = persistedRatios[key]
        lock.unlock()

        guard let persisted, persisted.isFinite, persisted > 0 else { return nil }
        let ratio = CGFloat(persisted)
        cache.setObject(NSNumber(value: persisted), forKey: key as NSString)
        return ratio
    }

    func insert(_ ratio: CGFloat, for url: URL) {
        insert(ratio, forKey: Self.cacheKey(for: url))
    }

    func insert(_ ratio: CGFloat, forURLString urlString: String) {
        let key = Self.cacheKey(forURLString: urlString)
        guard !key.isEmpty else { return }
        insert(ratio, forKey: key)
    }

    private func insert(_ ratio: CGFloat, forKey key: String) {
        guard ratio.isFinite, ratio > 0 else { return }
        let normalizedRatio = min(max(Double(ratio), 0.28), 3.2)
        cache.setObject(NSNumber(value: normalizedRatio), forKey: key as NSString)

        lock.lock()
        persistedRatios[key] = normalizedRatio
        trimPersistedRatiosIfNeeded()
        let snapshot = persistedRatios
        lock.unlock()

        defaults.set(snapshot, forKey: Self.storageKey)
    }

    private func trimPersistedRatiosIfNeeded() {
        let overflow = persistedRatios.count - Self.maxPersistedRatios
        guard overflow > 0 else { return }

        for key in persistedRatios.keys.sorted().prefix(overflow) {
            persistedRatios.removeValue(forKey: key)
        }
    }

    private static func loadPersistedRatios(from defaults: UserDefaults) -> [String: Double] {
        guard let rawValues = defaults.dictionary(forKey: storageKey) else { return [:] }

        var ratios: [String: Double] = [:]
        for (key, value) in rawValues {
            let ratio: Double?
            switch value {
            case let number as NSNumber:
                ratio = number.doubleValue
            case let double as Double:
                ratio = double
            default:
                ratio = nil
            }

            guard let ratio, ratio.isFinite, ratio > 0 else { continue }
            ratios[key] = min(max(ratio, 0.28), 3.2)
        }
        return ratios
    }

    private static func cacheKey(for url: URL) -> String {
        cacheKey(forURLString: url.absoluteString)
    }

    private static func cacheKey(forURLString urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        guard var components = URLComponents(string: trimmed) else {
            return trimmed
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.url?.absoluteString ?? trimmed
    }
}

private actor FlowMediaFailureBackoff {
    private struct Entry {
        var failureCount: Int
        var retryAfter: Date
    }

    private let aggressiveHosts: Set<String>
    private let maxURLEntries = 512
    private let maxHostEntries = 128
    private var urlFailures: [String: Entry] = [:]
    private var urlOrder: [String] = []
    private var hostFailures: [String: Entry] = [:]
    private var hostOrder: [String] = []

    init(aggressiveHosts: Set<String> = ["blossom.lostr.space", "void.cat"]) {
        self.aggressiveHosts = aggressiveHosts
    }

    func canAttempt(_ url: URL, now: Date = Date()) -> Bool {
        if let entry = urlFailures[urlKey(for: url)], entry.retryAfter > now {
            return false
        }
        if let host = hostKey(for: url),
           let entry = hostFailures[host],
           entry.retryAfter > now {
            return false
        }
        clearExpiredEntries(now: now)
        return true
    }

    func recordSuccess(for url: URL) {
        removeURLFailure(for: url)
        removeHostFailure(for: url)
    }

    func recordTransportFailure(for url: URL) {
        let baseDelay: TimeInterval = aggressiveHosts.contains(hostKey(for: url) ?? "") ? 60 : 20
        recordURLFailure(for: url, baseDelay: baseDelay, maxDelay: 15 * 60)
        recordHostFailure(for: url, baseDelay: baseDelay, maxDelay: 10 * 60)
    }

    func recordInvalidResponse(for url: URL) {
        recordURLFailure(for: url, baseDelay: 10 * 60, maxDelay: 60 * 60)
    }

    private func recordURLFailure(for url: URL, baseDelay: TimeInterval, maxDelay: TimeInterval) {
        let key = urlKey(for: url)
        let nextEntry = advancedEntry(current: urlFailures[key], baseDelay: baseDelay, maxDelay: maxDelay)
        urlFailures[key] = nextEntry
        if !urlOrder.contains(key) {
            urlOrder.append(key)
        }
        trimURLFailuresIfNeeded()
    }

    private func recordHostFailure(for url: URL, baseDelay: TimeInterval, maxDelay: TimeInterval) {
        guard let key = hostKey(for: url) else { return }
        let nextEntry = advancedEntry(current: hostFailures[key], baseDelay: baseDelay, maxDelay: maxDelay)
        hostFailures[key] = nextEntry
        if !hostOrder.contains(key) {
            hostOrder.append(key)
        }
        trimHostFailuresIfNeeded()
    }

    private func removeURLFailure(for url: URL) {
        let key = urlKey(for: url)
        urlFailures.removeValue(forKey: key)
        urlOrder.removeAll { $0 == key }
    }

    private func removeHostFailure(for url: URL) {
        guard let key = hostKey(for: url) else { return }
        hostFailures.removeValue(forKey: key)
        hostOrder.removeAll { $0 == key }
    }

    private func clearExpiredEntries(now: Date) {
        let expiredURLs = urlFailures.compactMap { key, entry in
            entry.retryAfter <= now ? key : nil
        }
        for key in expiredURLs {
            urlFailures.removeValue(forKey: key)
        }
        if !expiredURLs.isEmpty {
            let expiredSet = Set(expiredURLs)
            urlOrder.removeAll { expiredSet.contains($0) }
        }

        let expiredHosts = hostFailures.compactMap { key, entry in
            entry.retryAfter <= now ? key : nil
        }
        for key in expiredHosts {
            hostFailures.removeValue(forKey: key)
        }
        if !expiredHosts.isEmpty {
            let expiredSet = Set(expiredHosts)
            hostOrder.removeAll { expiredSet.contains($0) }
        }
    }

    private func trimURLFailuresIfNeeded() {
        while urlOrder.count > maxURLEntries {
            let removedKey = urlOrder.removeFirst()
            urlFailures.removeValue(forKey: removedKey)
        }
    }

    private func trimHostFailuresIfNeeded() {
        while hostOrder.count > maxHostEntries {
            let removedKey = hostOrder.removeFirst()
            hostFailures.removeValue(forKey: removedKey)
        }
    }

    private func advancedEntry(
        current: Entry?,
        baseDelay: TimeInterval,
        maxDelay: TimeInterval
    ) -> Entry {
        let nextFailureCount = (current?.failureCount ?? 0) + 1
        let multiplier = pow(2.0, Double(min(nextFailureCount - 1, 5)))
        let delay = min(baseDelay * multiplier, maxDelay)
        return Entry(
            failureCount: nextFailureCount,
            retryAfter: Date().addingTimeInterval(delay)
        )
    }

    private func urlKey(for url: URL) -> String {
        url.absoluteString.lowercased()
    }

    private func hostKey(for url: URL) -> String? {
        url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

actor FlowImageCache {
    static let shared = FlowImageCache(
        isUsingWiFiConnection: {
            FlowNetworkPathMonitor.shared.isCurrentlyUsingWiFi
        }
    )
    typealias ImageDataFetcher = @Sendable (URLRequest, Int?) async -> FlowMediaFetchedResponse?
    private static let maxSourceImagePixelCount: CGFloat = 48_000_000
    private static let liveImageDataFetcher: ImageDataFetcher = { request, maxByteCount in
        await fetchImageResponse(with: request, maxByteCount: maxByteCount)
    }

    private struct FetchKey: Hashable {
        let url: URL
        let maxByteCount: Int?
    }

    private struct ImagePixelSize {
        var width: CGFloat
        var height: CGFloat

        var pixelCount: CGFloat {
            width * height
        }
    }

    private let fileManager: FileManager
    private let directoryURL: URL
    private let urlCache: URLCache
    private let fetchImageData: ImageDataFetcher
    private let isUsingWiFiConnection: @Sendable () -> Bool
    private let failureBackoff: FlowMediaFailureBackoff
    private let memoryCache = NSCache<NSString, UIImage>()
    private let dataCache = NSCache<NSURL, NSData>()
    private let encodedByteCounts = NSCache<NSURL, NSNumber>()
    private let maxDiskBytes: Int64 = 384 * 1_024 * 1_024
    private let maxDiskEntries = 12_000
    private let maxEntryAge: TimeInterval = 60 * 60 * 24 * 30
    private let oversizedMediaBackoff: TimeInterval = 60 * 60
    private var inFlight: [FetchKey: Task<FlowMediaFetchedResponse?, Never>] = [:]
    private var oversizedMediaRetryAfter: [FetchKey: Date] = [:]
    private var diagnostics = FlowMediaCacheDiagnostics()

    init(
        fileManager: FileManager = .default,
        rootDirectoryURL: URL? = nil,
        urlCache: URLCache = .shared,
        fetchImageData: @escaping ImageDataFetcher = FlowImageCache.liveImageDataFetcher
    ) {
        self.init(
            fileManager: fileManager,
            rootDirectoryURL: rootDirectoryURL,
            urlCache: urlCache,
            fetchImageData: fetchImageData,
            isUsingWiFiConnection: { false }
        )
    }

    init(
        fileManager: FileManager = .default,
        rootDirectoryURL: URL? = nil,
        urlCache: URLCache = .shared,
        fetchImageData: @escaping ImageDataFetcher = FlowImageCache.liveImageDataFetcher,
        isUsingWiFiConnection: @escaping @Sendable () -> Bool
    ) {
        self.fileManager = fileManager
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directoryURL = rootDirectoryURL
            ?? root.appendingPathComponent("flow-media-cache", isDirectory: true)
        self.urlCache = urlCache
        self.fetchImageData = fetchImageData
        self.isUsingWiFiConnection = isUsingWiFiConnection
        self.failureBackoff = FlowMediaFailureBackoff()
        memoryCache.totalCostLimit = (FlowMediaCache.sharedURLCacheMemoryCapacity * 3) / 4
        dataCache.totalCostLimit = FlowMediaCache.sharedURLCacheMemoryCapacity / 4
    }

    func image(for url: URL) async -> UIImage? {
        await image(
            for: url,
            kind: .standard,
            enforceNetworkByteLimit: true,
            tracking: .tracked
        )
    }

    func image(
        for url: URL,
        kind: FlowImageCacheRequestKind,
        enforceNetworkByteLimit: Bool = true
    ) async -> UIImage? {
        await image(
            for: url,
            kind: kind,
            enforceNetworkByteLimit: enforceNetworkByteLimit,
            tracking: .tracked
        )
    }

    func profileImage(for url: URL) async -> UIImage? {
        await image(
            for: url,
            kind: .profileImage,
            enforceNetworkByteLimit: true,
            tracking: .tracked
        )
    }

    func aspectRatio(for url: URL, enforceNetworkByteLimit: Bool = true) async -> CGFloat? {
        if let cachedRatio = FlowMediaAspectRatioCache.shared.ratio(for: url) {
            return cachedRatio
        }

        guard let data = await data(
            for: url,
            kind: .feedThumbnail,
            enforceNetworkByteLimit: enforceNetworkByteLimit,
            tracking: .untracked,
            countsAsRequest: false
        ),
              let ratio = Self.imageAspectRatio(from: data) else {
            return nil
        }

        FlowMediaAspectRatioCache.shared.insert(ratio, for: url)
        return ratio
    }

    func data(for url: URL) async -> Data? {
        await data(
            for: url,
            kind: .standard,
            enforceNetworkByteLimit: true,
            tracking: .tracked,
            countsAsRequest: true
        )
    }

    func data(
        for url: URL,
        kind: FlowImageCacheRequestKind,
        enforceNetworkByteLimit: Bool = true
    ) async -> Data? {
        await data(
            for: url,
            kind: kind,
            enforceNetworkByteLimit: enforceNetworkByteLimit,
            tracking: .tracked,
            countsAsRequest: true
        )
    }

    func profileImageData(for url: URL) async -> Data? {
        await data(
            for: url,
            kind: .profileImage,
            enforceNetworkByteLimit: true,
            tracking: .tracked,
            countsAsRequest: true
        )
    }

    func diagnosticsSnapshot() -> FlowMediaCacheDiagnostics {
        diagnostics
    }

    func resetDiagnostics() {
        diagnostics = FlowMediaCacheDiagnostics()
    }

    private func image(
        for url: URL,
        kind: FlowImageCacheRequestKind,
        enforceNetworkByteLimit: Bool,
        tracking: FlowMediaCacheDiagnosticsTracking
    ) async -> UIImage? {
        guard isCacheable(url) else { return nil }

        let dataCacheKey = url as NSURL
        let cacheKey = imageCacheKey(for: url, kind: kind)
        recordRequestIfNeeded(tracking)
        if let cached = memoryCache.object(forKey: cacheKey) {
            if FlowMediaAspectRatioCache.shared.ratio(for: url) == nil,
               let ratio = Self.aspectRatio(for: cached) {
                FlowMediaAspectRatioCache.shared.insert(ratio, for: url)
            }
            recordCacheHit(
                .imageMemory,
                byteCount: encodedByteCount(for: dataCacheKey),
                tracking: tracking
            )
            return cached
        }

        if Self.isLikelyVideoURL(url),
           let thumbnail = await videoThumbnail(for: url) {
            memoryCache.setObject(thumbnail, forKey: cacheKey, cost: memoryCost(for: thumbnail))
            return thumbnail
        }

        guard let data = await data(
            for: url,
            kind: kind,
            enforceNetworkByteLimit: enforceNetworkByteLimit,
            tracking: tracking,
            countsAsRequest: false
        ),
              let image = preparedImage(
                from: data,
                sourceURL: url,
                maxPixelSize: kind.decodeMaxPixelSize
              ) else {
            return nil
        }

        if let ratio = Self.imageAspectRatio(from: data) ?? Self.aspectRatio(for: image) {
            FlowMediaAspectRatioCache.shared.insert(ratio, for: url)
        }
        memoryCache.setObject(image, forKey: cacheKey, cost: memoryCost(for: image))
        return image
    }

    private func data(
        for url: URL,
        kind: FlowImageCacheRequestKind,
        enforceNetworkByteLimit: Bool,
        tracking: FlowMediaCacheDiagnosticsTracking,
        countsAsRequest: Bool
    ) async -> Data? {
        guard isCacheable(url) else { return nil }

        if countsAsRequest {
            recordRequestIfNeeded(tracking)
        }

        let cacheKey = url as NSURL
        if let cachedData = dataCache.object(forKey: cacheKey) {
            let data = cachedData as Data
            storeEncodedByteCount(data.count, for: cacheKey)
            recordCacheHit(.dataMemory, byteCount: data.count, tracking: tracking)
            return data
        }

        if let diskData = loadDataFromDisk(for: url, cacheKey: cacheKey) {
            recordCacheHit(.disk, byteCount: diskData.count, tracking: tracking)
            return diskData
        }

        let request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 30
        )

        if let cachedResponse = urlCache.cachedResponse(for: request) {
            if let validatedCachedData = await validatedData(
                from: Self.makeFetchedResponse(
                    data: cachedResponse.data,
                    response: cachedResponse.response
                ),
                for: url,
                maxByteCount: nil
            ) {
                recordCacheHit(.urlCache, byteCount: validatedCachedData.count, tracking: tracking)
                return storeData(
                    data: validatedCachedData,
                    for: url,
                    cacheKey: cacheKey,
                    persistToDisk: true
                )
            }
            urlCache.removeCachedResponse(for: request)
        }

        guard await failureBackoff.canAttempt(url) else {
            return nil
        }
        let usingWiFi = isUsingWiFiConnection()
        let maxByteCount = kind.maxByteCount(
            enforcingNetworkLimit: shouldEnforceNetworkByteLimit(
                kind: kind,
                requested: enforceNetworkByteLimit,
                usingWiFi: usingWiFi
            ),
            usingWiFi: usingWiFi
        )
        guard canAttemptSizeLimitedRequest(for: url, maxByteCount: maxByteCount) else {
            return nil
        }

        let fetchKey = FetchKey(url: url, maxByteCount: maxByteCount)
        if let existingTask = inFlight[fetchKey] {
            let response = await existingTask.value
            let data = await validatedData(from: response, for: url, maxByteCount: maxByteCount)
            return storeData(data: data, for: url, cacheKey: cacheKey, persistToDisk: true)
        }

        let fetchImageData = self.fetchImageData
        let task = Task {
            await fetchImageData(request, maxByteCount)
        }
        inFlight[fetchKey] = task

        let response = await task.value
        inFlight[fetchKey] = nil
        let data = await validatedData(from: response, for: url, maxByteCount: maxByteCount)
        recordNetworkResult(data, tracking: tracking)
        return storeData(data: data, for: url, cacheKey: cacheKey, persistToDisk: true)
    }

    private func shouldEnforceNetworkByteLimit(
        kind: FlowImageCacheRequestKind,
        requested: Bool,
        usingWiFi: Bool
    ) -> Bool {
        guard requested else { return false }
        guard kind == .feedThumbnail else { return true }
        return !usingWiFi
    }

    func prefetch(urls: [URL]) async {
        let deduplicated = deduplicatedURLs(from: urls)
        guard !deduplicated.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            for url in deduplicated.prefix(36) {
                group.addTask {
                    _ = await self.image(
                        for: url,
                        kind: .feedThumbnail,
                        enforceNetworkByteLimit: true,
                        tracking: .untracked
                    )
                }
            }
            await group.waitForAll()
        }
    }

    func totalCacheSizeBytes() -> Int64 {
        localDiskUsageBytes() + Int64(urlCache.currentDiskUsage)
    }

    func clearAllCachedImages() async {
        memoryCache.removeAllObjects()
        dataCache.removeAllObjects()
        encodedByteCounts.removeAllObjects()
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
        urlCache.removeAllCachedResponses()

        if fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.removeItem(at: directoryURL)
        }
        ensureDirectory()
    }

    private func isCacheable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func loadDataFromDisk(for url: URL, cacheKey: NSURL) -> Data? {
        ensureDirectory()
        let fileURL = diskFileURL(for: url)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }

        let modificationDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
        if Date().timeIntervalSince(modificationDate) > maxEntryAge {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }

        guard Self.isLikelyRenderableImageData(data, contentType: nil) else {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }

        storeEncodedByteCount(data.count, for: cacheKey)
        dataCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        return data
    }

    private func storeData(
        data: Data?,
        for url: URL,
        cacheKey: NSURL,
        persistToDisk: Bool
    ) -> Data? {
        guard let data else { return nil }

        storeEncodedByteCount(data.count, for: cacheKey)
        dataCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
        if persistToDisk {
            persistImageData(data, for: url)
        }
        return data
    }

    private func persistImageData(_ data: Data, for url: URL) {
        ensureDirectory()
        let fileURL = diskFileURL(for: url)
        try? data.write(to: fileURL, options: .atomic)
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
        pruneDiskIfNeeded()
    }

    private func ensureDirectory() {
        if fileManager.fileExists(atPath: directoryURL.path) {
            return
        }

        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func diskFileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hashed = digest.map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension.lowercased()
        return directoryURL.appendingPathComponent("\(hashed).\(ext)", isDirectory: false)
    }

    private func deduplicatedURLs(from urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []

        for url in urls where isCacheable(url) {
            let normalized = url.absoluteString.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            ordered.append(url)
        }

        return ordered
    }

    private func localDiskUsageBytes() -> Int64 {
        ensureDirectory()
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(fileSize)
        }
        return total
    }

    private func pruneDiskIfNeeded() {
        ensureDirectory()
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var totalBytes: Int64 = 0
        let sortedFiles = files.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return lhsDate > rhsDate
        }

        for fileURL in sortedFiles {
            let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            totalBytes += Int64(fileSize)
        }

        if sortedFiles.count <= maxDiskEntries, totalBytes <= maxDiskBytes {
            return
        }

        var retainedCount = 0
        var retainedBytes: Int64 = 0
        for fileURL in sortedFiles {
            let fileSize = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let shouldRetain = retainedCount < maxDiskEntries && retainedBytes + fileSize <= maxDiskBytes
            if shouldRetain {
                retainedCount += 1
                retainedBytes += fileSize
            } else {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    private func memoryCost(for image: UIImage) -> Int {
        let scale = image.scale
        let width = Int(image.size.width * scale)
        let height = Int(image.size.height * scale)
        guard width > 0, height > 0 else { return 1 }
        return width * height * 4
    }

    private func imageCacheKey(for url: URL, kind: FlowImageCacheRequestKind) -> NSString {
        "\(url.absoluteString)#px:\(Int(kind.decodeMaxPixelSize.rounded()))" as NSString
    }

    private func preparedImage(
        from data: Data,
        sourceURL: URL,
        maxPixelSize: CGFloat
    ) -> UIImage? {
        guard Self.isLikelyRenderableImageData(data, contentType: nil) else {
            return nil
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            guard let image = UIImage(data: data) else { return nil }
            return image.preparingForDisplay() ?? image
        }

        if let pixelSize = Self.imagePixelSize(from: source),
           pixelSize.pixelCount > Self.maxSourceImagePixelCount {
            return nil
        }

        let frameCount = CGImageSourceGetCount(source)
        let isGIF = sourceURL.pathExtension.lowercased() == "gif" || data.starts(with: [0x47, 0x49, 0x46])
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: max(Int(maxPixelSize.rounded()), 1)
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let image = UIImage(cgImage: cgImage)
        if isGIF || frameCount > 1 {
            return image
        }

        return image.preparingForDisplay() ?? image
    }

    private func videoThumbnail(for url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 768, height: 768)

            let time = CMTime(seconds: 0.15, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else {
                return nil
            }

            let image = UIImage(cgImage: cgImage)
            return image.preparingForDisplay() ?? image
        }.value
    }

    private func validatedData(
        from response: FlowMediaFetchedResponse?,
        for url: URL,
        maxByteCount: Int?
    ) async -> Data? {
        guard let response else {
            guard !Task.isCancelled else { return nil }
            await failureBackoff.recordTransportFailure(for: url)
            return nil
        }

        if response.exceededByteLimit || !isAllowedByteCount(response.data.count, maxByteCount: maxByteCount) {
            recordOversizedMedia(for: url, maxByteCount: maxByteCount)
            return nil
        }

        if let statusCode = response.statusCode,
           !(200...299).contains(statusCode) {
            await failureBackoff.recordInvalidResponse(for: url)
            return nil
        }

        guard Self.isLikelyRenderableImageData(
            response.data,
            contentType: response.contentType
        ) else {
            await failureBackoff.recordInvalidResponse(for: url)
            return nil
        }

        await failureBackoff.recordSuccess(for: url)
        return response.data
    }

    private static func makeFetchedResponse(
        data: Data,
        response: URLResponse?
    ) -> FlowMediaFetchedResponse {
        let httpResponse = response as? HTTPURLResponse
        return FlowMediaFetchedResponse(
            data: data,
            statusCode: httpResponse?.statusCode,
            contentType: httpResponse?.value(forHTTPHeaderField: "Content-Type")
        )
    }

    private static func isLikelyRenderableImageData(
        _ data: Data,
        contentType: String?
    ) -> Bool {
        guard hasSupportedImageSignature(data) else { return false }

        guard let normalizedContentType = normalizedContentType(contentType) else {
            return true
        }

        if normalizedContentType == "image/svg+xml" {
            return false
        }

        if normalizedContentType.hasPrefix("image/") {
            return true
        }

        switch normalizedContentType {
        case "application/octet-stream", "binary/octet-stream", "application/binary":
            return true
        default:
            return false
        }
    }

    private static func isLikelyVideoURL(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "mp4", "mov", "m4v", "webm", "mkv", "m3u8":
            return true
        default:
            return false
        }
    }

    private static func normalizedContentType(_ contentType: String?) -> String? {
        guard let contentType else { return nil }
        let normalized = contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == true ? nil : normalized
    }

    private static func imageAspectRatio(from data: Data) -> CGFloat? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let pixelSize = imagePixelSize(from: source) else {
            return nil
        }

        return clampedAspectRatio(width: pixelSize.width, height: pixelSize.height)
    }

    private static func imagePixelSize(from source: CGImageSource) -> ImagePixelSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber).map({ CGFloat(truncating: $0) }),
              var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber).map({ CGFloat(truncating: $0) }) else {
            return nil
        }

        if let orientationValue = properties[kCGImagePropertyOrientation] as? NSNumber,
           let orientation = CGImagePropertyOrientation(rawValue: UInt32(orientationValue.intValue)),
           orientation.swapsDimensions {
            swap(&width, &height)
        }

        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return nil
        }

        return ImagePixelSize(width: width, height: height)
    }

    private static func aspectRatio(for image: UIImage) -> CGFloat? {
        clampedAspectRatio(width: image.size.width, height: image.size.height)
    }

    private static func clampedAspectRatio(width: CGFloat, height: CGFloat) -> CGFloat? {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return min(max(width / height, 0.28), 3.2)
    }

    private static func hasSupportedImageSignature(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }

        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return true
        }

        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return true
        }

        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return true
        }

        if data.count >= 12,
           data.starts(with: [0x52, 0x49, 0x46, 0x46]),
           String(data: data[8..<12], encoding: .ascii) == "WEBP" {
            return true
        }

        if data.count >= 12,
           String(data: data[4..<8], encoding: .ascii) == "ftyp" {
            let brand = String(data: data[8..<12], encoding: .ascii) ?? ""
            if ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif", "avis"].contains(brand) {
                return true
            }
        }

        return false
    }

    private func recordRequestIfNeeded(_ tracking: FlowMediaCacheDiagnosticsTracking) {
        guard tracking.shouldRecord else { return }
        diagnostics.trackedRequestCount += 1
    }

    private func recordCacheHit(
        _ source: FlowMediaCacheHitSource,
        byteCount: Int,
        tracking: FlowMediaCacheDiagnosticsTracking
    ) {
        guard tracking.shouldRecord else { return }

        switch source {
        case .imageMemory:
            diagnostics.imageMemoryHitCount += 1
        case .dataMemory:
            diagnostics.dataMemoryHitCount += 1
        case .disk:
            diagnostics.diskHitCount += 1
        case .urlCache:
            diagnostics.urlCacheHitCount += 1
        }

        diagnostics.cacheServedByteCount += Int64(max(0, byteCount))
    }

    private func recordNetworkResult(
        _ data: Data?,
        tracking: FlowMediaCacheDiagnosticsTracking
    ) {
        guard tracking.shouldRecord else { return }

        if let data {
            diagnostics.networkFetchCount += 1
            diagnostics.networkServedByteCount += Int64(data.count)
        } else {
            diagnostics.networkFailureCount += 1
        }
    }

    private func storeEncodedByteCount(_ byteCount: Int, for cacheKey: NSURL) {
        encodedByteCounts.setObject(NSNumber(value: byteCount), forKey: cacheKey)
    }

    private func encodedByteCount(for cacheKey: NSURL) -> Int {
        encodedByteCounts.object(forKey: cacheKey)?.intValue ?? 0
    }

    private func isAllowedByteCount(_ byteCount: Int, maxByteCount: Int?) -> Bool {
        guard let maxByteCount else { return true }
        return byteCount > 0 && byteCount <= maxByteCount
    }

    private func canAttemptSizeLimitedRequest(for url: URL, maxByteCount: Int?) -> Bool {
        guard maxByteCount != nil else { return true }
        let key = FetchKey(url: url, maxByteCount: maxByteCount)
        guard let retryAfter = oversizedMediaRetryAfter[key] else { return true }
        if Date() >= retryAfter {
            oversizedMediaRetryAfter[key] = nil
            return true
        }
        return false
    }

    private func recordOversizedMedia(for url: URL, maxByteCount: Int?) {
        guard maxByteCount != nil else { return }
        let key = FetchKey(url: url, maxByteCount: maxByteCount)
        oversizedMediaRetryAfter[key] = Date().addingTimeInterval(oversizedMediaBackoff)
    }

    private static func fetchImageResponse(
        with request: URLRequest,
        maxByteCount: Int?
    ) async -> FlowMediaFetchedResponse? {
        do {
            guard let maxByteCount else {
                let (data, response) = try await URLSession.shared.data(for: request)
                return makeFetchedResponse(data: data, response: response)
            }

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let httpResponse = response as? HTTPURLResponse
            if responseContentLength(response, httpResponse: httpResponse).map({ $0 > maxByteCount }) == true {
                return makeFetchedResponse(data: Data(), response: response, exceededByteLimit: true)
            }

            var data = Data()
            data.reserveCapacity(min(maxByteCount, 128 * 1_024))
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxByteCount {
                    return makeFetchedResponse(data: Data(), response: response, exceededByteLimit: true)
                }
            }

            return makeFetchedResponse(data: data, response: response)
        } catch {
            return nil
        }
    }

    private static func makeFetchedResponse(
        data: Data,
        response: URLResponse?,
        exceededByteLimit: Bool
    ) -> FlowMediaFetchedResponse {
        let httpResponse = response as? HTTPURLResponse
        return FlowMediaFetchedResponse(
            data: data,
            statusCode: httpResponse?.statusCode,
            contentType: httpResponse?.value(forHTTPHeaderField: "Content-Type"),
            exceededByteLimit: exceededByteLimit
        )
    }

    private static func responseContentLength(
        _ response: URLResponse,
        httpResponse: HTTPURLResponse?
    ) -> Int? {
        if let contentLength = httpResponse?.value(forHTTPHeaderField: "Content-Length"),
           let parsed = Int(contentLength),
           parsed > 0 {
            return parsed
        }

        let expected = response.expectedContentLength
        return expected > 0 ? Int(expected) : nil
    }
}

private extension CGImagePropertyOrientation {
    var swapsDimensions: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored:
            return true
        default:
            return false
        }
    }
}

enum CachedAsyncImagePhase {
    case empty
    case success(Image)
    case failure
}

struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    let transaction: Transaction
    let kind: FlowImageCacheRequestKind
    let enforceNetworkByteLimit: Bool?
    private let content: (CachedAsyncImagePhase) -> Content

    @EnvironmentObject private var appSettings: AppSettingsStore
    @State private var phase: CachedAsyncImagePhase = .empty
    @State private var loadedRequest: LoadRequest?

    private struct LoadRequest: Hashable {
        let url: URL?
        let kind: FlowImageCacheRequestKind
        let enforceNetworkByteLimit: Bool
    }

    init(
        url: URL?,
        transaction: Transaction = Transaction(),
        kind: FlowImageCacheRequestKind = .standard,
        enforceNetworkByteLimit: Bool? = nil,
        @ViewBuilder content: @escaping (CachedAsyncImagePhase) -> Content
    ) {
        self.url = url
        self.transaction = transaction
        self.kind = kind
        self.enforceNetworkByteLimit = enforceNetworkByteLimit
        self.content = content
    }

    var body: some View {
        content(phase)
            .task(id: loadRequest) {
                await load(request: loadRequest)
            }
    }

    private var loadRequest: LoadRequest {
        LoadRequest(
            url: url,
            kind: kind,
            enforceNetworkByteLimit: enforceNetworkByteLimit ?? appSettings.mediaFileSizeLimitsEffective
        )
    }

    @MainActor
    private func load(request: LoadRequest) async {
        guard let url = request.url else {
            loadedRequest = nil
            phase = .failure
            return
        }

        if loadedRequest == request, case .success = phase {
            return
        }

        loadedRequest = request
        phase = .empty

        let loadedImage = await FlowImageCache.shared.image(
            for: url,
            kind: request.kind,
            enforceNetworkByteLimit: request.enforceNetworkByteLimit
        )

        if let image = loadedImage {
            withTransaction(transaction) {
                phase = .success(Image(uiImage: image))
            }
        } else {
            withTransaction(transaction) {
                phase = .failure
            }
        }
    }
}
