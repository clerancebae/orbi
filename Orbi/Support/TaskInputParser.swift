import Foundation

/// Parses quick-add text like "Write docs 25m" into a title and an optional estimate.
/// Only a trailing duration token counts: `25m`, `25min`, `2h`, `1h30m`, `1h30`.
/// A bare number ("Call 911") is never treated as an estimate.
enum TaskInputParser {
    struct Result: Equatable {
        var title: String
        var estimatedMinutes: Int?
    }

    static func parse(_ raw: String) -> Result? {
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
