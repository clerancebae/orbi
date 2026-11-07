import Foundation

enum DurationText {
    /// "45m", "1h", "1h 05m".
    static func minutes(_ minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m)m" }
        let h = m / 60, rest = m % 60
        return rest == 0 ? "\(h)h" : "\(h)h \(String(format: "%02d", rest))m"
    }

    /// Whole minutes left, rounded up (59s left shows "1m").
    static func ceilMinutes(_ seconds: Int) -> Int { (max(0, seconds) + 59) / 60 }

    /// Whole minutes elapsed, rounded down.
    static func floorMinutes(_ seconds: Int) -> Int { max(0, seconds) / 60 }
}

extension String {
    /// Truncates to `limit` characters, appending "…" when cut.
    func truncated(to limit: Int) -> String {
        count <= limit ? self : String(prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
