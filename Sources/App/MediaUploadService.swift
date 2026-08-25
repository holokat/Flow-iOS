import CryptoKit
import Foundation
import ImageIO
import NostrSDK

enum MediaUploadProvider: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case blossom
    case nostrBuild

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blossom:
            return "Blossom"
        case .nostrBuild:
            return "Backup Upload"
        }
    }
}

struct MediaUploadResult: Sendable {
    let url: URL
    let imetaTag: [String]
}

enum HaloPersonalMediaRoutingPolicy {
    static let ownerPublicKeyHex = "1bc70a0148b3f316da33fe3c89f23e3e71ac4ff998027ec712b905cd24f6a411"
    static let blossomServerURL = URL(string: "https://media.21media.to/")!

    static func exclusiveBlossomServer(for publicKeyHex: String) -> URL? {
        let normalizedPublicKey = publicKeyHex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedPublicKey == ownerPublicKeyHex ? blossomServerURL : nil
    }
}

enum BlossomAuthorizationCoding {
    static func uploadTags(
        sha256Hex: String,
        serverHost: String,
        expiration: String
    ) -> [[String]] {
        [
            ["t", "upload"],
            ["expiration", expiration],
            ["x", sha256Hex],
            ["server", serverHost.lowercased()]
        ]
    }

    static func headerValue(for eventData: Data) -> String {
        let base64URL = eventData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "Nostr \(base64URL)"
    }
}

enum MediaUploadError: LocalizedError {
    case invalidCredentials
    case missingFileData
    case invalidUploadService
    case unsupportedBlossomPayment
    case blossomUploadFailed(statusCode: Int)
    case nip96UploadFailed(statusCode: Int)
    case invalidUploadResponse
    case missingUploadedURL
    case blossomFallbackFailed(primaryDescription: String, fallbackDescription: String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Sign in to upload media."
        case .missingFileData:
            return "Couldn't read selected media."
        case .invalidUploadService:
            return "Media upload service is unavailable right now."
        case .unsupportedBlossomPayment:
            return "Blossom upload requires payment and isn't supported by this client yet."
        case .blossomUploadFailed(let statusCode):
            return "Blossom upload failed (\(statusCode))."
        case .nip96UploadFailed(let statusCode):
            return "Media upload failed (\(statusCode))."
        case .invalidUploadResponse:
            return "Upload completed, but the response was invalid."
        case .missingUploadedURL:
            return "Upload completed, but no media URL was returned."
        case .blossomFallbackFailed(let primaryDescription, let fallbackDescription):
            return "Primary upload failed: \(primaryDescription) Backup upload also failed: \(fallbackDescription)"
        }
    }
}

