import XCTest
@testable import PaiGlance

final class PaiWidgetModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func glance(windows: [PaiGlance.Window] = [], needs: [PaiGlance.Need] = [], needsCount: Int? = nil, team: [PaiGlance.Member] = [], hold: PaiGlance.Hold? = nil) -> PaiGlance {
        PaiGlance(at: now, todayUsd: 12, usdPerHour: nil, windows: windows, agents: [], running: 0, needsCount: needsCount ?? needs.count, needs: needs, team: team, hold: hold)
    }

    private func member(_ slug: String, status: String = "idle", doing: String? = "line", activeAgo: TimeInterval? = nil) -> PaiGlance.Member {
        PaiGlance.Member(slug: slug, name: slug.capitalized, role: nil, status: status, doing: doing, depth: 2, steps: [], activeAt: activeAgo.map { now.addingTimeInterval(-$0) })
    }

    func testBarFractions() {
        let model = PaiWidgetModel(glance: glance(windows: [
            PaiGlance.Window(name: "Session", percent: 46, resetsAt: nil),
            PaiGlance.Window(name: "Weekly", percent: 71.4, resetsAt: now.addingTimeInterval(2 * 86400 + 60))
        ]), now: now)
        XCTAssertEqual(model.bar.weekly!, 0.714, accuracy: 0.0001)
        XCTAssertEqual(model.bar.session!, 0.46, accuracy: 0.0001)
        XCTAssertEqual(model.bar.weeklyLabel, "71%")
        XCTAssertEqual(model.bar.sessionLabel, "46%")
        XCTAssertEqual(model.bar.weeklyResetsIn, "2d")
        XCTAssertEqual(model.bar.peakPercent, 71.4)
    }

    func testBarClampsOutOfRange() {
        let model = PaiWidgetModel(glance: glance(windows: [
            PaiGlance.Window(name: "Session", percent: -5, resetsAt: nil),
            PaiGlance.Window(name: "Weekly", percent: 130, resetsAt: nil)
        ]), now: now)
        XCTAssertEqual(model.bar.weekly, 1)
        XCTAssertEqual(model.bar.session, 0)
    }

    func testUnknownWindowsAreDashNotZero() {
        let model = PaiWidgetModel(glance: glance(windows: []), now: now)
        XCTAssertNil(model.bar.weekly)
        XCTAssertNil(model.bar.session)
        XCTAssertEqual(model.bar.weeklyLabel, "—")
        XCTAssertEqual(model.bar.sessionLabel, "—")
        XCTAssertNil(model.bar.peakPercent)
    }

    func testOnlyWeeklyKnownLeavesSessionUnknown() {
        let model = PaiWidgetModel(glance: glance(windows: [PaiGlance.Window(name: "Weekly", percent: 50, resetsAt: nil)]), now: now)
        XCTAssertEqual(model.bar.weekly, 0.5)
        XCTAssertNil(model.bar.session)
        XCTAssertEqual(model.bar.sessionLabel, "—")
    }

    func testAgentsMostRecentFirstThenWorkingThenTeamOrder() {
        let team = [
            member("pai", status: "idle"),
            member("old", activeAgo: 3600),
            member("busy", status: "working"),
            member("fresh", activeAgo: 60),
            member("silent", doing: "  ")
        ]
        let model = PaiWidgetModel(glance: glance(team: team), now: now)
        XCTAssertEqual(model.agents.map(\.slug), ["fresh", "old", "busy", "pai"])
        XCTAssertEqual(model.agents.first?.age, "1m")
        XCTAssertNil(model.agents.last?.age)
    }

    func testAgentLineDropsTrailingAge() {
        XCTAssertEqual(PaiWidgetModel.stripAge("Release build running · 5m ago"), "Release build running")
        XCTAssertEqual(PaiWidgetModel.stripAge("Sorting · just now"), "Sorting")
        XCTAssertEqual(PaiWidgetModel.stripAge("A · B"), "A · B")
    }

    func testAsksOldestFirstAndCount() {
        let needs = [
            PaiGlance.Need(id: "b", agent: nil, from: "Tomas", question: "**Ship**?", options: [], freeText: true, createdAt: now.addingTimeInterval(-600)),
            PaiGlance.Need(id: "a", agent: "lena", from: "Lena", question: "Send?", options: [], freeText: true, createdAt: now.addingTimeInterval(-7200))
        ]
        let model = PaiWidgetModel(glance: glance(needs: needs, needsCount: 5), now: now)
        XCTAssertEqual(model.asksCount, 5)
        XCTAssertEqual(model.oldestAsk?.id, "a")
        XCTAssertEqual(model.oldestAsk?.age, "2h")
        XCTAssertEqual(model.asks.last?.question, "Ship?")
    }

    func testHoldLine() {
        XCTAssertNil(PaiWidgetModel(glance: glance(), now: now).holdLine)
        let held = PaiWidgetModel(glance: glance(hold: PaiGlance.Hold(level: 90, until: now.addingTimeInterval(3 * 86400), held: 4)), now: now)
        XCTAssertEqual(held.holdLine, "Background held · weekly ≥90% · until 3d")
    }

    func testGlanceWithoutNewFieldsStillDecodes() throws {
        let json = #"{"at":0,"todayUsd":1,"windows":[],"agents":[],"running":0,"needsCount":0,"needs":[],"team":[{"slug":"a","name":"A","status":"idle","depth":1,"steps":[]}]}"#
        let decoded = try JSONDecoder().decode(PaiGlance.self, from: Data(json.utf8))
        XCTAssertNil(decoded.hold)
        XCTAssertNil(decoded.team.first?.activeAt)
    }

    func testSummaryDecodesHold() {
        let json = #"{"todayUsd":1,"windows":[],"hold":{"level":95,"until":"2027-01-01T00:00:00.000Z","held":3}}"#
        let glance = PaiGlanceLiveSource.decodeSummary(Data(json.utf8))
        XCTAssertEqual(glance?.hold?.level, 95)
        XCTAssertEqual(glance?.hold?.held, 3)
        XCTAssertNotNil(glance?.hold?.until)
    }
}
