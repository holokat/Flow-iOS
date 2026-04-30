import Foundation

enum NostrLongFormArticleKind {
    static let article = 30_023
}

private struct LongFormArticleTagMetadata: Hashable, Sendable {
    let title: String?
    let summary: String?
    let imageURL: URL?
    let identifier: String?
    let publishedAt: Int
    let tags: [String]

    init(event: NostrEvent) {
        var title: String?
        var summary: String?
        var imageURL: URL?
        var identifier: String?
        var tags: [String] = []
        var seenTags = Set<String>()
        var publishedAt = event.createdAt

        for tag in event.tags {
            guard let name = tag.first?.lowercased() else { continue }

            switch name {
            case "title":
                if let value = Self.normalizedText(from: tag, at: 1) {
                    title = value
                }
            case "summary":
                if let value = Self.normalizedText(from: tag, at: 1) {
                    summary = value
                }
            case "image":
                if let value = Self.normalizedHTTPURL(from: tag, at: 1) {
                    imageURL = value
                }
            case "d":
                if let value = Self.normalizedText(from: tag, at: 1) {
                    identifier = value
                }
            case "published_at":
                if let value = Self.normalizedText(from: tag, at: 1),
                   let timestamp = Int(value),
                   timestamp > 0 {
                    publishedAt = timestamp
                }
            case "t":
                guard tags.count < 6,
                      let value = Self.normalizedText(from: tag, at: 1) else {
                    continue
                }
                let normalizedTag = NostrEvent.normalizedHashtagValue(value)
                guard !normalizedTag.isEmpty,
                      seenTags.insert(normalizedTag).inserted else {
                    continue
                }
                tags.append(normalizedTag)
            default:
                continue
            }
        }

        self.title = title
        self.summary = summary
        self.imageURL = imageURL
        self.identifier = identifier
        self.publishedAt = publishedAt
        self.tags = tags
    }

    private static func normalizedText(from tag: [String], at index: Int) -> String? {
        guard tag.indices.contains(index) else { return nil }
        let value = tag[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func normalizedHTTPURL(from tag: [String], at index: Int) -> URL? {
        guard let value = normalizedText(from: tag, at: index),
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}

struct NostrLongFormArticleIndexMetadata: Hashable, Sendable {
    let identifier: String?
    let publishedAt: Int

    init?(event: NostrEvent) {
        guard event.kind == NostrLongFormArticleKind.article else {
            return nil
        }

        let tagMetadata = LongFormArticleTagMetadata(event: event)
        self.identifier = tagMetadata.identifier
        self.publishedAt = tagMetadata.publishedAt
    }
}

struct NostrLongFormArticleMetadata: Hashable, Sendable {
    let title: String
    let summary: String?
    let imageURL: URL?
    let imageIsContentFallback: Bool
    let identifier: String?
    let publishedAt: Int
    let tags: [String]
    let wordCount: Int

    init?(event: NostrEvent) {
        guard event.kind == NostrLongFormArticleKind.article else {
            return nil
        }

        let tagMetadata = LongFormArticleTagMetadata(event: event)
        let resolvedTitle = tagMetadata.title ?? tagMetadata.identifier ?? "Untitled"
        let contentImageURL = tagMetadata.imageURL == nil
            ? LongFormArticleMarkdownParser.firstImageURL(in: event.content)
            : nil
        let wordCount = Self.wordCount(in: event.content)

        self.title = resolvedTitle
        self.summary = tagMetadata.summary
        self.imageURL = tagMetadata.imageURL ?? contentImageURL
        self.imageIsContentFallback = tagMetadata.imageURL == nil && contentImageURL != nil
        self.identifier = tagMetadata.identifier
        self.publishedAt = tagMetadata.publishedAt
        self.tags = tagMetadata.tags
        self.wordCount = wordCount
    }

    var publishedDate: Date {
        Date(timeIntervalSince1970: TimeInterval(publishedAt))
    }

    var readingTimeMinutes: Int {
        max(1, Int(round(Double(max(wordCount, 1)) / 220)))
    }

    private static func wordCount(in markdown: String) -> Int {
        markdown
            .split(whereSeparator: \.isWhitespace)
            .count
    }
}

enum LongFormArticleBlock: Hashable, Sendable {
    case heading(level: Int, markdown: String)
    case paragraph(markdown: String)
    case unorderedList(items: [String])
    case orderedList(start: Int, items: [String])
    case blockquote(markdown: String)
    case codeBlock(language: String?, code: String)
    case image(url: URL, alt: String?)
    case divider
}

enum LongFormArticleMarkdownParser {
    static func firstImageURL(in markdown: String) -> URL? {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if case .image(let url, _) = standaloneImage(in: trimmed) {
                return url
            }
        }

        return nil
    }

    static func parseBlocks(from markdown: String) -> [LongFormArticleBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [LongFormArticleBlock] = []
        var paragraphLines: [String] = []
        var index = 0

        func flushParagraph() {
            let joined = paragraphLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty else {
                paragraphLines.removeAll(keepingCapacity: true)
                return
            }
            blocks.append(.paragraph(markdown: joined))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let codeFence = codeFenceLanguage(in: trimmed) {
                flushParagraph()
                index += 1

                var codeLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index]
                    if candidate.trimmingCharacters(in: .whitespaces) == "```" {
                        index += 1
                        break
                    }
                    codeLines.append(candidate)
                    index += 1
                }

                blocks.append(
                    .codeBlock(
                        language: codeFence.isEmpty ? nil : codeFence,
                        code: codeLines.joined(separator: "\n")
                    )
                )
                continue
            }

            if let heading = heading(in: line) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if let imageBlock = standaloneImage(in: trimmed) {
                flushParagraph()
                blocks.append(imageBlock)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []

                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    let withoutMarker = candidate
                        .dropFirst()
                        .drop(while: { $0 == " " })
                    quoteLines.append(String(withoutMarker))
                    index += 1
                }

                let markdown = quoteLines
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !markdown.isEmpty {
                    blocks.append(.blockquote(markdown: markdown))
                }
                continue
            }

            if let orderedStart = orderedListIndex(in: line) {
                flushParagraph()
                let start = orderedStart.number
                var items: [String] = []
                var currentIndex = index

                while currentIndex < lines.count,
                      let orderedMatch = orderedListIndex(in: lines[currentIndex]) {
                    items.append(orderedMatch.text)
                    currentIndex += 1
                }

                if !items.isEmpty {
                    blocks.append(.orderedList(start: start, items: items))
                }
                index = currentIndex
                continue
            }

            if let unorderedItem = unorderedListText(in: line) {
                flushParagraph()
                var items: [String] = [unorderedItem]
                var currentIndex = index + 1

                while currentIndex < lines.count,
                      let nextItem = unorderedListText(in: lines[currentIndex]) {
                    items.append(nextItem)
                    currentIndex += 1
                }

                blocks.append(.unorderedList(items: items))
                index = currentIndex
                continue
            }

            paragraphLines.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func codeFenceLanguage(in trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("```") else { return nil }
        return trimmedLine.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func heading(in line: String) -> LongFormArticleBlock? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }

        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }

