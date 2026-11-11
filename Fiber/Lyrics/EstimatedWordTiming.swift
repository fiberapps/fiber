import Foundation

extension Lyrics {
    /// Visual fallback only. Keep the source timing classification and mark estimates.
    nonisolated func fillingMissingWordTiming() -> Lyrics {
        guard timing != .unsynced else { return self }
        var result = self
        var estimated = false
        for index in result.lines.indices {
            let line = result.lines[index]
            guard line.words?.isEmpty != false, line.end > line.start else { continue }
            let text = line.text
            let tokens: [String]
            if text.contains(where: \.isWhitespace) {
                let regex = try! NSRegularExpression(pattern: #"\S+\s*"#)
                tokens = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                    Range($0.range, in: text).map { String(text[$0]) }
                }
            } else {
                // Keep a single Latin word whole; split unspaced CJK into graphemes.
                let cjk = text.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
                tokens = cjk ? text.map(String.init) : [text]
            }
            guard !tokens.isEmpty else { continue }
            let weights = tokens.map { max(1, sqrt(Double($0.filter { !$0.isWhitespace }.count))) }
            let total = weights.reduce(0, +)
            // Avoid stretching a short phrase across a long instrumental gap.
            let span = min(line.end - line.start, max(1.2, Double(tokens.count) * 0.7))
            var cursor = line.start
            result.lines[index].words = tokens.enumerated().map { i, token in
                let end = cursor + span * weights[i] / total
                defer { cursor = end }
                return LyricWord(text: token, start: cursor, end: end)
            }
            result.lines[index].preservesWordSpacing = true
            estimated = true
        }
        if estimated { result.estimatedWordTiming = true }
        return result
    }
}
