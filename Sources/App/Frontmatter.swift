import Foundation

/// Minimal YAML-frontmatter helper. We keep the block as opaque raw text so
/// any unknown keys (tags, aliases, custom tool fields, nested maps) round-trip
/// verbatim. We only reach in to pull out the values the app actually uses —
/// currently just `title:`.
enum Frontmatter {

    /// Split a raw markdown document into `(frontmatter, body)`.
    /// - Frontmatter is the text between a leading `---` line and the next
    ///   `---` line, exclusive on both sides.
    /// - Body is everything after the closing `---`, with at most one blank
    ///   separator line consumed.
    /// - When there's no leading `---`, or no matching closing `---`,
    ///   returns `(nil, source)` untouched.
    static func split(_ source: String) -> (frontmatter: String?, body: String) {
        // Normalize CRLF so the line-based logic below is uniform. We emit LF
        // on assemble either way — macOS convention.
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = parts.first,
              first.trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, source)
        }
        // Find the matching closing marker.
        var closeIndex: Int?
        for i in 1..<parts.count {
            if parts[i].trimmingCharacters(in: .whitespaces) == "---" {
                closeIndex = i
                break
            }
        }
        guard let close = closeIndex else { return (nil, source) }

        let fm = parts[1..<close].joined(separator: "\n")

        // Skip one blank line after the closing marker if there is one.
        var bodyStart = close + 1
        if bodyStart < parts.count, parts[bodyStart].trimmingCharacters(in: .whitespaces).isEmpty {
            bodyStart += 1
        }
        let body: String
        if bodyStart >= parts.count { body = "" }
        else { body = parts[bodyStart..<parts.count].joined(separator: "\n") }

        return (fm, body)
    }

    /// Recombine frontmatter + body into a full document. Empty or nil
    /// frontmatter returns the body untouched (no `---` block written).
    static func assemble(frontmatter: String?, body: String) -> String {
        guard let fm = frontmatter,
              !fm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return body
        }
        // Trim any trailing newlines from the frontmatter chunk so we emit
        // a canonical `---\n<fm>\n---\n\n<body>` layout regardless of what
        // the caller passed in.
        var trimmed = fm
        while trimmed.hasSuffix("\n") { trimmed.removeLast() }
        return "---\n\(trimmed)\n---\n\n\(body)"
    }

    /// Read `title:` out of a raw frontmatter block. Handles unquoted,
    /// double-quoted, and single-quoted forms. Returns nil when the key is
    /// missing or empty. Never throws — malformed YAML just yields nil.
    static func title(in frontmatter: String) -> String? {
        for rawLine in frontmatter.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            // Only match top-level `title:` (no leading indent — indented is
            // a nested map key, not our title).
            guard line.first != " ", line.first != "\t" else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "title" else { continue }
            let raw = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            return unquote(raw)
        }
        return nil
    }

    /// Rewrite the top-level `title:` line inside `frontmatter` to `newTitle`.
    /// If no `title:` line exists, one is inserted at the very top. Unrelated
    /// keys, comments, and blank lines are preserved verbatim.
    ///
    /// Passing `nil` frontmatter treats it as empty (so this becomes "create
    /// a frontmatter block with just `title:`").
    static func settingTitle(_ newTitle: String, in frontmatter: String?) -> String {
        let value = encodeScalar(newTitle)
        let source = frontmatter ?? ""
        var lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var replaced = false
        for i in lines.indices {
            let line = lines[i]
            // Skip indented lines — they belong to a nested map, not our title.
            guard line.first != " ", line.first != "\t" else { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if key == "title" {
                lines[i] = "title: \(value)"
                replaced = true
                break
            }
        }
        if !replaced {
            // Insert at the top so it's easy to spot.
            if lines == [""] { lines = ["title: \(value)"] }
            else { lines.insert("title: \(value)", at: 0) }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Value parsing

    /// Encode a string as a YAML scalar. Uses the plain (unquoted) form when
    /// the value is unambiguous; falls back to double-quoted with backslash
    /// escapes otherwise. Conservative — false positives (needless quoting)
    /// beat false negatives (a broken frontmatter).
    private static func encodeScalar(_ s: String) -> String {
        let indicators: Set<Character> = [
            "-", "?", ":", ",", "[", "]", "{", "}", "#", "&", "*",
            "!", "|", ">", "'", "\"", "%", "@", "`",
        ]
        let firstChar = s.first
        let needsQuote =
            s.isEmpty
            || indicators.contains(firstChar ?? " ")
            || (firstChar?.isWhitespace ?? false)
            || (s.last?.isWhitespace ?? false)
            || s.contains(": ")                 // reads as a nested value otherwise
            || s.contains(" #")                 // starts an inline comment otherwise
            || s.contains(where: { $0.isNewline || $0 == "\t" || $0 == "\"" || $0 == "\\" })
        if !needsQuote { return s }
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Strip surrounding quotes and drop trailing YAML comments. Returns nil
    /// for empty values.
    private static func unquote(_ s: String) -> String? {
        if s.isEmpty { return nil }
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            let inner = s.dropFirst().dropLast()
            return String(inner)
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if s.hasPrefix("'") && s.hasSuffix("'") && s.count >= 2 {
            let inner = s.dropFirst().dropLast()
            return String(inner).replacingOccurrences(of: "''", with: "'")
        }
        // Drop trailing YAML comment (` # ...`), but only when the `#` is
        // preceded by whitespace so URLs like http://x#y aren't truncated.
        var out = s
        if let hashIdx = out.firstIndex(of: "#"),
           hashIdx > out.startIndex,
           out[out.index(before: hashIdx)].isWhitespace {
            out = String(out[..<hashIdx]).trimmingCharacters(in: .whitespaces)
        }
        return out.isEmpty ? nil : out
    }
}
