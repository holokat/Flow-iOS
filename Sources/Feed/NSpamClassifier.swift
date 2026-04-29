import Foundation

struct NSpamNoteInput: Sendable {
    let content: String
    let tags: [[String]]
    let createdAt: Int
}

private struct NSpamPreparedText {
    let text: String
    let rawText: String
}

enum MurmurHash3 {
    private static let c1: UInt32 = 0xcc9e2d51
    private static let c2: UInt32 = 0x1b873593
    private static let fmix1: UInt32 = 0x85ebca6b
    private static let fmix2: UInt32 = 0xc2b2ae35

    static func hash32(_ data: [UInt8], seed: UInt32 = 0) -> Int32 {
        var h1 = seed
        let blockCount = data.count / 4

        for block in 0..<blockCount {
            let offset = block * 4
            var k1 = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)

            k1 &*= c1
            k1 = k1.rotatedLeft(by: 15)
            k1 &*= c2

            h1 ^= k1
            h1 = h1.rotatedLeft(by: 13)
            h1 = h1 &* 5 &+ 0xe6546b64
        }

        let tailOffset = blockCount * 4
        var k1: UInt32 = 0

        switch data.count & 3 {
        case 3:
            k1 ^= UInt32(data[tailOffset + 2]) << 16
            k1 ^= UInt32(data[tailOffset + 1]) << 8
            k1 ^= UInt32(data[tailOffset])
            k1 &*= c1
            k1 = k1.rotatedLeft(by: 15)
            k1 &*= c2
            h1 ^= k1
        case 2:
            k1 ^= UInt32(data[tailOffset + 1]) << 8
            k1 ^= UInt32(data[tailOffset])
            k1 &*= c1
            k1 = k1.rotatedLeft(by: 15)
            k1 &*= c2
            h1 ^= k1
        case 1:
            k1 ^= UInt32(data[tailOffset])
            k1 &*= c1
            k1 = k1.rotatedLeft(by: 15)
            k1 &*= c2
            h1 ^= k1
        default:
            break
        }

        h1 ^= UInt32(data.count)
        h1 ^= h1 >> 16
        h1 &*= fmix1
        h1 ^= h1 >> 13
        h1 &*= fmix2
        h1 ^= h1 >> 16

        return Int32(bitPattern: h1)
    }
}

private extension UInt32 {
    func rotatedLeft(by amount: UInt32) -> UInt32 {
        (self << amount) | (self >> (32 - amount))
    }
}

private enum NSpamPreprocessor {
    private static let invisibleScalarValues: [UInt32] = [
        0x180E, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2060, 0x2061, 0x2062, 0x2063, 0x2064,
        0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF
    ]
    private static let invisibleScalars: Set<UnicodeScalar> = Set(invisibleScalarValues.compactMap { UnicodeScalar($0) })

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"https?://([^\s/]+)(/\S*)?"#,
        options: [.caseInsensitive]
    )
    private static let whitespacePattern = try! NSRegularExpression(pattern: #"\s+"#)

    static func countInvisibleChars(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if invisibleScalars.contains(scalar) {
                count += 1
            }
        }
    }

    static func removingInvisibleChars(from text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !invisibleScalars.contains($0) }))
    }

    static func preprocess(_ text: String) -> NSpamPreparedText {
        let nfkc = (text as NSString).precomposedStringWithCompatibilityMapping
        var stripped = removingInvisibleChars(from: nfkc)
        stripped = replaceMatches(in: stripped, regex: urlPattern) { source, match in
            let nsSource = source as NSString
            guard match.numberOfRanges > 1 else { return nsSource.substring(with: match.range) }
            let host = nsSource.substring(with: match.range(at: 1)).lowercased()
            return "http://\(host)"
        }
        stripped = stripped.lowercased()
        stripped = whitespacePattern.stringByReplacingMatches(
            in: stripped,
            options: [],
            range: NSRange(location: 0, length: (stripped as NSString).length),
            withTemplate: " "
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return NSpamPreparedText(text: stripped, rawText: nfkc)
    }

    private static func replaceMatches(
        in text: String,
        regex: NSRegularExpression,
        replacement: (String, NSTextCheckingResult) -> String
    ) -> String {
        let mutable = NSMutableString(string: text)
        let range = NSRange(location: 0, length: (text as NSString).length)
        let matches = regex.matches(in: text, options: [], range: range)

        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range, with: replacement(text, match))
        }

        return mutable as String
    }
}

