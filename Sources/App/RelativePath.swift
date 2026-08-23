import Foundation

enum RelativePath {

    /// Return `target`'s path relative to the directory containing `source`.
    /// Each component is percent-encoded so the result is safe to drop into
    /// a markdown link's URL slot.
    ///
    /// Examples (assuming a workspace under `/notes/`):
    ///   source = /notes/a.md,          target = /notes/b.md          → "b.md"
    ///   source = /notes/a.md,          target = /notes/sub/c.md      → "sub/c.md"
    ///   source = /notes/sub/c.md,      target = /notes/a.md          → "../a.md"
    ///   source = /notes/x/y/z.md,      target = /notes/a.md          → "../../a.md"
    ///   source = /notes/a.md,          target = /notes/w space.md    → "w%20space.md"
    static func relative(from source: URL, to target: URL) -> String {
        let fromComponents = source.standardizedFileURL
            .deletingLastPathComponent()
            .pathComponents
        let toComponents = target.standardizedFileURL.pathComponents

        var common = 0
        while common < fromComponents.count,
              common < toComponents.count,
              fromComponents[common] == toComponents[common] {
            common += 1
        }

        let ups = Array(repeating: "..", count: fromComponents.count - common)
        let downs = Array(toComponents[common..<toComponents.count])
        let parts = ups + downs
        if parts.isEmpty { return "" }

        // Percent-encode each component individually so path separators stay
        // as `/`. `urlPathAllowed` covers spaces + unicode + most punctuation
        // that appears in filenames.
        return parts
            .map { component in
                component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
                    ?? component
            }
            .joined(separator: "/")
    }
}
