import Foundation

/// Which day a task is planned for.
enum PlannedDay: Equatable, Sendable {
    case today
    case tomorrow
    case date(year: Int, month: Int, day: Int)

    func resolve(now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today:
            return today
        case .tomorrow:
            return calendar.date(byAdding: .day, value: 1, to: today) ?? today
        case let .date(year, month, day):
            guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return today }
            return max(calendar.startOfDay(for: date), today)  // past dates land on today
        }
    }
}

enum OrbiAction: Equatable, Sendable {
    case waterAdd
    case waterUndo
    case taskStartNext
    case taskComplete
    case taskAdd(title: String, minutes: Int?, day: PlannedDay)
    case readingSave(url: URL, title: String?)
    case readingOpenNext
    case capture
    /// Short info bubble (e.g. "Claude finished"), closes by itself.
    case notify(title: String, message: String?)
}

/// Parses `orbi://` URLs into actions. Pure — no side effects — so it's fully unit tested.
enum URLRouter {
    enum RouteError: Error, Equatable {
        case notOrbi
        case unknownRoute(String)
        case missingParameter(String)
        case invalidParameter(String)
    }

    static let maxTitleLength = 300

    static func parse(_ url: URL) -> Result<OrbiAction, RouteError> {
        guard url.scheme?.lowercased() == "orbi" else { return .failure(.notOrbi) }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.unknownRoute(url.absoluteString))
        }
        let host = (components.host ?? "").lowercased()
        let path = components.path.split(separator: "/").map { $0.lowercased() }
        let route = ([host] + path).filter { !$0.isEmpty }.joined(separator: "/")
        let query = queryDictionary(components)

        switch route {
        case "water/add": return .success(.waterAdd)
        case "water/undo": return .success(.waterUndo)
        case "task/start-next": return .success(.taskStartNext)
        case "task/complete": return .success(.taskComplete)
        case "reading/open-next": return .success(.readingOpenNext)
        case "capture": return .success(.capture)
        case "task/add": return parseTaskAdd(query)
        case "reading/save": return parseReadingSave(query)
        case "notify": return parseNotify(query)
        default: return .failure(.unknownRoute(route))
        }
    }

    private static func parseTaskAdd(_ query: [String: String]) -> Result<OrbiAction, RouteError> {
        guard let rawTitle = query["title"]?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty else {
            return .failure(.missingParameter("title"))
        }
        var title = String(rawTitle.prefix(maxTitleLength))
        var minutes: Int?

        if let rawMinutes = query["min"], !rawMinutes.isEmpty {
            guard let value = Int(rawMinutes), (1...1440).contains(value) else {
                return .failure(.invalidParameter("min"))
            }
            minutes = value
        } else if let parsed = TaskInputParser.parse(title) {
            // Allow "title=Write docs 25m" too.
            title = parsed.title
            minutes = parsed.estimatedMinutes
        }

        var day = PlannedDay.today
        if let rawDate = query["date"]?.lowercased(), !rawDate.isEmpty {
            guard let parsed = parseDay(rawDate) else { return .failure(.invalidParameter("date")) }
            day = parsed
        }
        return .success(.taskAdd(title: title, minutes: minutes, day: day))
    }

    private static func parseReadingSave(_ query: [String: String]) -> Result<OrbiAction, RouteError> {
        guard let raw = query["url"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .failure(.missingParameter("url"))
        }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else {
            return .failure(.invalidParameter("url"))
        }
        let title = query["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty.map { String($0.prefix(maxTitleLength)) }
        return .success(.readingSave(url: url, title: title))
    }

    static let maxNotifyLength = 120

    private static func parseNotify(_ query: [String: String]) -> Result<OrbiAction, RouteError> {
        let title = query["title"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let message = query["message"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard title != nil || message != nil else { return .failure(.missingParameter("title")) }
        return .success(.notify(title: String((title ?? "Orbi").prefix(maxNotifyLength)),
                                message: message.map { String($0.prefix(maxNotifyLength * 2)) }))
    }

    /// "today", "tomorrow" or "YYYY-MM-DD".
    static func parseDay(_ raw: String) -> PlannedDay? {
        switch raw {
        case "today": return .today
        case "tomorrow": return .tomorrow
        default:
            guard let match = raw.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})/),
                  let y = Int(match.1), let m = Int(match.2), let d = Int(match.3),
                  (1...12).contains(m), (1...31).contains(d) else { return nil }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .gmt
            // Reject impossible dates like 2026-02-30.
            guard let date = cal.date(from: DateComponents(year: y, month: m, day: d)),
                  cal.component(.day, from: date) == d else { return nil }
            return .date(year: y, month: m, day: d)
        }
    }

    /// Query items, with `+` treated as a space (form encoding); `%2B` stays a literal plus.
    private static func queryDictionary(_ components: URLComponents) -> [String: String] {
        var result: [String: String] = [:]
        for item in components.percentEncodedQueryItems ?? [] {
            let value = item.value?.replacingOccurrences(of: "+", with: "%20").removingPercentEncoding
            if result[item.name.lowercased()] == nil { result[item.name.lowercased()] = value ?? "" }
        }
        return result
    }
}
