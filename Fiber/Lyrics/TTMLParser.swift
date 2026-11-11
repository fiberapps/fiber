import Foundation

/// Reads absolute TTML clock times and timed leaf spans, preserving syllable spacing.
nonisolated final class TTMLParser: NSObject, XMLParserDelegate {
    private final class Node {
        var name: String
        var attributes: [String: String]
        var children: [Node] = []
        var text = ""
        init(_ name: String, _ attributes: [String: String] = [:]) {
            self.name = name; self.attributes = attributes
        }
    }
    private var stack: [Node] = []
    private var paragraphs: [Node] = []

    static func parse(_ text: String, source: String) -> Lyrics? {
        let delegate = TTMLParser()
        let parser = XMLParser(data: Data(text.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        var lines: [LyricLine] = []
        for p in delegate.paragraphs {
            guard let start = seconds(p.attributes["begin"]), let end = seconds(p.attributes["end"]),
                  end > start else { continue }
            var words: [LyricWord] = []
            var fullText = ""
            func walk(_ node: Node, inherited: (Double, Double)?) {
                let role = node.attributes["ttm:role"] ?? node.attributes["role"] ?? ""
                if role == "x-translation" || role == "x-roman" { return }
                let timing: (Double, Double)? = {
                    if let a = seconds(node.attributes["begin"]), let b = seconds(node.attributes["end"]), b > a {
                        return (a, b)
                    }
                    return inherited
                }()
                if node.name == "#text" {
                    fullText += node.text
                    if let timing, !node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        words.append(LyricWord(text: node.text, start: timing.0, end: timing.1))
                    } else if !words.isEmpty {
                        words[words.count - 1].text += node.text
                    }
                } else {
                    for child in node.children { walk(child, inherited: timing) }
                }
            }
            // A paragraph's own timing is line timing, never word timing.
            for child in p.children { walk(child, inherited: nil) }
            let clean = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            // Only use timed runs when they account for all non-whitespace text.
            let compact: (String) -> String = { $0.filter { !$0.isWhitespace } }
            let complete = !words.isEmpty && compact(words.map(\.text).joined()) == compact(clean)
            lines.append(LyricLine(id: 0, text: clean, start: start, end: end,
                                  words: complete ? words : nil, preservesWordSpacing: true))
        }
        lines.sort { $0.start < $1.start }
        for i in lines.indices { lines[i].id = i }
        guard !lines.isEmpty else { return nil }
        return Lyrics(lines: lines, timing: lines.contains { $0.words != nil } ? .word : .line,
                      source: source, language: nil)
    }

    static func seconds(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        if raw.hasSuffix("ms") { return Double(raw.dropLast(2)).map { $0 / 1000 } }
        if raw.hasSuffix("s") { return Double(raw.dropLast()) }
        let parts = raw.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var result = 0.0
        for part in parts {
            guard let value = Double(part), value.isFinite, value >= 0 else { return nil }
            result = result * 60 + value
        }
        return result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let node = Node(elementName.components(separatedBy: ":").last ?? elementName, attributeDict)
        stack.last?.children.append(node)
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let parent = stack.last else { return }
        if let last = parent.children.last, last.name == "#text" { last.text += string }
        else { let node = Node("#text"); node.text = string; parent.children.append(node) }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if let node = stack.popLast(), node.name == "p" { paragraphs.append(node) }
    }
}
