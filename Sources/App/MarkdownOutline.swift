import Foundation

/// One heading in the document, produced by `MarkdownOutline.headings(in:)`.
///
/// `index` is the heading's zero-based position among all headings in the
/// same document. The JS side uses it to look up the corresponding `<h1>`…
/// `<h6>` DOM node and scroll it into view — matching by index is stable
/// even when heading text repeats.
struct OutlineEntry: Identifiable, Hashable {
    let level: Int          // 1…6
    let text: String
    let index: Int
    var id: Int { index }
}

/// Line-based ATX heading extractor. Only `#`-style headings are recognized;
/// fenced code blocks (```` ``` ```` / ` ~~~ `) are skipped so headings
/// inside sample code don't leak into the outline. Setext (`===` / `---`
/// underline) headings are intentionally not parsed — vanishingly rare in
/// the files we edit and cheap to add later if needed.
enum MarkdownOutline {

    static func headings(in body: String) -> [OutlineEntry] {
        var out: [OutlineEntry] = []
        var inCodeBlock = false
        var runningIndex = 0
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let stripped = rawLine.drop { $0 == " " }   // leading spaces
            // Fenced-code fence: at most 3 leading spaces + 3+ ` or ~
            let leadingSpaces = rawLine.count - stripped.count
            if leadingSpaces < 4,
               (stripped.hasPrefix("```") || stripped.hasPrefix("~~~")) {
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock { continue }
            if let (level, text) = parseATX(rawLine) {
                out.append(OutlineEntry(level: level, text: text, index: runningIndex))
                runningIndex += 1
            }
        }
        return out
    }

    private static func parseATX(_ line: Substring) -> (level: Int, text: String)? {
        var i = line.startIndex
        var leadingSpaces = 0
        while i < line.endIndex, line[i] == " ", leadingSpaces < 4 {
            i = line.index(after: i)
            leadingSpaces += 1
        }
        // 4-space indent turns the line into a code block per CommonMark.
        if leadingSpaces >= 4 { return nil }
        var level = 0
        while i < line.endIndex, line[i] == "#", level < 7 {
            i = line.index(after: i)
            level += 1
        }
        guard (1...6).contains(level) else { return nil }
        // ATX requires the run of `#` to be followed by whitespace or EOL.
        if i < line.endIndex, line[i] != " ", line[i] != "\t" { return nil }
        var text = String(line[i...])
            .trimmingCharacters(in: .whitespaces)
        // Trailing `#`s in a closed ATX header (`## foo ##`).
        while text.hasSuffix("#") { text = String(text.dropLast()) }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }
}
