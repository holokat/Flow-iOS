import Compression
import Foundation

enum NSpamModelIdentity {
    static let version = "v2.4"
    static let schemaVersion = 2
    static let modelRevision = "abd4b0311891d6c5f088c2b5b7e4b9dc1bbbe303"
    static let corpusRevision = "707e4c12bf2a46d0dda71eca59be59a4456d630d"
    static let modelSHA256 = "0c6e63604b78a668b8bd282d5bc5ad07e54331dd27a6c3f5c06113b8b2c84960"
    static let calibrationSHA256 = "62653a59086ae153f70ca4efc15d6d89d2ea4658c6fae962fdc4c74172358c3b"
    static let configurationSHA256 = "4c1d0412748e63f105892a4301bbf7979f8a864756582b1af2426b566edbb847"
}

struct NSpamModelConfiguration: Decodable, Sendable {
    let schemaVersion: Int
    let modelVersion: String
    let modelType: String
    let nFeaturesChar: Int
    let nFeaturesWord: Int
    let charNgramRange: [Int]
    let wordNgramRange: [Int]
    let wordAnalyzer: String
    let charAnalyzer: String
    let structuralNames: [String]
    let groupFeatureNames: [String]
    let unicodeNormalization: String
    let casefold: Bool
    let hashing: Hashing

    struct Hashing: Decodable, Sendable {
        let algorithm: String
        let alternateSign: Bool

        enum CodingKeys: String, CodingKey {
            case algorithm
            case alternateSign = "alternate_sign"
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case modelVersion = "model_version"
        case modelType = "model_type"
        case nFeaturesChar = "n_features_char"
        case nFeaturesWord = "n_features_word"
        case charNgramRange = "char_ngram_range"
        case wordNgramRange = "word_ngram_range"
        case wordAnalyzer = "word_analyzer"
        case charAnalyzer = "char_analyzer"
        case structuralNames = "structural_names"
        case groupFeatureNames = "group_feature_names"
        case unicodeNormalization = "unicode_normalization"
        case casefold
        case hashing
    }

    func validate() throws {
        guard schemaVersion == NSpamModelIdentity.schemaVersion,
              modelVersion == NSpamModelIdentity.version,
              modelType == "lightgbm",
              nFeaturesChar == NSpamFeatures.charFeatureCount,
              nFeaturesWord == NSpamFeatures.wordFeatureCount,
              charNgramRange == [3, 5],
              wordNgramRange == [1, 2],
              wordAnalyzer == "word",
              charAnalyzer == "char_wb",
              structuralNames.count == NSpamFeatures.structuralFeatureCount,
              groupFeatureNames.count == NSpamFeatures.groupFeatureCount,
              unicodeNormalization == "NFKC",
              casefold,
              hashing.algorithm == "MurmurHash3 x86 32-bit (seed=0)",
              hashing.alternateSign else {
            throw NSpamWeightsError.incompatibleConfiguration
        }
    }
}

final class NSpamLightGBMModel: @unchecked Sendable {
    struct Tree: Sendable {
        let splitFeature: [Int32]
        let threshold: [Double]
        let decisionType: [UInt8]
        let leftChild: [Int32]
        let rightChild: [Int32]
        let leafValue: [Double]
    }

    let trees: [Tree]

    init(trees: [Tree]) {
        self.trees = trees
    }

    func rawMargin(features: [Float]) -> Double {
        var sum = Double(0)
        for tree in trees {
            var node = Int32(0)
            while node >= 0 {
                let nodeIndex = Int(node)
                let featureIndex = Int(tree.splitFeature[nodeIndex])
                let value = Double(features[featureIndex])
                if value.isNaN {
                    node = tree.decisionType[nodeIndex] & 2 != 0
                        ? tree.leftChild[nodeIndex]
                        : tree.rightChild[nodeIndex]
                } else {
                    node = value <= tree.threshold[nodeIndex]
                        ? tree.leftChild[nodeIndex]
                        : tree.rightChild[nodeIndex]
                }
            }
            sum += Double(tree.leafValue[Int(-node - 1)])
        }
        return sum
    }

    static func parse(data: Data) throws -> NSpamLightGBMModel {
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSpamWeightsError.invalidModel
        }
        return try parse(text: text)
    }