        let text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        return .heading(level: level, markdown: text)
    }

    private static func isDivider(_ trimmedLine: String) -> Bool {
        let compact = trimmedLine.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return false }
        return compact.allSatisfy { $0 == "-" } ||
            compact.allSatisfy { $0 == "*" } ||
            compact.allSatisfy { $0 == "_" }
    }

    private static func standaloneImage(in trimmedLine: String) -> LongFormArticleBlock? {
        guard trimmedLine.hasPrefix("!["),
              let altEndIndex = trimmedLine.firstIndex(of: "]"),
              trimmedLine[altEndIndex...].hasPrefix("]("),
              trimmedLine.hasSuffix(")") else {
            return nil
        }

        let altStartIndex = trimmedLine.index(trimmedLine.startIndex, offsetBy: 2)
        let alt = String(trimmedLine[altStartIndex..<altEndIndex])
        let urlStartIndex = trimmedLine.index(altEndIndex, offsetBy: 2)
        let urlEndIndex = trimmedLine.index(before: trimmedLine.endIndex)
        let rawURL = trimmedLine[urlStartIndex..<urlEndIndex]
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""

        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        var normalizedAlt = alt.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalizedAlt.hasPrefix("[") {
            normalizedAlt.removeFirst()
        }
        return .image(url: url, alt: normalizedAlt.isEmpty ? nil : normalizedAlt)
    }

    private static func orderedListIndex(in line: String) -> (number: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty,
              let number = Int(digits),
              digits.count < trimmed.count else {
            return nil
        }

        let separatorIndex = trimmed.index(trimmed.startIndex, offsetBy: digits.count)
        guard trimmed[separatorIndex] == "." else { return nil }

        let textStartIndex = trimmed.index(after: separatorIndex)
        let text = trimmed[textStartIndex...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        return (number, text)
    }

    private static func unorderedListText(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 2,
              let marker = trimmed.first,
              marker == "-" || marker == "*" || marker == "+" else {
            return nil
        }

        let nextIndex = trimmed.index(after: trimmed.startIndex)
        guard trimmed[nextIndex] == " " else { return nil }

        let text = trimmed[trimmed.index(after: nextIndex)...].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}

extension NostrEvent {
    var longFormArticleIndexMetadata: NostrLongFormArticleIndexMetadata? {
        NostrLongFormArticleIndexMetadata(event: self)
    }

    var longFormArticleMetadata: NostrLongFormArticleMetadata? {
        NostrLongFormArticleMetadata(event: self)
    }
}
