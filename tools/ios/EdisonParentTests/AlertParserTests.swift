//
//  AlertParserTests.swift
//  EdisonParentTests
//
//  Replays tests/alerts.jsonl — the same fixtures the PowerShell reference
//  parser is tested against. Every `status` in that file is a verbatim post
//  from the district's public live feed, false positives included.
//
//  A failure here means AlertMonitor.swift and engine/Alerts.ps1 have
//  diverged.
//

import XCTest
@testable import EdisonParent

final class AlertParserTests: XCTestCase {

    private func loadRules() throws -> Rules {
        let b = Bundle(for: AlertParserTests.self)
        guard let url = b.url(forResource: "intents", withExtension: "json") else {
            throw XCTSkip("intents.json is not in the test bundle's resources.")
        }
        return try JSONDecoder().decode(Rules.self, from: Data(contentsOf: url))
    }

    private func loadPack() throws -> KnowledgePack {
        let b = Bundle(for: AlertParserTests.self)
        guard let url = b.url(forResource: "knowledge-pack", withExtension: "json") else {
            throw XCTSkip("knowledge-pack.json is not in the test bundle's resources.")
        }
        return try JSONDecoder().decode(KnowledgePack.self, from: Data(contentsOf: url))
    }

    struct Fixture {
        var name: String
        var postedAt: Date
        var status: String
        var expect: [String]      // "kind@yyyy-MM-dd"
    }

