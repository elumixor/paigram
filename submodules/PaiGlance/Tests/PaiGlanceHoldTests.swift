import XCTest
@testable import PaiGlance

final class PaiGlanceHoldTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")

    private func summary(_ extra: String) -> Data {
        Data("{\"todayUsd\": 1.5, \"windows\": [{\"name\": \"Weekly\", \"percent\": 91.0}]\(extra)}".utf8)
    }

    func testDecodesHoldAt90() {
        let glance = PaiGlanceLiveSource.decodeSummary(summary(", \"hold\": {\"level\": 90, \"until\": \"2026-11-23T14:00:00.351Z\", \"held\": 3}"))
        XCTAssertEqual(glance?.hold, PaiGlance.Hold(level: 90, until: "2026-11-23T14:00:00.351Z", held: 3))
    }

    func testDecodesHoldAt95() {
        let glance = PaiGlanceLiveSource.decodeSummary(summary(", \"hold\": {\"level\": 95, \"until\": \"2026-11-23T14:00:00Z\", \"held\": 7}"))
        XCTAssertEqual(glance?.hold?.level, 95)
        XCTAssertEqual(glance?.hold?.held, 7)
    }

    func testNullHoldIsNil() {
        let glance = PaiGlanceLiveSource.decodeSummary(summary(", \"hold\": null"))
        XCTAssertNotNil(glance)
        XCTAssertNil(glance?.hold)
    }

    func testMissingHoldIsNil() {
        let glance = PaiGlanceLiveSource.decodeSummary(summary(""))
        XCTAssertNotNil(glance)
        XCTAssertNil(glance?.hold)
    }

    func testMalformedHoldIsNil() {
        XCTAssertNil(PaiGlance.Hold.decode(["level": "90"]))
        XCTAssertNil(PaiGlance.Hold.decode(["until": "2026-11-23T14:00:00Z"]))
        XCTAssertEqual(PaiGlance.Hold.decode(["level": 90, "until": "x"])?.held, 0)
    }

    func testUntilDateReadsMilliseconds() {
        let hold = PaiGlance.Hold(level: 90, until: "2026-11-23T14:00:00.351Z", held: 0)
        XCTAssertEqual(hold.untilDate, ISO8601DateFormatter().date(from: "2026-11-23T14:00:00Z"))
    }

    func testLineAt90SameDay() {
        let hold = PaiGlance.Hold(level: 90, until: "2026-11-23T14:00:00.000Z", held: 3)
        let now = ISO8601DateFormatter().date(from: "2026-11-23T09:00:00Z")!
        XCTAssertEqual(hold.line(now: now, timeZone: utc, locale: posix), "Background held until 14:00 · 3 held")
    }

    func testLineAt90OtherDay() {
        let hold = PaiGlance.Hold(level: 90, until: "2026-11-23T14:00:00Z", held: 1)
        let now = ISO8601DateFormatter().date(from: "2026-11-19T09:00:00Z")!
        XCTAssertEqual(hold.line(now: now, timeZone: utc, locale: posix), "Background held until Mon 14:00 · 1 held")
    }

    func testLineAt90WithoutDate() {
        let hold = PaiGlance.Hold(level: 90, until: "soon", held: 2)
        XCTAssertEqual(hold.line(), "Background held · 2 held")
    }

    func testLineAt95() {
        let hold = PaiGlance.Hold(level: 95, until: "2026-11-23T14:00:00Z", held: 4)
        XCTAssertEqual(hold.line(), "Agents can't start dev sessions; yours still run · 4 held")
    }

    func testEmptyWindowsAreUnknown() {
        let glance = PaiGlanceLiveSource.decodeSummary(Data("{\"todayUsd\": 0.0, \"windows\": []}".utf8))
        XCTAssertEqual(glance?.windows.isEmpty, true)
        XCTAssertNil(glance?.session)
        XCTAssertEqual(PaiGlance.percentText(glance?.session), "—")
        XCTAssertEqual(PaiGlance.percentText(PaiGlance.Window(name: "Session", percent: 45.6, resetsAt: nil)), "46%")
    }

    func testCodableRoundTripKeepsHold() throws {
        let glance = PaiGlance(at: Date(timeIntervalSince1970: 0), todayUsd: 1, usdPerHour: nil, windows: [], agents: [], running: 0, needsCount: 0, needs: [], hold: PaiGlance.Hold(level: 95, until: "2026-11-23T14:00:00Z", held: 2))
        let decoded = try JSONDecoder().decode(PaiGlance.self, from: JSONEncoder().encode(glance))
        XCTAssertEqual(decoded.hold, glance.hold)
    }

    func testStoredGlanceWithoutHoldDecodes() throws {
        let glance = PaiGlance(at: Date(timeIntervalSince1970: 0), todayUsd: 1, usdPerHour: nil, windows: [], agents: [], running: 0, needsCount: 0, needs: [])
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(glance)) as! [String: Any]
        object.removeValue(forKey: "hold")
        let decoded = try JSONDecoder().decode(PaiGlance.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.hold)
    }

    func testHoldWithoutHeldDecodesAsZero() throws {
        let hold = try JSONDecoder().decode(PaiGlance.Hold.self, from: Data("{\"level\": 90, \"until\": \"2026-11-23T14:00:00Z\"}".utf8))
        XCTAssertEqual(hold.held, 0)
    }
}
