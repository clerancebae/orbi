import Foundation

/// Parses quick-add text like "Write docs 25m" into a title and an optional estimate.
/// Only a trailing duration token counts: `25m`, `25min`, `2h`, `1h30m`, `1h30`.
/// A bare number ("Call 911") is never treated as an estimate.
/// A `#project` word anywhere links the task to an agent project ("Fix login #api 25m").
enum TaskInputParser {
    struct Result: Equatable {
        var title: String
        var estimatedMinutes: Int?
        var project: String? = nil
    }

    static func parse(_ raw: String) -> Result? {
        let (rest, project) = extractProject(raw)
        guard var result = parseTitle(rest) else { return nil }
        result.project = project
        return result
    }

    /// Removes `#tag` words (letters, digits, `.`, `_`, `-`, at least one letter); the last one wins.
    /// "C# review" and "#1" stay as they are.
    static func extractProject(_ raw: String) -> (text: String, project: String?) {
        var project: String?
        var words: [Substring] = []
        for word in raw.split(separator: " ", omittingEmptySubsequences: true) {
            let tag = word.dropFirst()
            if word.first == "#", !tag.isEmpty, tag.count <= 120, tag.contains(where: \.isLetter),
               tag.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) {
                project = String(tag)
            } else {
                words.append(word)
            }
        }
        return (words.joined(separator: " "), project)
    }

    private static func parseTitle(_ raw: String) -> Result? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        guard let spaceIndex = text.lastIndex(where: \.isWhitespace) else {
            return Result(title: text, estimatedMinutes: nil)
        }
        let token = text[text.index(after: spaceIndex)...].lowercased()
        let title = text[..<spaceIndex].trimmingCharacters(in: .whitespaces)

        guard !title.isEmpty, let minutes = minutes(from: token) else {
            return Result(title: text, estimatedMinutes: nil)
        }
        return Result(title: title, estimatedMinutes: minutes)
    }

    /// Returns minutes for a duration token, or nil if it isn't one (or is 0 / over 24h).
    static func minutes(from token: String) -> Int? {
        let pattern = /^(?:(\d{1,2})h)?(?:(\d{1,4})(?:m|min)?)?$/
        guard let match = token.wholeMatch(of: pattern) else { return nil }
        let hours = match.1.flatMap { Int($0) }
        let mins = match.2.flatMap { Int($0) }
        // Require a unit: "25" alone is not a duration, but "1h30" is.
        let hasUnit = token.contains("h") || token.hasSuffix("m") || token.hasSuffix("min")
        guard hasUnit, hours != nil || mins != nil else { return nil }
        let total = (hours ?? 0) * 60 + (mins ?? 0)
        guard total > 0, total <= 24 * 60 else { return nil }
        return total
    }
}