    private func loadFixtures() throws -> [Fixture] {
        let b = Bundle(for: AlertParserTests.self)
        guard let url = b.url(forResource: "alerts", withExtension: "jsonl") else {
            throw XCTSkip("alerts.jsonl is not in the test bundle's resources.")
        }
        let text = try String(contentsOf: url, encoding: .utf8)

        var out: [Fixture] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("{"), let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = obj["status"] as? String,
                  let postedRaw = obj["postedAt"] as? String,
                  let posted = AlertParser.parseFeedDate(postedRaw) else { continue }

            let expect = ((obj["expect"] as? [[String: Any]]) ?? []).compactMap { e -> String? in
                guard let k = e["kind"] as? String, let d = e["date"] as? String else { return nil }
                return "\(k)@\(d)"
            }
            out.append(Fixture(name: obj["name"] as? String ?? "(unnamed)",
                               postedAt: posted, status: status, expect: expect))
        }
        return out
    }

    // MARK: - The contract

    func testAlertFixtures() throws {
        let rules = try loadRules()
        let parser = AlertParser(rules: rules)
        let fixtures = try loadFixtures()
        XCTAssertGreaterThan(fixtures.count, 10, "The alert contract file looks truncated.")

        var failures: [String] = []
        for f in fixtures {
            let got = Set(parser.alerts(inStatus: f.status, postedAt: f.postedAt)
                            .map { "\($0.kind)@\(AnswerEngine.iso($0.date))" })
            let want = Set(f.expect)

            let missing = want.subtracting(got)
            let extra = got.subtracting(want)
            if !missing.isEmpty || !extra.isEmpty {
                var msg = "\(f.name):"
                if !missing.isEmpty { msg += "\n  missing: \(missing.sorted().joined(separator: ", "))" }
                if !extra.isEmpty   { msg += "\n  extra:   \(extra.sorted().joined(separator: ", "))" }
                failures.append(msg)
            }
        }
        if !failures.isEmpty {
            XCTFail("\(failures.count) of \(fixtures.count) alert fixtures failed:\n\n"
                    + failures.joined(separator: "\n\n"))
        }
    }

    // MARK: - The point of the whole layer

    /// On a snow day the published calendar says "normal full day" and is
    /// wrong. A live alert has to win.
    func testAlertOverridesCalendar() throws {
        let rules = try loadRules()
        var pack = try loadPack()

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let target = cal.date(from: DateComponents(year: 2026, month: 12, day: 10))!   // a clear Thursday
        let today = cal.date(from: DateComponents(year: 2026, month: 12, day: 9))!

        pack.alerts = []
        let before = AnswerEngine(pack: pack, rules: rules)
            .answer("is there school tomorrow", today: today)
        XCTAssertTrue(before.text.contains("open"),
                      "baseline should be open, got: \(before.text)")

        pack.alerts = [ClosingAlert(
            id: "999-closed-2026-12-10",
            kind: "closed",
            date: AnswerEngine.iso(target),
            postedAt: "2026-12-09T15:02:00-05:00",
            text: "Due to inclement weather, Edison Township Public Schools will be closed tomorrow, Thursday, December 10.",
            author: "District",
            scope: "district", schoolId: nil
        )]
        let after = AnswerEngine(pack: pack, rules: rules)
            .answer("is there school tomorrow", today: today)

        XCTAssertTrue(after.text.hasPrefix("No"), "expected a No, got: \(after.text)")
        XCTAssertTrue(after.text.contains("closed"))
        XCTAssertTrue(after.text.contains("announcement posted"),
                      "the answer should say it came from an announcement")
        XCTAssertTrue(after.sources.contains { $0.contains("live-feed") })
        XCTAssertFalse(after.text.contains(".."), "doubled period in: \(after.text)")
    }

    /// A delayed opening has to move the reported start times, not just the
    /// wording.
    func testDelayedOpeningShiftsBellTimes() throws {
        let rules = try loadRules()
        var pack = try loadPack()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let today = cal.date(from: DateComponents(year: 2026, month: 12, day: 9))!

        pack.alerts = [ClosingAlert(
            id: "998-delayed-2026-12-10", kind: "delayed_opening", date: "2026-12-10",
            postedAt: "2026-12-09T15:02:00-05:00",
            text: "two-hour delayed opening tomorrow", author: "District", scope: "district", schoolId: nil
        )]
        let a = AnswerEngine(pack: pack, rules: rules)
            .answer("what time does middle school start tomorrow", today: today)
        XCTAssertTrue(a.text.contains("10:25 AM"),
                      "middle school should open at 10:25 on a delay, got: \(a.text)")
    }

    /// A single-building closure must not close the district. This is the
    /// failure mode that would matter most: a Woodbrook parent keeping their
    /// kid home because Lincoln lost heat.
    func testSchoolAlertDoesNotCloseOtherSchools() throws {
        let rules = try loadRules()
        var pack = try loadPack()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let today = cal.date(from: DateComponents(year: 2026, month: 12, day: 9))!

        pack.alerts = [ClosingAlert(
            id: "997-closed-2026-12-10", kind: "closed", date: "2026-12-10",
            postedAt: "2026-12-09T15:02:00-05:00",
            text: "Lincoln Elementary School will be closed tomorrow due to a water main break.",
            author: "Lincoln", scope: "school", schoolId: "les"
        )]
        let engine = AnswerEngine(pack: pack, rules: rules)

        let atLincoln = engine.answer("is there school tomorrow at Lincoln", today: today)
        XCTAssertTrue(atLincoln.text.contains("closed"), "Lincoln should be closed: \(atLincoln.text)")

        let atWoodbrook = engine.answer("is there school tomorrow at Woodbrook", today: today)
        XCTAssertTrue(atWoodbrook.text.contains("open"),
                      "Woodbrook must stay open: \(atWoodbrook.text)")

        let unnamed = engine.answer("is there school tomorrow", today: today)
        XCTAssertTrue(unnamed.text.contains("open"),
                      "with no school named, a one-school closure must not apply: \(unnamed.text)")
    }

    /// A school republishing the district's own closing must not double up.
    func testSchoolEchoOfDistrictAlertIsDropped() {
        let district = ClosingAlert(id: "d", kind: "closed", date: "2026-12-10",
                                    postedAt: "2026-12-09T15:00:00-05:00", text: "district closed",
                                    author: "", scope: "district", schoolId: nil)
        let echo = ClosingAlert(id: "s", kind: "closed", date: "2026-12-10",
                                postedAt: "2026-12-09T15:30:00-05:00", text: "district closed",
                                author: "", scope: "school", schoolId: "les")
        let merged = AlertParser.merge([district, echo])
        XCTAssertEqual(merged.count, 1)
        XCTAssertNil(merged.first?.schoolId, "the district copy should survive, not the echo")
    }

    /// Closure outranks a delay when both are posted for the same day.
    func testClosureOutranksDelay() throws {
        let rules = try loadRules()
        var pack = try loadPack()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let today = cal.date(from: DateComponents(year: 2026, month: 12, day: 9))!

        pack.alerts = [
            ClosingAlert(id: "a", kind: "delayed_opening", date: "2026-12-10",
                         postedAt: "2026-12-09T15:00:00-05:00", text: "delayed opening",
                         author: "", scope: "district", schoolId: nil),
            ClosingAlert(id: "b", kind: "closed", date: "2026-12-10",
                         postedAt: "2026-12-09T20:00:00-05:00", text: "schools closed",
                         author: "", scope: "district", schoolId: nil)
        ]
        let a = AnswerEngine(pack: pack, rules: rules)
            .answer("is there school tomorrow", today: today)
        XCTAssertTrue(a.text.contains("closed"), "closure should win, got: \(a.text)")
    }

    func testMergeKeepsNewestPerKindAndDate() {
        let older = ClosingAlert(id: "x", kind: "closed", date: "2026-12-10",
                                 postedAt: "2026-12-09T10:00:00-05:00", text: "first wording",
                                 author: "", scope: "district", schoolId: nil)
        let newer = ClosingAlert(id: "y", kind: "closed", date: "2026-12-10",
                                 postedAt: "2026-12-09T16:00:00-05:00", text: "updated wording",
                                 author: "", scope: "district", schoolId: nil)
        let merged = AlertParser.merge([older, newer])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.text, "updated wording")
    }

    func testFriendlyDayWording() {
        let cal = Calendar(identifier: .gregorian)
        let today = AnswerEngine.iso(Date())
        XCTAssertEqual(ClosingNotifier.friendlyDay(today), "today")
        let tomorrow = AnswerEngine.iso(cal.date(byAdding: .day, value: 1, to: Date())!)
        XCTAssertEqual(ClosingNotifier.friendlyDay(tomorrow), "tomorrow")
    }

    func testMalformedFeedIsIgnored() throws {
        let rules = try loadRules()
        let parser = AlertParser(rules: rules)
        for bad in ["", "{}", "[]", "not json", "{\"live_feeds\":null}", "{\"live_feeds\":[{}]}"] {
            let out = parser.alerts(inFeed: Data(bad.utf8))
            XCTAssertTrue(out.isEmpty, "expected nothing from \(bad)")
        }
    }
}
