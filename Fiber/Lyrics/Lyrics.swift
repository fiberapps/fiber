import Foundation

nonisolated struct LyricWord: Hashable, Codable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

nonisolated struct LyricLine: Identifiable, Hashable, Codable, Sendable {
    var id: Int
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    /// Source timing or explicitly marked estimated timing.
    var words: [LyricWord]?
    var preservesWordSpacing: Bool? = nil
}

nonisolated struct Lyrics: Hashable, Codable, Sendable {
    enum Timing: String, Codable, Sendable {
        case word, line, unsynced
    }

    var lines: [LyricLine]
    var timing: Timing
    /// Where the lyrics came from, shown under the last line.
    var source: String
    /// BCP 47 language code when known ("en", "pt", "ko"…).
    var language: String?
    var estimatedWordTiming: Bool? = nil
    var sourceURL: URL? = nil
    var contributor: String? = nil
    var contributorURL: URL? = nil

    /// Index of the line being sung at `time`, or nil before the first line.
    func activeIndex(at time: TimeInterval) -> Int? {
        guard timing != .unsynced else { return nil }
        var low = 0
        var high = lines.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }
}

/// Reads `.lrc` text. Supports plain line timing (`[01:02.50] words`), several
/// stamps on one line, an `[offset:]` tag, and the enhanced word format
/// (`[00:10.00] <00:10.00> one <00:10.40> two`). Text with no stamps comes
/// back as unsynced lyrics; timing is never invented.
nonisolated enum LRCParser {
    static func parse(_ text: String, source: String) -> Lyrics? {
        var offset: TimeInterval = 0
        var timed: [(start: TimeInterval, body: String)] = []
        var plain: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            var rest = Substring(rawLine.trimmingCharacters(in: .whitespaces))
            guard !rest.isEmpty else { continue }
            var stamps: [TimeInterval] = []
            var isMetadata = false

            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = seconds(from: tag) {
                    stamps.append(time)
                } else {
                    if tag.lowercased().hasPrefix("offset:"),
                       let value = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                        // A positive offset means the lyrics should appear earlier.
                        offset = -value / 1000
                    }
                    isMetadata = true
                }
                rest = rest[rest.index(after: close)...]
            }

            let body = rest.trimmingCharacters(in: .whitespaces)
            if stamps.isEmpty {
                if !isMetadata { plain.append(body) }
            } else {
                for stamp in stamps { timed.append((stamp, body)) }
            }
        }

        if timed.isEmpty {
            guard !plain.isEmpty else { return nil }
            let lines = plain.enumerated().map { LyricLine(id: $0.offset, text: $0.element, start: 0, end: 0, words: nil) }
            return Lyrics(lines: lines, timing: .unsynced, source: source, language: nil)
        }

        timed.sort { $0.start < $1.start }
        var lines: [LyricLine] = []
        var anyWords = false

        for (index, entry) in timed.enumerated() {
            let start = max(0, entry.start + offset)
            let nextStart = index + 1 < timed.count ? max(0, timed[index + 1].start + offset) : start + 5
            let (cleanText, words) = splitWords(entry.body, lineStart: start, lineEnd: nextStart, offset: offset)
            // An empty timed line marks an instrumental gap: it ends the previous line.
            guard !cleanText.isEmpty else { continue }
            if words != nil { anyWords = true }
            lines.append(LyricLine(id: lines.count, text: cleanText, start: start, end: nextStart, words: words))
        }

        guard !lines.isEmpty else { return nil }
        return Lyrics(lines: lines, timing: anyWords ? .word : .line, source: source, language: nil)
    }

    private static func seconds(from tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var total: TimeInterval = 0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Pulls `<mm:ss.xx>` word stamps out of a line body.
    private static func splitWords(
        _ body: String, lineStart: TimeInterval, lineEnd: TimeInterval, offset: TimeInterval
    ) -> (String, [LyricWord]?) {
        guard body.contains("<") else { return (body, nil) }
        var words: [LyricWord] = []
        var pendingStart: TimeInterval?
        var rest = Substring(body)

        while !rest.isEmpty {
            if rest.hasPrefix("<"), let close = rest.firstIndex(of: ">"),
               let time = seconds(from: rest[rest.index(after: rest.startIndex)..<close]) {
                let stamp = max(0, time + offset)
                if !words.isEmpty, words[words.count - 1].end < 0 { words[words.count - 1].end = stamp }
                pendingStart = stamp
                rest = rest[rest.index(after: close)...]
                continue
            }
            // Search past the first character so a stray "<" is kept as text
            // and the loop always moves forward.
            let next = rest[rest.index(after: rest.startIndex)...].firstIndex(of: "<") ?? rest.endIndex
            let chunk = rest[..<next].trimmingCharacters(in: .whitespaces)
            if !chunk.isEmpty {
                words.append(LyricWord(text: chunk, start: pendingStart ?? lineStart, end: -1))
                pendingStart = nil
            }
            rest = rest[next...]
        }

        guard !words.isEmpty else { return ("", nil) }
        if words[words.count - 1].end < 0 { words[words.count - 1].end = max(lineEnd, words[words.count - 1].start) }
        return (words.map(\.text).joined(separator: " "), words)
    }
}