actor MediaUploadService {
    static let shared = MediaUploadService()

    private let nostrBuildServiceURL = URL(string: "https://nostr.build")!
    private let relayClient = NostrRelayClient()
    private let uploadSession: URLSession
    private let blossomServerListKind = 10_063
    private let blossomServerListCacheTTL: TimeInterval = 60 * 10
    private let blossomServerCandidates: [URL] = [
        URL(string: "https://blossom.primal.net/")!,
        URL(string: "https://blossom.band/")!,
        URL(string: "https://blossom.nostr.build/")!
    ]

    private var nip96UploadURLByService: [String: URL] = [:]
    private var blossomServerCacheByPubkey: [String: (urls: [URL], storedAt: Date)] = [:]

    init(uploadSession: URLSession = MediaUploadService.makeUploadSession()) {
        self.uploadSession = uploadSession
    }

    private nonisolated static func makeUploadSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }

    func uploadMedia(
        data: Data,
        mimeType: String,
        filename: String,
        nsec: String,
        provider: MediaUploadProvider
    ) async throws -> MediaUploadResult {
        guard !data.isEmpty else {
            throw MediaUploadError.missingFileData
        }

        guard let keypair = Keypair(nsec: nsec.lowercased()) else {
            throw MediaUploadError.invalidCredentials
        }

        if let personalServer = HaloPersonalMediaRoutingPolicy.exclusiveBlossomServer(
            for: keypair.publicKey.hex
        ) {
            return try await uploadToBlossomServer(
                serverURL: personalServer,
                data: data,
                mimeType: mimeType,
                keypair: keypair
            )
        }

        switch provider {
        case .blossom:
            do {
                return try await uploadViaBlossom(
                    data: data,
                    mimeType: mimeType,
                    keypair: keypair
                )
            } catch {
                let blossomDescription = describeUploadError(error)

                do {
                    return try await uploadViaNIP96(
                        serviceURL: nostrBuildServiceURL,
                        data: data,
                        mimeType: mimeType,
                        filename: filename,
                        keypair: keypair
                    )
                } catch {
                    throw MediaUploadError.blossomFallbackFailed(
                        primaryDescription: blossomDescription,
                        fallbackDescription: describeUploadError(error)
                    )
                }
            }
        case .nostrBuild:
            return try await uploadViaNIP96(
                serviceURL: nostrBuildServiceURL,
                data: data,
                mimeType: mimeType,
                filename: filename,
                keypair: keypair
            )
        }
    }

    private func uploadViaBlossom(
        data: Data,
        mimeType: String,
        keypair: Keypair
    ) async throws -> MediaUploadResult {
        var firstError: Error?
        let preferredServers = await resolvedBlossomServers(for: keypair.publicKey.hex.lowercased())

        for server in preferredServers {
            do {
                return try await uploadToBlossomServer(
                    serverURL: server,
                    data: data,
                    mimeType: mimeType,
                    keypair: keypair
                )
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if let firstError {
            throw firstError
        }
        throw MediaUploadError.invalidUploadService
    }

    private func uploadToBlossomServer(
        serverURL: URL,
        data: Data,
        mimeType: String,
        keypair: Keypair
    ) async throws -> MediaUploadResult {
        let uploadURL = URL(string: "/upload", relativeTo: serverURL)?.absoluteURL ?? serverURL.appendingPathComponent("upload")
        guard let serverHost = uploadURL.host?.lowercased(), !serverHost.isEmpty else {
            throw MediaUploadError.invalidUploadService
        }
        let sha256Hex = sha256(data: data)

        let checkStatus = try await blossomHeadCheckStatus(
            uploadURL: uploadURL,
            sha256Hex: sha256Hex,
            mimeType: mimeType,
            size: data.count
        )

        if checkStatus == 402 {
            throw MediaUploadError.unsupportedBlossomPayment
        }

        let shouldSendAuth = checkStatus == 401

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue(sha256Hex, forHTTPHeaderField: "X-SHA-256")
        uploadRequest.setValue(mimeType, forHTTPHeaderField: "Content-Type")

        if shouldSendAuth {
            let authHeader = try makeBlossomAuthHeader(
                sha256Hex: sha256Hex,
                serverHost: serverHost,
                keypair: keypair
            )
            uploadRequest.setValue(authHeader, forHTTPHeaderField: "Authorization")
        }

        var (responseData, response) = try await uploadSession.upload(
            for: uploadRequest,
            from: data
        )
        var statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

        if statusCode == 401 && !shouldSendAuth {
            let authHeader = try makeBlossomAuthHeader(
                sha256Hex: sha256Hex,
                serverHost: serverHost,
                keypair: keypair
            )

            uploadRequest.setValue(authHeader, forHTTPHeaderField: "Authorization")
            let retried = try await uploadSession.upload(
                for: uploadRequest,
                from: data
            )
            responseData = retried.0
            response = retried.1
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MediaUploadError.invalidUploadResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 402 {
                throw MediaUploadError.unsupportedBlossomPayment
            }
            throw MediaUploadError.blossomUploadFailed(statusCode: httpResponse.statusCode)
        }

        guard let object = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let urlString = object["url"] as? String,
              let uploadedURL = URL(string: urlString) else {
            throw MediaUploadError.missingUploadedURL
        }

        var imeta = ["imeta", "url \(uploadedURL.absoluteString)"]
        let responseSHA = (object["sha256"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let responseType = (object["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let responseSize = object["size"]

        let finalSHA = (responseSHA?.isEmpty == false ? responseSHA : sha256Hex) ?? sha256Hex
        imeta.append("x \(finalSHA)")

        let finalType = (responseType?.isEmpty == false ? responseType : mimeType) ?? mimeType
        imeta.append("m \(finalType)")

        if let numericSize = responseSize as? Int {
            imeta.append("size \(numericSize)")
        } else if let numericSize = responseSize as? Double {
            imeta.append("size \(Int(numericSize))")
        } else {
            imeta.append("size \(data.count)")
        }

        appendImageDimensionsIfNeeded(to: &imeta, data: data, mimeType: finalType)

        return MediaUploadResult(url: uploadedURL, imetaTag: imeta)
    }

    private func blossomHeadCheckStatus(
        uploadURL: URL,
        sha256Hex: String,
        mimeType: String,
        size: Int
    ) async throws -> Int {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "HEAD"
        request.setValue(sha256Hex, forHTTPHeaderField: "X-SHA-256")
        request.setValue(String(size), forHTTPHeaderField: "X-Content-Length")
        request.setValue(mimeType, forHTTPHeaderField: "X-Content-Type")

        let (_, response) = try await uploadSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MediaUploadError.invalidUploadResponse
        }

        return httpResponse.statusCode
    }

    private func uploadViaNIP96(
        serviceURL: URL,
        data: Data,
        mimeType: String,
        filename: String,
        keypair: Keypair
    ) async throws -> MediaUploadResult {
        let uploadURL = try await resolveNIP96UploadURL(for: serviceURL)
        let authHeader = try makeNIP98AuthHeader(uploadURL: uploadURL, keypair: keypair)
        let boundary = "Boundary-\(UUID().uuidString)"
        let multipartFileURL = try makeMultipartBodyFile(
            boundary: boundary,
            fileData: data,
            filename: filename,
            mimeType: mimeType
        )
        defer {
            try? FileManager.default.removeItem(at: multipartFileURL)
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")

        let (responseData, response) = try await uploadSession.upload(
            for: request,
            fromFile: multipartFileURL
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MediaUploadError.invalidUploadResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw MediaUploadError.nip96UploadFailed(statusCode: httpResponse.statusCode)
        }

        let parsed = extractNIP96UploadResult(from: responseData)
        guard let uploadedURL = parsed.url else {
            throw MediaUploadError.missingUploadedURL
        }

        let imetaTag: [String]
        if parsed.imetaComponents.isEmpty {
            var components = ["imeta", "url \(uploadedURL.absoluteString)", "m \(mimeType)", "size \(data.count)"]
            appendImageDimensionsIfNeeded(to: &components, data: data, mimeType: mimeType)
            imetaTag = components
        } else {
            var components = ["imeta"] + parsed.imetaComponents
            appendImageDimensionsIfNeeded(to: &components, data: data, mimeType: mimeType)
            imetaTag = components
        }

        return MediaUploadResult(url: uploadedURL, imetaTag: imetaTag)
    }

    private func resolveNIP96UploadURL(for serviceURL: URL) async throws -> URL {
        let cacheKey = serviceURL.absoluteString.lowercased()
        if let cached = nip96UploadURLByService[cacheKey] {
            return cached
        }

        let configURL = serviceURL
            .appendingPathComponent(".well-known", isDirectory: true)
            .appendingPathComponent("nostr", isDirectory: true)
            .appendingPathComponent("nip96.json", isDirectory: false)
        let (data, response) = try await uploadSession.data(from: configURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw MediaUploadError.invalidUploadService
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uploadURLString = object["api_url"] as? String,
              let uploadURL = URL(string: uploadURLString) else {
            throw MediaUploadError.invalidUploadService
        }

        nip96UploadURLByService[cacheKey] = uploadURL
        return uploadURL
    }

    private func makeNIP98AuthHeader(uploadURL: URL, keypair: Keypair) throws -> String {
        let methodTag = ["method", "POST"]
        let urlTag = ["u", uploadURL.absoluteString]
        let sdkTags = [urlTag, methodTag].compactMap(decodeSDKTag(from:))

        let authEvent = try NostrSDK.NostrEvent.Builder<NostrSDK.NostrEvent>(kind: .unknown(27_235))
            .content("Uploading media file")
            .appendTags(contentsOf: sdkTags)
            .build(signedBy: keypair)
        let encodedEvent = try JSONEncoder().encode(authEvent)
        return "Nostr \(encodedEvent.base64EncodedString())"
    }

    private func makeBlossomAuthHeader(
        sha256Hex: String,
        serverHost: String,
        keypair: Keypair
    ) throws -> String {
        let expiration = String(Int(Date().timeIntervalSince1970) + 3600)
        let rawTags = BlossomAuthorizationCoding.uploadTags(
            sha256Hex: sha256Hex,
            serverHost: serverHost,
            expiration: expiration
        )

        let sdkTags = rawTags.compactMap(decodeSDKTag(from:))
        let authEvent = try NostrSDK.NostrEvent.Builder<NostrSDK.NostrEvent>(kind: .unknown(24_242))
            .content("Upload Blob")
            .appendTags(contentsOf: sdkTags)
            .build(signedBy: keypair)

        let encoded = try JSONEncoder().encode(authEvent)
        return BlossomAuthorizationCoding.headerValue(for: encoded)
    }

    private func extractNIP96UploadResult(from responseData: Data) -> (url: URL?, imetaComponents: [String]) {
        guard let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return (nil, [])
        }

        if let directURLString = object["url"] as? String,
           let directURL = URL(string: directURLString) {
            return (directURL, ["url \(directURL.absoluteString)"])
        }

        guard let nip94Event = object["nip94_event"] as? [String: Any],
              let rawTags = nip94Event["tags"] as? [[Any]] else {
            return (nil, [])
        }

        var mediaURL: URL?
        var imetaComponents: [String] = []

        for rawTag in rawTags {
            guard rawTag.count >= 2 else { continue }
            let name = String(describing: rawTag[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(describing: rawTag[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }
            if name.lowercased() == "url", mediaURL == nil {
                mediaURL = URL(string: value)
            }
            imetaComponents.append("\(name) \(value)")
        }

        return (mediaURL, imetaComponents)
    }

    private func makeMultipartBodyFile(
        boundary: String,
        fileData: Data,
        filename: String,
        mimeType: String
    ) throws -> URL {
        let lineBreak = "\r\n"
        let safeFilename = filename
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\"", with: "'")
        let header = """
        --\(boundary)\(lineBreak)Content-Disposition: form-data; name="file"; filename="\(safeFilename)"\(lineBreak)Content-Type: \(mimeType)\(lineBreak)\(lineBreak)
        """
        let footer = "\(lineBreak)--\(boundary)--\(lineBreak)"
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("halo-upload-\(UUID().uuidString)")
            .appendingPathExtension("multipart")

        guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
            throw MediaUploadError.missingFileData
        }

        do {
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            defer {
                try? fileHandle.close()
            }

            try fileHandle.write(contentsOf: Data(header.utf8))
            try fileHandle.write(contentsOf: fileData)
            try fileHandle.write(contentsOf: Data(footer.utf8))
            return fileURL
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw MediaUploadError.missingFileData
        }
    }

    private func decodeSDKTag(from raw: [String]) -> NostrSDK.Tag? {
        guard raw.count >= 2 else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              let tag = try? JSONDecoder().decode(NostrSDK.Tag.self, from: data) else {
            return nil
        }
        return tag
    }

    private func resolvedBlossomServers(for pubkey: String) async -> [URL] {
        let normalizedPubkey = pubkey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedPubkey.isEmpty else { return blossomServerCandidates }

        if let cached = blossomServerCacheByPubkey[normalizedPubkey],
           Date().timeIntervalSince(cached.storedAt) < blossomServerListCacheTTL,
           !cached.urls.isEmpty {
            return cached.urls
        }

        let relayURLs = await blossomRelayTargets()
        let publishedServers = await fetchBlossomServers(pubkey: normalizedPubkey, relayURLs: relayURLs)
        let resolved = normalizedServerURLs(publishedServers + blossomServerCandidates)
        let finalServers = resolved.isEmpty ? blossomServerCandidates : resolved

        blossomServerCacheByPubkey[normalizedPubkey] = (
            urls: finalServers,
            storedAt: Date()
        )

        return finalServers
    }

    private func blossomRelayTargets() async -> [URL] {
        let relayURLs = await MainActor.run {
            let appSettings = AppSettingsStore.shared
            let relaySettings = RelaySettingsStore.shared

            let readRelayURLs = appSettings.effectiveReadRelayURLs(from: relaySettings.readRelayURLs)
            let writeRelayURLs = appSettings.effectiveWriteRelayURLs(
                from: relaySettings.writeRelayURLs,
                fallbackReadRelayURLs: readRelayURLs
            )

            return readRelayURLs + writeRelayURLs
        }

        return normalizedServerURLs(relayURLs)
    }

    private func fetchBlossomServers(pubkey: String, relayURLs: [URL]) async -> [URL] {
        guard !pubkey.isEmpty, !relayURLs.isEmpty else { return [] }

        let filter = NostrFilter(
            authors: [pubkey],
            kinds: [blossomServerListKind],
            limit: 10
        )

        let events = await withTaskGroup(of: [NostrEvent].self, returning: [NostrEvent].self) { group in
            for relayURL in relayURLs.prefix(6) {
                group.addTask { [relayClient] in
                    (try? await relayClient.fetchEvents(relayURL: relayURL, filter: filter, timeout: 5)) ?? []
                }
            }

            var merged: [NostrEvent] = []
            for await relayEvents in group {
                merged.append(contentsOf: relayEvents)
            }
            return merged
        }

        guard !events.isEmpty else { return [] }

        var seenEventIDs = Set<String>()
        let latestEvent = events
            .filter { seenEventIDs.insert($0.id.lowercased()).inserted }
            .sorted(by: { $0.createdAt > $1.createdAt })
            .first

        guard let latestEvent else { return [] }

        return latestEvent.tags.compactMap { tag in
            guard tag.count > 1, tag[0].lowercased() == "server" else { return nil }
            return normalizedServerURL(from: tag[1])
        }
    }

    private func normalizedServerURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []

        for url in urls {
            guard let normalized = normalizedServerURL(from: url.absoluteString) else { continue }
            let key = normalized.absoluteString.lowercased()
            guard seen.insert(key).inserted else { continue }
            ordered.append(normalized)
        }

        return ordered
    }

    private func normalizedServerURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return nil
        }

        return URL(string: "/", relativeTo: url)?.absoluteURL ?? url
    }

    private func sha256(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func appendImageDimensionsIfNeeded(
        to imeta: inout [String],
        data: Data,
        mimeType: String
    ) {
        let normalizedMimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedMimeType.hasPrefix("image/") else { return }
        guard !imeta.contains(where: { $0.hasPrefix("dim ") }) else { return }
        guard let dimensions = imageDimensions(from: data) else { return }

        imeta.append("dim \(Int(dimensions.width))x\(Int(dimensions.height))")
    }

    private func imageDimensions(from data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber).map({ CGFloat(truncating: $0) }),
              var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber).map({ CGFloat(truncating: $0) }) else {
            return nil
        }

        if let orientationValue = properties[kCGImagePropertyOrientation] as? NSNumber,
           let orientation = CGImagePropertyOrientation(rawValue: UInt32(orientationValue.intValue)),
           imageOrientationSwapsDimensions(orientation) {
            swap(&width, &height)
        }

        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    private func imageOrientationSwapsDimensions(_ orientation: CGImagePropertyOrientation) -> Bool {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return true
        default:
            return false
        }
    }

    private func describeUploadError(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return description
        }

        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            return description
        }

        return "Unknown upload error."
    }
}