    static func parse(text: String) throws -> NSpamLightGBMModel {
        var trees: [Tree] = []
        trees.reserveCapacity(512)
        var header: [String: String] = [:]
        var fields: [String: String] = [:]
        var isInsideTree = false

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Tree=") {
                if isInsideTree {
                    trees.append(try buildTree(fields))
                }
                fields.removeAll(keepingCapacity: true)
                isInsideTree = true
            } else if line == "end of trees" {
                if isInsideTree {
                    trees.append(try buildTree(fields))
                    isInsideTree = false
                }
                break
            } else if let separator = line.firstIndex(of: "=") {
                let key = String(line[..<separator])
                if isInsideTree, treeFields.contains(key) {
                    fields[key] = String(line[line.index(after: separator)...])
                } else if !isInsideTree, headerFields.contains(key) {
                    header[key] = String(line[line.index(after: separator)...])
                }
            }
        }

        if isInsideTree {
            trees.append(try buildTree(fields))
        }
        guard !trees.isEmpty,
              header["objective"] == "binary sigmoid:1",
              header["max_feature_idx"] == String(NSpamFeatures.totalFeatureCount - 1) else {
            throw NSpamWeightsError.invalidModel
        }
        return NSpamLightGBMModel(trees: trees)
    }

    private static let treeFields: Set<String> = [
        "split_feature", "threshold", "decision_type", "left_child", "right_child", "leaf_value"
    ]
    private static let headerFields: Set<String> = ["max_feature_idx", "objective"]

    private static func buildTree(_ fields: [String: String]) throws -> Tree {
        guard let splitFeatureSource = fields["split_feature"],
              let thresholdSource = fields["threshold"],
              let decisionTypeSource = fields["decision_type"],
              let leftChildSource = fields["left_child"],
              let rightChildSource = fields["right_child"],
              let leafValueSource = fields["leaf_value"] else {
            throw NSpamWeightsError.invalidModel
        }

        let splitFeature = try parseInt32s(splitFeatureSource)
        let threshold = try parseDoubles(thresholdSource)
        let decisionType = try parseUInt8s(decisionTypeSource)
        let leftChild = try parseInt32s(leftChildSource)
        let rightChild = try parseInt32s(rightChildSource)
        let leafValue = try parseDoubles(leafValueSource)
        let nodeCount = splitFeature.count

        guard nodeCount > 0,
              threshold.count == nodeCount,
              decisionType.count == nodeCount,
              decisionType.allSatisfy({ $0 == 2 }),
              leftChild.count == nodeCount,
              rightChild.count == nodeCount,
              !leafValue.isEmpty else {
            throw NSpamWeightsError.invalidModel
        }

        for child in leftChild + rightChild {
            if child >= 0 {
                guard Int(child) < nodeCount else { throw NSpamWeightsError.invalidModel }
            } else {
                guard Int(-child - 1) < leafValue.count else { throw NSpamWeightsError.invalidModel }
            }
        }
        guard splitFeature.allSatisfy({ $0 >= 0 && Int($0) < NSpamFeatures.totalFeatureCount }) else {
            throw NSpamWeightsError.invalidModel
        }

        return Tree(
            splitFeature: splitFeature,
            threshold: threshold,
            decisionType: decisionType,
            leftChild: leftChild,
            rightChild: rightChild,
            leafValue: leafValue
        )
    }

    private static func parseInt32s(_ source: String) throws -> [Int32] {
        try source.split(separator: " ", omittingEmptySubsequences: true).map { value in
            guard let parsed = Int32(value) else { throw NSpamWeightsError.invalidModel }
            return parsed
        }
    }

    private static func parseUInt8s(_ source: String) throws -> [UInt8] {
        try source.split(separator: " ", omittingEmptySubsequences: true).map { value in
            guard let parsed = UInt8(value) else { throw NSpamWeightsError.invalidModel }
            return parsed
        }
    }

    private static func parseDoubles(_ source: String) throws -> [Double] {
        try source.split(separator: " ", omittingEmptySubsequences: true).map { value in
            guard let parsed = Double(value), parsed.isFinite else {
                throw NSpamWeightsError.invalidModel
            }
            return parsed
        }
    }
}

final class NSpamCalibration: @unchecked Sendable {
    let calibX: [Float]
    let calibY: [Float]

    init(calibX: [Float], calibY: [Float]) {
        self.calibX = calibX
        self.calibY = calibY
    }

    static func load(data: Data) throws -> NSpamCalibration {
        let arrays = try parseNpz([UInt8](data))
        guard let calibX = arrays["calib_x"],
              let calibY = arrays["calib_y"],
              !calibX.isEmpty,
              calibX.count == calibY.count,
              zip(calibX, calibX.dropFirst()).allSatisfy({ $0 <= $1 }) else {
            throw NSpamWeightsError.invalidCalibration
        }
        return NSpamCalibration(calibX: calibX, calibY: calibY)
    }

