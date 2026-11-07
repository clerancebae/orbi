import Foundation
import Testing
@testable import Orbi

struct URLRouterTests {
    func parse(_ string: String) -> Result<OrbiAction, URLRouter.RouteError> {
        URLRouter.parse(URL(string: string)!)  // test literals are valid URLs
    }

    @Test(arguments: [
        ("orbi://water/add", OrbiAction.waterAdd),
        ("orbi://water/undo", .waterUndo),
        ("orbi://task/start-next", .taskStartNext),
        ("orbi://task/complete", .taskComplete),
        ("orbi://reading/open-next", .readingOpenNext),
        ("orbi://capture", .capture),
        ("ORBI://Water/Add/", .waterAdd),
    ])
    func simpleRoutes(url: String, action: OrbiAction) {
        #expect(parse(url) == .success(action))
    }

    @Test func taskAddWithMinutes() {
        #expect(parse("orbi://task/add?title=API%20docs&min=25")
                == .success(.taskAdd(title: "API docs", minutes: 25, day: .today)))
    }

    @Test func taskAddPlusMeansSpaceButEncodedPlusStays() {
        #expect(parse("orbi://task/add?title=C%2B%2B+review")
                == .success(.taskAdd(title: "C++ review", minutes: nil, day: .today)))
    }

    @Test func taskAddParsesEstimateFromTitle() {
        #expect(parse("orbi://task/add?title=Write%20docs%2045m")
                == .success(.taskAdd(title: "Write docs", minutes: 45, day: .today)))
    }

    @Test func taskAddDates() {
        #expect(parse("orbi://task/add?title=X&date=tomorrow") == .success(.taskAdd(title: "X", minutes: nil, day: .tomorrow)))
        #expect(parse("orbi://task/add?title=X&date=2026-12-01")
                == .success(.taskAdd(title: "X", minutes: nil, day: .date(year: 2026, month: 12, day: 1))))
        #expect(parse("orbi://task/add?title=X&date=2026-02-30") == .failure(.invalidParameter("date")))
        #expect(parse("orbi://task/add?title=X&date=next-week") == .failure(.invalidParameter("date")))
    }

    @Test func taskAddValidation() {
        #expect(parse("orbi://task/add") == .failure(.missingParameter("title")))
        #expect(parse("orbi://task/add?title=%20%20") == .failure(.missingParameter("title")))
        #expect(parse("orbi://task/add?title=X&min=0") == .failure(.invalidParameter("min")))
        #expect(parse("orbi://task/add?title=X&min=abc") == .failure(.invalidParameter("min")))
        #expect(parse("orbi://task/add?title=X&min=5000") == .failure(.invalidParameter("min")))
    }

    @Test func longTitleIsCapped() {
        let long = String(repeating: "a", count: 400)
        guard case .success(.taskAdd(let title, _, _)) = parse("orbi://task/add?title=\(long)") else {
            Issue.record("expected taskAdd"); return
        }
        #expect(title.count == URLRouter.maxTitleLength)
    }

    @Test func readingSave() {
        let encoded = "https%3A%2F%2Fexample.com%2Fa%3Fb%3D1%26c%3D2"
        #expect(parse("orbi://reading/save?url=\(encoded)&title=Hello%20World")
                == .success(.readingSave(url: URL(string: "https://example.com/a?b=1&c=2")!, title: "Hello World")))
        #expect(parse("orbi://reading/save?url=https%3A%2F%2Fexample.com")
                == .success(.readingSave(url: URL(string: "https://example.com")!, title: nil)))
    }

    @Test func readingSaveValidation() {
        #expect(parse("orbi://reading/save") == .failure(.missingParameter("url")))
        #expect(parse("orbi://reading/save?url=file%3A%2F%2F%2Fetc%2Fpasswd") == .failure(.invalidParameter("url")))
        #expect(parse("orbi://reading/save?url=javascript%3Aalert(1)") == .failure(.invalidParameter("url")))
        #expect(parse("orbi://reading/save?url=not%20a%20url") == .failure(.invalidParameter("url")))
    }

    @Test func unknownAndForeign() {
        #expect(parse("orbi://water/drink") == .failure(.unknownRoute("water/drink")))
        #expect(parse("orbi://") == .failure(.unknownRoute("")))
        #expect(parse("https://water/add") == .failure(.notOrbi))
    }

    @Test func plannedDayResolution() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Istanbul")!  // valid fixed identifier
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 15))!
        let today = cal.startOfDay(for: now)
        #expect(PlannedDay.today.resolve(now: now, calendar: cal) == today)
        #expect(PlannedDay.tomorrow.resolve(now: now, calendar: cal) == cal.date(byAdding: .day, value: 1, to: today))
        #expect(PlannedDay.date(year: 2020, month: 1, day: 1).resolve(now: now, calendar: cal) == today)
    }
}

