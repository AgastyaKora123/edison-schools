//
//  AnswerEngineTests.swift
//  EdisonParentTests
//
//  Replays tests/questions.jsonl - the same file the PowerShell reference
//  engine is tested against - so the Swift port is checked against the oracle
//  rather than against itself.
//
//  Run with Cmd-U. A failure here means AnswerEngine.swift and
//  engine/Answer-Query.ps1 have diverged; fix the Swift side to match, or
//  change both plus the contract file deliberately.
//

import XCTest
@testable import EdisonParent

final class AnswerEngineTests: XCTestCase {

    // MARK: - Fixtures

    struct Case {
        var line: Int
        var q: String
        var today: Date?
        var school: String
        var resolver: String?
        var contains: [String]
        var notContains: [String]
    }

    private static func bundle() -> Bundle { Bundle(for: AnswerEngineTests.self) }

    private func loadEngine() throws -> AnswerEngine {
        let b = Self.bundle()
        guard let packURL = b.url(forResource: "knowledge-pack", withExtension: "json") else {
            throw XCTSkip("knowledge-pack.json is not in the test bundle's resources.")
        }
        guard let rulesURL = b.url(forResource: "intents", withExtension: "json") else {
            throw XCTSkip("intents.json is not in the test bundle's resources.")
        }
        let pack = try JSONDecoder().decode(KnowledgePack.self, from: Data(contentsOf: packURL))
        let rules = try JSONDecoder().decode(Rules.self, from: Data(contentsOf: rulesURL))
        return AnswerEngine(pack: pack, rules: rules)
    }

    private func loadCases() throws -> [Case] {
        let b = Self.bundle()
        guard let url = b.url(forResource: "questions", withExtension: "jsonl") else {
            throw XCTSkip("questions.jsonl is not in the test bundle's resources.")
        }
        let text = try String(contentsOf: url, encoding: .utf8)

        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "America/New_York")
        df.dateFormat = "yyyy-MM-dd"

        var out: [Case] = []
        for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line.hasPrefix("{") else { continue }
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            // Rows carrying only "_" are section comments.
            guard let q = obj["q"] as? String else { continue }

            out.append(Case(
                line: i + 1,
                q: q,
                today: (obj["today"] as? String).flatMap { df.date(from: $0) },
                school: obj["school"] as? String ?? "",
                resolver: obj["resolver"] as? String,
                contains: (obj["contains"] as? [String])?.filter { !$0.isEmpty } ?? [],
                notContains: (obj["notContains"] as? [String])?.filter { !$0.isEmpty } ?? []
            ))
        }
        return out
    }

    // MARK: - The contract

    func testQuestionContract() throws {
        let engine = try loadEngine()
        let cases = try loadCases()
        XCTAssertGreaterThan(cases.count, 30, "The contract file looks truncated.")

        var failures: [String] = []

        for c in cases {
            let today = c.today ?? Date()
            let a = engine.answer(c.q, today: today, defaultSchoolId: c.school)

            var errs: [String] = []
            if a.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errs.append("empty answer")
            }
            if let want = c.resolver, a.debug.resolver != want {
                errs.append("resolver: want '\(want)', got '\(a.debug.resolver)'")
            }
            // Case-insensitive on purpose, matching the PowerShell and
            // JavaScript harnesses: the contract is about what an answer
            // says, not how the district capitalised a calendar title.
            for needle in c.contains where a.text.range(of: needle, options: .caseInsensitive) == nil {
                errs.append("missing: '\(needle)'")
            }
            for needle in c.notContains where a.text.range(of: needle, options: .caseInsensitive) != nil {
                errs.append("should not contain: '\(needle)'")
            }

            if !errs.isEmpty {
                failures.append("""
                line \(c.line): \(c.q)
                  \(errs.joined(separator: "\n  "))
                  slots: resolver=\(a.debug.resolver) date=\(a.debug.dateSlot) school=\(a.debug.schoolSlot) \
                level=\(a.debug.levelSlot) sched=\(a.debug.scheduleSlot) break=\(a.debug.breakSlot)
                  answer: \(a.text.replacingOccurrences(of: "\n", with: " | "))
                """)
            }
        }

        if !failures.isEmpty {
            XCTFail("\(failures.count) of \(cases.count) contract cases failed:\n\n"
                    + failures.joined(separator: "\n\n"))
        }
    }

    // MARK: - Unit checks on the tricky parts

    /// iCal DTEND is exclusive for all-day events; ingest converts it to an
    /// inclusive endDate. Getting this wrong shifts every break by a day.
    func testBreakEndDatesAreInclusive() throws {
        let engine = try loadEngine()
        for e in engine.pack.calendar where e.kind == "break" {
            guard let s = engine.parsePackDate(e.date),
                  let en = engine.parsePackDate(e.endDate) else {
                XCTFail("unparseable dates on '\(e.title)'")
                continue
            }
            XCTAssertLessThanOrEqual(s, en, "'\(e.title)' ends before it starts")
        }
    }

    func testWeekStartsOnMonday() throws {
        let engine = try loadEngine()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-11-20 is a Friday; its week starts Monday 2026-11-16.
        let friday = cal.date(from: DateComponents(year: 2026, month: 11, day: 20))!
        let start = engine.weekStart(friday)
        XCTAssertEqual(AnswerEngine.iso(start), "2026-11-16")
        // Sunday belongs to the week that just ended, not the next one.
        let sunday = cal.date(from: DateComponents(year: 2026, month: 11, day: 22))!
        XCTAssertEqual(AnswerEngine.iso(engine.weekStart(sunday)), "2026-11-16")
    }

    func testBareMonthDayPrefersTheFuture() throws {
        let engine = try loadEngine()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let nov = cal.date(from: DateComponents(year: 2026, month: 11, day: 20))!
        // Asked in November, "march 10" means the coming March.
        let d = engine.resolveMonthDay(month: 3, day: 10, year: nil, today: nov)
        XCTAssertEqual(d.map(AnswerEngine.iso), "2027-03-10")
        // A date a few days back still reads as the recent past, not a year on.
        let d2 = engine.resolveMonthDay(month: 11, day: 18, year: nil, today: nov)
        XCTAssertEqual(d2.map(AnswerEngine.iso), "2026-11-18")
    }

    func testEveryLevelHasBellTimes() throws {
        let engine = try loadEngine()
        for level in ["elementary", "middle", "high"] {
            let b = engine.pack.bells.first { $0.level == level }
            XCTAssertNotNil(b, "no bell schedule for \(level)")
            XCTAssertNotNil(b?.regular, "no regular hours for \(level)")
            XCTAssertNotNil(b?.delayed, "no delayed-opening hours for \(level)")
            XCTAssertNotNil(b?.early, "no early-dismissal hours for \(level)")
        }
    }

    func testEverySchoolResolvesFromItsOwnName() throws {
        let engine = try loadEngine()
        for s in engine.pack.schools {
            let got = engine.resolveSchool(AnswerEngine.normalize("what time does \(s.name) start"))
            XCTAssertEqual(got?.id, s.id, "'\(s.name)' resolved to \(got?.id ?? "nil")")
        }
    }

    func testNoQueryCrashesOrReturnsEmpty() throws {
        let engine = try loadEngine()
        let nasty = ["", "   ", "?????", "🎉🎉", "a", "/////", "12/99/9999",
                     "is school open on february 30", "next next next",
                     String(repeating: "school ", count: 200)]
        for q in nasty {
            let a = engine.answer(q, today: Date())
            XCTAssertFalse(a.text.isEmpty, "empty answer for '\(q.prefix(20))'")
        }
    }
}