enum NSpamFeatures {
    static let charFeatureCount = 131_072
    static let wordFeatureCount = 131_072
    static let structuralFeatureCount = 17
    static let groupFeatureCount = 6
    static let totalFeatureCount = charFeatureCount + wordFeatureCount + structuralFeatureCount + groupFeatureCount

    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}_]{2,}"#)
    private static let whitespacePattern = try! NSRegularExpression(pattern: #"\s+"#)
    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://([^\s/]+)"#, options: [.caseInsensitive])
    private static let mentionPattern = try! NSRegularExpression(
        pattern: #"\b(?:nostr:)?(?:npub1|note1|nprofile1|nevent1|naddr1)[0-9a-z]+"#,
        options: [.caseInsensitive]
    )
    private static let hashtagPattern = try! NSRegularExpression(pattern: #"#[\w]+"#)
    private static let nonWhitespaceTokenPattern = try! NSRegularExpression(pattern: #"\S+"#)
    private static let digitPattern = try! NSRegularExpression(pattern: #"\p{N}"#)
    private static let punctuationPattern = try! NSRegularExpression(pattern: #"\p{P}"#)
    private static let tokenizePattern = try! NSRegularExpression(
        pattern: #"\p{L}[\p{L}\p{M}\p{N}_]*|\p{N}+|https?://\S+|[#@][\w]+"#
    )

    static func extractFeatures(notes: [NSpamNoteInput]) -> [Float] {
        var features = Array(repeating: Float(0), count: totalFeatureCount)
        let noteCount = notes.count
        guard noteCount > 0 else { return features }

        let preparedTexts: [NSpamPreparedText] = notes.map { NSpamPreprocessor.preprocess($0.content) }
        let rawPreparedTexts = preparedTexts.map { $0.rawText }
        let charText = rawPreparedTexts.joined(separator: " ")
        hashCharWbNgrams(charText, features: &features)

        let normalizedPreparedTexts = preparedTexts.map { $0.text }
        let wordText = normalizedPreparedTexts.joined(separator: " ")
        hashWordNgrams(wordText, features: &features)

        var structuralSums = Array(repeating: Float(0), count: structuralFeatureCount)
        var charLengths: [Float] = []
        var bodyKeys: [String] = []
        var rawTexts: [String] = []
        charLengths.reserveCapacity(noteCount)
        bodyKeys.reserveCapacity(noteCount)
        rawTexts.reserveCapacity(noteCount)

        for note in notes {
            let raw = note.content
            rawTexts.append(raw)
            let bodyKey = String(
                NSpamPreprocessor.removingInvisibleChars(from: raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .prefix(200)
            )
            bodyKeys.append(bodyKey)

            let structural = extractStructural(raw: raw, tags: note.tags)
            for index in structural.indices {
                structuralSums[index] += structural[index]
            }
            charLengths.append(Float((raw as NSString).length))
        }

        let structuralOffset = charFeatureCount + wordFeatureCount
        for index in 0..<structuralFeatureCount {
            features[structuralOffset + index] = structuralSums[index] / Float(noteCount)
        }

        let groupOffset = structuralOffset + structuralFeatureCount
        features[groupOffset] = Float(noteCount)
        if noteCount > 1, let (minCreatedAt, maxCreatedAt) = createdAtRange(for: notes) {
            features[groupOffset + 1] = Float(maxCreatedAt - minCreatedAt) / 3_600
        }
        features[groupOffset + 2] = Float(Set(bodyKeys.filter { !$0.isEmpty }).count)

        if noteCount >= 2 {
            features[groupOffset + 3] = populationStdDev(charLengths)

            let tokenLists = rawTexts.map { tokenizedLowercase($0) }
            let firstTokens = tokenLists.compactMap { $0.first }
            if !firstTokens.isEmpty {
                var firstTokenCounts: [String: Int] = [:]
                for token in firstTokens {
                    firstTokenCounts[token, default: 0] += 1
                }
                features[groupOffset + 4] = Float(firstTokenCounts.values.max() ?? 0) / Float(noteCount)
            }

            let tokenSets = tokenLists.map { Set<String>($0) }
            var jaccardSum: Double = 0
            var jaccardCount = 0
            for lhsIndex in 0..<noteCount {
                for rhsIndex in (lhsIndex + 1)..<noteCount {
                    let lhs = tokenSets[lhsIndex]
                    let rhs = tokenSets[rhsIndex]
                    let unionCount = lhs.union(rhs).count
                    if unionCount > 0 {
                        jaccardSum += Double(lhs.intersection(rhs).count) / Double(unionCount)
                    }
                    jaccardCount += 1
                }
            }
            if jaccardCount > 0 {
                features[groupOffset + 5] = Float(jaccardSum / Double(jaccardCount))
            }
        }

        return features
    }

    private static func createdAtRange(for notes: [NSpamNoteInput]) -> (Int, Int)? {
        guard var minCreatedAt = notes.first?.createdAt else { return nil }
        var maxCreatedAt = minCreatedAt
        for note in notes.dropFirst() {
            minCreatedAt = min(minCreatedAt, note.createdAt)
            maxCreatedAt = max(maxCreatedAt, note.createdAt)
        }
        return (minCreatedAt, maxCreatedAt)
    }

    private static func extractStructural(raw: String, tags: [[String]]) -> [Float] {
        let nsRaw = raw as NSString
        let fullRange = NSRange(location: 0, length: nsRaw.length)
        let urlMatches = urlPattern.matches(in: raw, options: [], range: fullRange)
        let urlDomains = urlMatches.compactMap { match -> String? in
            guard match.numberOfRanges > 1 else { return nil }
            return nsRaw.substring(with: match.range(at: 1)).lowercased()
        }

        var tagP: Float = 0
        var tagE: Float = 0
        var tagT: Float = 0
        var tagOther: Float = 0
        for tag in tags {
            guard let name = tag.first else { continue }
            switch name {
            case "p":
                tagP += 1
            case "e":
                tagE += 1
            case "t":
                tagT += 1
            default:
                tagOther += 1
            }
        }

        let length = Float(nsRaw.length)
        let emojiCount = Float(raw.unicodeScalars.filter { scalar in
            scalar.properties.isEmojiPresentation || scalar.properties.isEmojiModifierBase
        }.count)
        let alphaCharacters: [UnicodeScalar] = raw.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let capsCount = alphaCharacters.filter { scalar in
            let value = String(scalar)
            return value.uppercased() == value && value.lowercased() != value
        }.count
        let digitCount = matchCount(digitPattern, in: raw, range: fullRange)
        let punctuationCount = matchCount(punctuationPattern, in: raw, range: fullRange)
        let structural: [Float] = [
            length,
            Float(matchCount(nonWhitespaceTokenPattern, in: raw, range: fullRange)),
            Float(urlMatches.count),
            Float(Set<String>(urlDomains).count),
            Float(matchCount(mentionPattern, in: raw, range: fullRange)),
            Float(matchCount(hashtagPattern, in: raw, range: fullRange)),
            tagP,
            tagE,
            tagT,
            tagOther,
            emojiCount,
            length > 0 ? emojiCount / length : 0,
            Float(NSpamPreprocessor.countInvisibleChars(raw)),
            alphaCharacters.isEmpty ? 0 : Float(capsCount) / Float(alphaCharacters.count),
            length > 0 ? Float(digitCount) / length : 0,
            length > 0 ? Float(punctuationCount) / length : 0,
            0
        ]

        return structural
    }

    private static func hashWordNgrams(_ text: String, features: inout [Float]) {
        let tokens = matches(wordPattern, in: text)
        for token in tokens {
            hashInto(token, features: &features, offset: charFeatureCount, featureCount: wordFeatureCount)
        }

        guard tokens.count > 1 else { return }
        for index in 0..<(tokens.count - 1) {
            hashInto("\(tokens[index]) \(tokens[index + 1])", features: &features, offset: charFeatureCount, featureCount: wordFeatureCount)
        }
    }

    private static func hashCharWbNgrams(_ text: String, features: inout [Float]) {
        let normalized = whitespacePattern.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: " "
        )

        for word in normalized.split(separator: " ") {
            let padded = " \(word) "
            let codeUnits = Array(padded.utf16)
            for ngramLength in 3...5 {
                guard codeUnits.count >= ngramLength else { continue }
                for start in 0...(codeUnits.count - ngramLength) {
                    let tokenSlice: ArraySlice<UInt16> = codeUnits[start..<(start + ngramLength)]
                    let token = String(decoding: tokenSlice, as: UTF16.self)
                    hashInto(token, features: &features, offset: 0, featureCount: charFeatureCount)
                }
            }
        }
    }

    private static func hashInto(_ token: String, features: inout [Float], offset: Int, featureCount: Int) {
        let hash = MurmurHash3.hash32(Array(token.utf8))
        let hashValue = Int64(hash)
        let absHash = hash == Int32.min ? Int64(Int32.max) + 1 : Swift.abs(hashValue)
        let index = Int(absHash % Int64(featureCount))
        let sign: Float = hash >= 0 ? 1 : -1
        features[offset + index] += sign
    }

    private static func tokenizedLowercase(_ text: String) -> [String] {
        matches(tokenizePattern, in: text.lowercased())
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [String] {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, options: [], range: range).map { nsText.substring(with: $0.range) }
    }

    private static func matchCount(_ regex: NSRegularExpression, in text: String, range: NSRange) -> Int {
        regex.numberOfMatches(in: text, options: [], range: range)
    }

    private static func populationStdDev(_ values: [Float]) -> Float {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.reduce(Double(0)) { partial, value in
            let delta = Double(value - mean)
            return partial + delta * delta
        } / Double(values.count)
        return Float(sqrt(variance))
    }
}

final class NSpamWeights: @unchecked Sendable {
    let coef: [Float]
    let intercept: Float
    let calibX: [Float]
    let calibY: [Float]

    init(coef: [Float], intercept: Float, calibX: [Float], calibY: [Float]) {
        self.coef = coef
        self.intercept = intercept
        self.calibX = calibX
        self.calibY = calibY
    }

    static func loadFromBundle(_ bundle: Bundle = .main) throws -> NSpamWeights {
        let coef = try loadNpyResource(named: "effective_coef", bundle: bundle)
        let intercept = try loadNpyResource(named: "intercept", bundle: bundle).first ?? 0
        let calibX = try loadNpyResource(named: "calib_x", bundle: bundle)
        let calibY = try loadNpyResource(named: "calib_y", bundle: bundle)
        return NSpamWeights(coef: coef, intercept: intercept, calibX: calibX, calibY: calibY)
    }

    private static func loadNpyResource(named name: String, bundle: Bundle) throws -> [Float] {
        let url = bundle.url(forResource: name, withExtension: "npy", subdirectory: "nspam")
            ?? bundle.url(forResource: name, withExtension: "npy")
        guard let url else {
            throw NSpamWeightsError.missingResource(name)
        }

        return try parseNpy(Data(contentsOf: url))
    }

    private static func parseNpy(_ data: Data) throws -> [Float] {
        guard data.count >= 10,
              data[0] == 0x93,
              data[1] == 0x4e,
              data[2] == 0x55,
              data[3] == 0x4d,
              data[4] == 0x50,
              data[5] == 0x59 else {
            throw NSpamWeightsError.invalidNpy
        }

        let major = data[6]
        let headerStart: Int
        let headerLength: Int
        if major <= 1 {
            headerStart = 10
            headerLength = Int(data[8]) | (Int(data[9]) << 8)
        } else {
            guard data.count >= 12 else { throw NSpamWeightsError.invalidNpy }
            headerStart = 12
            headerLength = Int(data[8])
                | (Int(data[9]) << 8)
                | (Int(data[10]) << 16)
                | (Int(data[11]) << 24)
        }

        let dataStart = headerStart + headerLength
        guard data.count >= dataStart else { throw NSpamWeightsError.invalidNpy }
        let headerData = data[headerStart..<dataStart]
        guard let header = String(data: headerData, encoding: .ascii) else {
            throw NSpamWeightsError.invalidNpy
        }
        guard header.contains("'descr': '<f4'") || header.contains("\"descr\": \"<f4\"") else {
            throw NSpamWeightsError.unsupportedNpy(header)
        }

        let count = npyElementCount(from: header)
        guard data.count >= dataStart + count * MemoryLayout<Float>.size else {
            throw NSpamWeightsError.invalidNpy
        }

        var values: [Float] = []
        values.reserveCapacity(count)
        for index in 0..<count {
            let offset = dataStart + index * 4
            let bitPattern = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
            values.append(Float(bitPattern: bitPattern))
        }
        return values
    }

    private static func npyElementCount(from header: String) -> Int {
        guard let shapeRange = header.range(of: #"'shape'\s*:\s*\(([^)]*)\)"#, options: .regularExpression) else {
            return 1
        }

        let shape = String(header[shapeRange])
        guard let open = shape.firstIndex(of: "("),
              let close = shape.firstIndex(of: ")"),
              open < close else {
            return 1
        }

        let body = shape[shape.index(after: open)..<close]
        let values = body
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return values.isEmpty ? 1 : values.reduce(1, *)
    }
}

enum NSpamWeightsError: Error {
    case missingResource(String)
    case invalidNpy
    case unsupportedNpy(String)
}

final class NSpamClassifier: @unchecked Sendable {
    private let weights: NSpamWeights

    init(weights: NSpamWeights) {
        self.weights = weights
    }

    func score(notes: [NSpamNoteInput]) -> Float? {
        guard !notes.isEmpty else { return nil }
        let cappedNotes = notes.count > 10
            ? Array(notes.sorted { $0.createdAt > $1.createdAt }.prefix(10))
            : notes
        let features = NSpamFeatures.extractFeatures(notes: cappedNotes)
        let rawScore = sigmoid(dotProduct(features, weights.coef) + weights.intercept)
        return calibrate(raw: rawScore, calibX: weights.calibX, calibY: weights.calibY)
    }

    private func dotProduct(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let count = min(lhs.count, rhs.count)
        var sum: Double = 0
        for index in 0..<count {
            sum += Double(lhs[index]) * Double(rhs[index])
        }
        return Float(sum)
    }

    private func sigmoid(_ value: Float) -> Float {
        Float(1.0 / (1.0 + exp(-Double(value))))
    }

    private func calibrate(raw: Float, calibX: [Float], calibY: [Float]) -> Float {
        guard !calibX.isEmpty, calibX.count == calibY.count else { return raw }
        if raw <= calibX[0] {
            return calibY[0]
        }
        if let lastX = calibX.last, let lastY = calibY.last, raw >= lastX {
            return lastY
        }

        for index in 0..<(calibX.count - 1) {
            if raw >= calibX[index], raw < calibX[index + 1] {
                let denominator = calibX[index + 1] - calibX[index]
                guard denominator != 0 else { return calibY[index] }
                let t = (raw - calibX[index]) / denominator
                return calibY[index] + t * (calibY[index + 1] - calibY[index])
            }
        }

        return calibY.last ?? raw
    }
}

private struct NSpamPersonalizationLabels: Sendable {
    let markedSpamPubkeys: [String]
    let notSpamPubkeys: [String]

    init(markedSpamPubkeys: [String], notSpamPubkeys: [String]) {
        self.notSpamPubkeys = Self.normalizedUnique(notSpamPubkeys)
        let notSpamSet = Set(self.notSpamPubkeys)
        self.markedSpamPubkeys = Self.normalizedUnique(markedSpamPubkeys)
            .filter { !notSpamSet.contains($0) }
    }

    var signature: String {
        [
            markedSpamPubkeys.joined(separator: "|"),
            notSpamPubkeys.joined(separator: "|")
        ]
        .joined(separator: "-")
    }

    func exactScore(for pubkey: String) -> Float? {
        let normalized = Self.normalizedPubkey(pubkey)
        if notSpamPubkeys.contains(normalized) {
            return 0
        }
        if markedSpamPubkeys.contains(normalized) {
            return 1
        }
        return nil
    }

    private static func normalizedUnique(_ pubkeys: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for pubkey in pubkeys {
            let normalized = normalizedPubkey(pubkey)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }
        return ordered
    }

    private static func normalizedPubkey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private enum NSpamLocalPersonalizer {
    private static let similarityThreshold: Float = 0.55
    private static let maxAdjustment: Float = 0.28
    private static let labelLimit = 16

    static func adjustedScore(
        baseScore: Float,
        candidateNotes: [NSpamNoteInput],
        markedSpamNotes: [[NSpamNoteInput]],
        notSpamNotes: [[NSpamNoteInput]]
    ) -> Float {
        guard !candidateNotes.isEmpty else { return baseScore }
        guard !markedSpamNotes.isEmpty || !notSpamNotes.isEmpty else { return baseScore }

        let candidateFeatures = NSpamFeatures.extractFeatures(notes: candidateNotes)
        let spamSimilarity = maxSimilarity(candidateFeatures, labeledNotes: Array(markedSpamNotes.prefix(labelLimit)))
        let notSpamSimilarity = maxSimilarity(candidateFeatures, labeledNotes: Array(notSpamNotes.prefix(labelLimit)))

        let spamBoost = max(0, spamSimilarity - similarityThreshold) * maxAdjustment
        let notSpamReduction = max(0, notSpamSimilarity - similarityThreshold) * maxAdjustment
        return min(max(baseScore + spamBoost - notSpamReduction, 0), 1)
    }

    private static func maxSimilarity(_ candidateFeatures: [Float], labeledNotes: [[NSpamNoteInput]]) -> Float {
        var maximum: Float = 0
        for notes in labeledNotes where !notes.isEmpty {
            let labelFeatures = NSpamFeatures.extractFeatures(notes: notes)
            maximum = max(maximum, cosineSimilarity(candidateFeatures, labelFeatures))
        }
        return maximum
    }

    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let count = min(lhs.count, rhs.count)
        var dot: Double = 0
        var lhsNorm: Double = 0
        var rhsNorm: Double = 0

        for index in 0..<count {
            let lhsValue = Double(lhs[index])
            let rhsValue = Double(rhs[index])
            dot += lhsValue * rhsValue
            lhsNorm += lhsValue * lhsValue
            rhsNorm += rhsValue * rhsValue
        }

        guard lhsNorm > 0, rhsNorm > 0 else { return 0 }
        return Float(dot / (sqrt(lhsNorm) * sqrt(rhsNorm)))
    }
}

actor NSpamAuthorCache {
    private struct Entry {
        let score: Float
        let noteCount: Int
        let personalizationSignature: String
    }

    private let maxEntries: Int
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private static let rescoreThreshold = 5

    init(maxEntries: Int = 2_000) {
        self.maxEntries = maxEntries
    }

    func score(
        for pubkey: String,
        currentNoteCount: Int,
        personalizationSignature: String
    ) -> Float? {
        guard let entry = entries[pubkey] else { return nil }
        guard entry.personalizationSignature == personalizationSignature else { return nil }
        if entry.noteCount < Self.rescoreThreshold, currentNoteCount >= Self.rescoreThreshold {
            return nil
        }
        touch(pubkey)
        return entry.score
    }

    func put(
        pubkey: String,
        score: Float,
        noteCount: Int,
        personalizationSignature: String
    ) {
        entries[pubkey] = Entry(
            score: score,
            noteCount: noteCount,
            personalizationSignature: personalizationSignature
        )
        touch(pubkey)
        trimIfNeeded()
    }

    private func touch(_ pubkey: String) {
        order.removeAll { $0 == pubkey }
        order.append(pubkey)
    }

    private func trimIfNeeded() {
        while entries.count > maxEntries, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}

actor NSpamAuthorScorer {
    static let shared = NSpamAuthorScorer()

    private let cache = NSpamAuthorCache()
    private var classifier: NSpamClassifier?
    private var didAttemptClassifierLoad = false

    func cachedScore(
        for pubkey: String,
        markedSpamPubkeys: [String] = [],
        notSpamPubkeys: [String] = []
    ) async -> Float? {
        let labels = NSpamPersonalizationLabels(
            markedSpamPubkeys: markedSpamPubkeys,
            notSpamPubkeys: notSpamPubkeys
        )
        if let exactScore = labels.exactScore(for: pubkey) {
            return exactScore
        }
        let notes = cachedNoteInputs(for: pubkey)
        return await cache.score(
            for: normalizedPubkey(pubkey),
            currentNoteCount: notes.count,
            personalizationSignature: labels.signature
        )
    }

    func scoreAuthor(
        pubkey: String,
        markedSpamPubkeys: [String] = [],
        notSpamPubkeys: [String] = []
    ) async -> Float? {
        let normalized = normalizedPubkey(pubkey)
        guard !normalized.isEmpty else { return nil }
        let labels = NSpamPersonalizationLabels(
            markedSpamPubkeys: markedSpamPubkeys,
            notSpamPubkeys: notSpamPubkeys
        )
        if let exactScore = labels.exactScore(for: normalized) {
            await cache.put(
                pubkey: normalized,
                score: exactScore,
                noteCount: 0,
                personalizationSignature: labels.signature
            )
            return exactScore
        }
        let notes = cachedNoteInputs(for: normalized)
        guard !notes.isEmpty, let classifier = classifierIfAvailable() else { return nil }
        guard let score = classifier.score(notes: notes) else { return nil }
        let adjustedScore = personalizedScore(
            baseScore: score,
            candidatePubkey: normalized,
            candidateNotes: notes,
            labels: labels
        )
        await cache.put(
            pubkey: normalized,
            score: adjustedScore,
            noteCount: notes.count,
            personalizationSignature: labels.signature
        )
        return adjustedScore
    }

    private func classifierIfAvailable() -> NSpamClassifier? {
        if didAttemptClassifierLoad {
            return classifier
        }
        didAttemptClassifierLoad = true
        if let weights = try? NSpamWeights.loadFromBundle() {
            classifier = NSpamClassifier(weights: weights)
        }
        return classifier
    }

    private nonisolated func personalizedScore(
        baseScore: Float,
        candidatePubkey: String,
        candidateNotes: [NSpamNoteInput],
        labels: NSpamPersonalizationLabels
    ) -> Float {
        let spamNotes = labels.markedSpamPubkeys
            .filter { $0 != candidatePubkey }
            .map { cachedNoteInputs(for: $0) }
            .filter { !$0.isEmpty }
        let notSpamNotes = labels.notSpamPubkeys
            .filter { $0 != candidatePubkey }
            .map { cachedNoteInputs(for: $0) }
            .filter { !$0.isEmpty }
        return NSpamLocalPersonalizer.adjustedScore(
            baseScore: baseScore,
            candidateNotes: candidateNotes,
            markedSpamNotes: spamNotes,
            notSpamNotes: notSpamNotes
        )
    }

    private nonisolated func cachedNoteInputs(for pubkey: String) -> [NSpamNoteInput] {
        let normalized = normalizedPubkey(pubkey)
        guard !normalized.isEmpty else { return [] }
        return []
    }

    private nonisolated func normalizedPubkey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