struct NotifyRouteTests {
    func parse(_ s: String) -> Result<OrbiAction, URLRouter.RouteError> { URLRouter.parse(URL(string: s)!) }  // valid literals

    @Test func notifyRoutes() {
        #expect(parse("orbi://notify?title=Claude%20finished%20%E2%9C%93&message=Orbi%20%C2%B7%203m")
                == .success(.notify(title: "Claude finished ✓", message: "Orbi · 3m", sticky: false)))
        #expect(parse("orbi://notify?message=Hi") == .success(.notify(title: "Orbi", message: "Hi", sticky: false)))
        #expect(parse("orbi://notify?title=Claude%20needs%20you&sticky=1")
                == .success(.notify(title: "Claude needs you", message: nil, sticky: true)))
        #expect(parse("orbi://notify?title=x&sticky=0") == .success(.notify(title: "x", message: nil, sticky: false)))
        #expect(parse("orbi://notify/dismiss") == .success(.notifyDismiss))
        #expect(parse("orbi://notify") == .failure(.missingParameter("title")))
    }

    @Test func askRoutes() {
        #expect(parse("orbi://ask?id=ab-12&kind=permission&title=Claude%20wants%20to%20use%20Bash&message=Orbi&detail=ls%20-la")
                == .success(.ask(AgentAsk(id: "ab-12", kind: .permission, title: "Claude wants to use Bash",
                                          message: "Orbi", detail: "ls -la"))))
        #expect(parse("orbi://ask?id=x1&kind=reply&title=Done")
                == .success(.ask(AgentAsk(id: "x1", kind: .reply, title: "Done", message: nil, detail: nil))))
        #expect(parse("orbi://ask?id=..%2Fetc&kind=reply&title=t") == .failure(.invalidParameter("id")))
        #expect(parse("orbi://ask?id=a&kind=other&title=t") == .failure(.invalidParameter("kind")))
        #expect(parse("orbi://ask?id=a&kind=reply") == .failure(.missingParameter("title")))
        #expect(parse("orbi://ask/cancel?id=ab-12") == .success(.askCancel(id: "ab-12")))
        #expect(parse("orbi://ask/cancel") == .failure(.invalidParameter("id")))
        #expect(parse("orbi://agent/log?title=Claude%20finished&subtitle=Orbi%20%C2%B7%2045%20s&detail=Done.")
                == .success(.agentLog(title: "Claude finished", subtitle: "Orbi · 45 s", detail: "Done.")))
        #expect(parse("orbi://agent/log?detail=x") == .failure(.missingParameter("title")))
        #expect(parse("orbi://agent/start?session=claude-ab_1&agent=Claude&project=Orbi&app=com.apple.Terminal")
                == .success(.agentStart(AgentContext(session: "claude-ab_1", agent: "Claude", project: "Orbi",
                                                     app: "com.apple.Terminal"))))
        #expect(parse("orbi://agent/start?agent=Claude") == .failure(.invalidParameter("session")))
        #expect(parse("orbi://agent/stop?session=claude-ab_1") == .success(.agentStop(session: "claude-ab_1")))
        // Bad optional fields are dropped, the route still works.
        #expect(parse("orbi://agent/log?title=t&session=..%2Fx&app=a%20b&seconds=-5")
                == .success(.agentLog(title: "t", subtitle: nil, detail: nil, context: .none)))
        #expect(parse("orbi://agent/log?title=t&seconds=420&project=api")
                == .success(.agentLog(title: "t", subtitle: nil, detail: nil,
                                      context: AgentContext(project: "api", seconds: 420))))
        #expect(parse("orbi://notify?title=x&app=com.microsoft.VSCode")
                == .success(.notify(title: "x", message: nil, sticky: false, app: "com.microsoft.VSCode")))
    }
}
