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
    /// Info bubble (e.g. "Claude finished"). Closes by itself unless `sticky`
    /// (e.g. "Claude needs you"), which stays until closed or dismissed.
    case notify(title: String, message: String?, sticky: Bool, app: String? = nil)
    /// Closes a sticky notify bubble (the agent continued). No-op otherwise.
    case notifyDismiss
    /// An AI agent asks the user something (permission, or "reply?" after a turn). The answer
    /// is written to `answers/<id>.json` for the waiting hook to pick up.
    case ask(AgentAsk)
    /// The question was answered elsewhere (e.g. in the terminal): close it without answering.
    case askCancel(id: String)
    /// Silent entry in the Agents list (a finished turn that showed no bubble).
    case agentLog(title: String, subtitle: String?, detail: String?, context: AgentContext = .none)
    /// An agent session started a turn (menu bar shows it as running).
    case agentStart(AgentContext)
    /// The session's turn ended or it went idle (e.g. interrupted).
    case agentStop(session: String)
    /// Claude plan limits from the status line hook: % used of the 5-hour and weekly windows.
    case usage(UsageLimits)
}

/// Claude.ai plan limits as Claude Code reports them (`rate_limits` in the status line input).
struct UsageLimits: Codable, Equatable, Sendable {
    /// % used of the 5-hour window, and when it resets.
    var fiveHour: Int?
    var fiveHourReset: Date?
    /// % used of the weekly window, and when it resets.
    var week: Int?
    var weekReset: Date?
    /// When Orbi received it.
    var updated: Date
}

/// Who is talking: which agent session, project and host app (for "go to project").
struct AgentContext: Equatable, Sendable {
    var session: String?
    var agent: String?
    var project: String?
    /// Bundle id of the terminal / IDE the agent runs in.
    var app: String?
    /// Length of the finished turn, for the daily summary.
    var seconds: Int?
    /// Tokens the finished turn used (input + cache writes + output), for the daily summary.
    var tokens: Int? = nil

    static let none = AgentContext()
}

struct AgentAsk: Equatable {
    enum Kind: String { case permission, reply }
    let id: String
    let kind: Kind
    let title: String
    let message: String?
    /// The command / file for a permission, or the agent's last message for a reply.
    let detail: String?
    var context: AgentContext = .none
    /// The rule Claude suggests for "don't ask again" (e.g. `Bash(npm test:*)`); shows an Always button.
    var alwaysRule: String? = nil
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
        case "notify/dismiss": return .success(.notifyDismiss)
        case "ask": return parseAsk(query)
        case "agent/start":
            let context = parseContext(query)
            guard context.session != nil else { return .failure(.invalidParameter("session")) }
            return .success(.agentStart(context))
        case "agent/stop":
            guard let session = parseContext(query).session else { return .failure(.invalidParameter("session")) }
            return .success(.agentStop(session: session))
        case "agent/log":
            guard let title = query["title"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                return .failure(.missingParameter("title"))
            }
            return .success(.agentLog(
                title: String(title.prefix(maxNotifyLength)),
                subtitle: query["subtitle"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    .map { String($0.prefix(maxNotifyLength * 2)) },
                detail: query["detail"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    .map { String($0.prefix(maxAskDetailLength)) },
                context: parseContext(query)))
        case "usage": return parseUsage(query)
        case "ask/cancel":
            guard let id = query["id"], isValidAskID(id) else { return .failure(.invalidParameter("id")) }
            return .success(.askCancel(id: id))
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
        let sticky = ["1", "true", "yes"].contains(query["sticky"]?.lowercased() ?? "")
        return .success(.notify(title: String((title ?? "Orbi").prefix(maxNotifyLength)),
                                message: message.map { String($0.prefix(maxNotifyLength * 2)) },
                                sticky: sticky, app: parseContext(query).app))
    }

    static let maxAskDetailLength = 4000

    /// Ids name answer files, so only short, plain ids are accepted (no paths).
    static func isValidAskID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func parseAsk(_ query: [String: String]) -> Result<OrbiAction, RouteError> {
        guard let id = query["id"], isValidAskID(id) else { return .failure(.invalidParameter("id")) }
        guard let kind = AgentAsk.Kind(rawValue: query["kind"] ?? "") else { return .failure(.invalidParameter("kind")) }
        guard let title = query["title"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return .failure(.missingParameter("title"))
        }
        let message = query["message"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let detail = query["detail"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return .success(.ask(AgentAsk(id: id, kind: kind, title: String(title.prefix(maxNotifyLength)),
                                      message: message.map { String($0.prefix(maxNotifyLength * 2)) },
                                      detail: detail.map { String($0.prefix(maxAskDetailLength)) },
                                      context: parseContext(query),
                                      alwaysRule: query["always"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                                          .nilIfEmpty.map { String($0.prefix(200)) })))
    }

    /// Optional agent fields shared by agent routes. Invalid values are dropped, not errors,
    /// so an old or odd hook still gets its bubble.
    static func parseContext(_ query: [String: String]) -> AgentContext {
        func plain(_ key: String, max: Int, extra: Set<Character> = []) -> String? {
            guard let value = query[key], (1...max).contains(value.count),
                  value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || extra.contains($0)) })
            else { return nil }
            return value
        }
        let text: (String, Int) -> String? = { key, max in
            query[key]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map { String($0.prefix(max)) }
        }
        return AgentContext(
            session: plain("session", max: 120, extra: ["-", "_"]),
            agent: text("agent", 40),
            project: text("project", 120),
            app: plain("app", max: 155, extra: [".", "-"]),
            seconds: query["seconds"].flatMap(Int.init).flatMap { (0...86_400).contains($0) ? $0 : nil },
            tokens: query["tokens"].flatMap(Int.init).flatMap { (0...1_000_000_000).contains($0) ? $0 : nil })
    }

    /// `usage?five=23&five_reset=<epoch>&week=41&week_reset=<epoch>`; at least one percentage.
    private static func parseUsage(_ query: [String: String]) -> Result<OrbiAction, RouteError> {
        func percent(_ key: String) -> Int? { query[key].flatMap(Int.init).flatMap { (0...100).contains($0) ? $0 : nil } }
        func date(_ key: String) -> Date? {
            query[key].flatMap(TimeInterval.init).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        }
        let five = percent("five"), week = percent("week")
        guard five != nil || week != nil else { return .failure(.missingParameter("five")) }
        return .success(.usage(UsageLimits(fiveHour: five, fiveHourReset: date("five_reset"),
                                           week: week, weekReset: date("week_reset"), updated: .now)))
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