    func score(rawScore: Double) -> Double {
        if rawScore <= Double(calibX[0]) { return Double(calibY[0]) }
        if rawScore >= Double(calibX[calibX.count - 1]) { return Double(calibY[calibY.count - 1]) }

        for index in 0..<(calibX.count - 1)
            where rawScore >= Double(calibX[index]) && rawScore < Double(calibX[index + 1]) {
            let lowerX = Double(calibX[index])
            let upperX = Double(calibX[index + 1])
            let lowerY = Double(calibY[index])
            let upperY = Double(calibY[index + 1])
            let denominator = upperX - lowerX
            if denominator == 0 { return lowerY }
            let interpolation = (rawScore - lowerX) / denominator
            return lowerY + interpolation * (upperY - lowerY)
        }
        return Double(calibY[calibY.count - 1])
    }

    private static func parseNpz(_ bytes: [UInt8]) throws -> [String: [Float]] {
        var arrays: [String: [Float]] = [:]
        var offset = 0

        while offset + 30 <= bytes.count {
            guard read32LE(bytes, at: offset) == 0x04034b50 else { break }
            let compressionMethod = read16LE(bytes, at: offset + 8)
            let compressedSize = Int(read32LE(bytes, at: offset + 18))
            let uncompressedSize = Int(read32LE(bytes, at: offset + 22))
            let filenameLength = Int(read16LE(bytes, at: offset + 26))
            let extraLength = Int(read16LE(bytes, at: offset + 28))
            let filenameStart = offset + 30
            let filenameEnd = filenameStart + filenameLength
            guard filenameEnd <= bytes.count else { throw NSpamWeightsError.invalidCalibration }

            let filename = String(bytes: bytes[filenameStart..<filenameEnd], encoding: .ascii) ?? ""
            let dataStart = filenameEnd + extraLength
            let dataEnd = dataStart + compressedSize
            guard dataStart <= dataEnd, dataEnd <= bytes.count else {
                throw NSpamWeightsError.invalidCalibration
            }

            let entry: [UInt8]
            switch compressionMethod {
            case 0:
                entry = Array(bytes[dataStart..<dataEnd])
            case 8:
                guard let inflated = inflate(
                    Array(bytes[dataStart..<dataEnd]),
                    expectedSize: uncompressedSize
                ) else {
                    throw NSpamWeightsError.invalidCalibration
                }
                entry = inflated
            default:
                throw NSpamWeightsError.invalidCalibration
            }

            if filename.hasSuffix(".npy") {
                arrays[String(filename.dropLast(4))] = try parseNpy(entry)
            }
            offset = dataEnd
        }
        return arrays
    }

    private static func inflate(_ source: [UInt8], expectedSize: Int) -> [UInt8]? {
        guard expectedSize >= 0 else { return nil }
        if expectedSize == 0 { return [] }
        var destination = [UInt8](repeating: 0, count: expectedSize)
        let decodedSize = source.withUnsafeBufferPointer { sourceBuffer in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                guard let sourceAddress = sourceBuffer.baseAddress,
                      let destinationAddress = destinationBuffer.baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationAddress,
                    expectedSize,
                    sourceAddress,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedSize == expectedSize else { return nil }
        return destination
    }

    private static func parseNpy(_ bytes: [UInt8]) throws -> [Float] {
        guard bytes.count >= 10,
              bytes[0] == 0x93,
              bytes[1] == 0x4e,
              bytes[2] == 0x55,
              bytes[3] == 0x4d,
              bytes[4] == 0x50,
              bytes[5] == 0x59 else {
            throw NSpamWeightsError.invalidCalibration
        }

        let major = Int(bytes[6])
        let headerStart = major <= 1 ? 10 : 12
        let headerLength = major <= 1
            ? Int(read16LE(bytes, at: 8))
            : Int(read32LE(bytes, at: 8))
        let dataStart = headerStart + headerLength
        guard dataStart <= bytes.count,
              let header = String(bytes: bytes[headerStart..<dataStart], encoding: .ascii),
              header.contains("'descr': '<f4'") || header.contains("\"descr\": \"<f4\"") else {
            throw NSpamWeightsError.invalidCalibration
        }

        guard let shapeRange = header.range(
            of: #"['\"]shape['\"]\s*:\s*\(([^)]*)\)"#,
            options: .regularExpression
        ) else {
            throw NSpamWeightsError.invalidCalibration
        }
        let shapeSource = String(header[shapeRange])
        guard let open = shapeSource.firstIndex(of: "("),
              let close = shapeSource.firstIndex(of: ")"),
              open < close else {
            throw NSpamWeightsError.invalidCalibration
        }
        let dimensions = shapeSource[shapeSource.index(after: open)..<close]
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let count = dimensions.isEmpty ? 1 : dimensions.reduce(1, *)
        guard count > 0, dataStart + count * 4 <= bytes.count else {
            throw NSpamWeightsError.invalidCalibration
        }

        return (0..<count).map { index in
            let offset = dataStart + index * 4
            return Float(bitPattern: read32LE(bytes, at: offset))
        }
    }

    private static func read16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func read32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
