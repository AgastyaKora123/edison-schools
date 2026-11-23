//
//  DayBeforeRemindersTests.swift
//  EdisonParentTests
//
//  The reminders that go out the evening before a planned day off.
//
//  Everything tested here is a pure function. Nothing touches the
//  notification queue: iOS will not let a unit test schedule one, and the
//  interesting decisions - which days, collapsing a run, the wording, the
//  hour - are all made before the queue is reached.
//

import XCTest
@testable import EdisonParent

final class DayBeforeRemindersTests: XCTestCase {

    // MARK: - Fixtures

    private static func bundle() -> Bundle { Bundle(for: DayBeforeRemindersTests.self) }

    private func loadPack() throws -> (pack: KnowledgePack, rules: Rules) {
        let b = Self.bundle()
        guard let packURL = b.url(forResource: "knowledge-pack", withExtension: "json") else {
            throw XCTSkip("knowledge-pack.json is not in the test bundle's resources.")
        }
        guard let rulesURL = b.url(forResource: "intents", withExtension: "json") else {
            throw XCTSkip("intents.json is not in the test bundle's resources.")
        }
        let pack = try JSONDecoder().decode(KnowledgePack.self, from: Data(contentsOf: packURL))
        let rules = try JSONDecoder().decode(Rules.self, from: Data(contentsOf: rulesURL))
        return (pack, rules)
    }

    /// The real pack with its calendar replaced by a known one.
    ///
    /// Keeping the rest of the pack real means these run against the engine
    /// that actually ships, rather than a stripped-down stand-in that could
    /// pass here while the app fails.
    private func makeEngine(calendar entries: [CalendarEntry],
                            alerts: [ClosingAlert] = []) throws -> AnswerEngine {
        let loaded = try loadPack()
        var pack = loaded.pack
        pack.calendar = entries
        pack.alerts = alerts
        return AnswerEngine(pack: pack, rules: loaded.rules)
    }

    private var eastern: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func day(_ iso: String) -> Date {
        let f = DateFormatter()
        f.calendar = eastern
        f.timeZone = eastern.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: iso)!
    }

    private func entry(_ from: String, _ to: String, _ title: String, _ kind: String) -> CalendarEntry {
        CalendarEntry(date: from, endDate: to, title: title, rawTitle: title,
                      kind: kind, scope: "district", schoolIds: [], allDay: true,
                      startTime: nil, url: "https://example.org/")
    }

    // MARK: - The words

    func testTitlesSayWhatTomorrowIs() {
        XCTAssertEqual(DayBeforeReminders.title(for: .closed), "No school tomorrow")
        XCTAssertEqual(DayBeforeReminders.title(for: .earlyDismissal), "Early dismissal tomorrow")
        XCTAssertEqual(DayBeforeReminders.title(for: .delayedOpening), "Late start tomorrow")
    }

    func testMessageNamesTheDayAndTheReason() {
        let m = DayBeforeReminders.message(kind: .closed,
                                           reason: "Thanksgiving Recess",
                                           weekday: "Thursday",
                                           who: "Edison schools")
        XCTAssertEqual(m, "Edison schools are closed Thursday — Thanksgiving Recess.")
    }

    /// Districts title an early dismissal "Early Dismissal". Under a heading
    /// that already reads "Early dismissal tomorrow" that is the same words
    /// twice, so the reason is dropped.
    func testMessageDoesNotSayTheSameThingTwice() {
        let m = DayBeforeReminders.message(kind: .earlyDismissal,
                                           reason: "Early Dismissal",
                                           weekday: "Friday",
                                           who: "Edison schools")
        XCTAssertEqual(m, "School lets out early on Friday.")
        XCTAssertFalse(m.contains("—"))
    }

    func testMessageWithNoReasonIsStillASentence() {
        let m = DayBeforeReminders.message(kind: .delayedOpening, reason: "",
                                           weekday: "Monday", who: "Edison schools")
        XCTAssertEqual(m, "School opens later than usual on Monday.")
    }

    /// Titles arrive from a dozen different district websites, some carrying
    /// a double space or a stray newline from the page they were typed on.
    func testMessageTidiesUpAMessyTitle() {
        let m = DayBeforeReminders.message(kind: .closed, reason: "  Teacher\n Institute  Day ",
                                           weekday: "Monday", who: "Edison schools")
        XCTAssertEqual(m, "Edison schools are closed Monday — Teacher Institute Day.")
    }

    func testWhoFallsBackWhenThereIsNoPack() {
        XCTAssertEqual(DayBeforeReminders.who(for: nil), "School")
    }

    // MARK: - The hour

    func testReminderFiresTheEveningBeforeAtTheChosenHour() {
        let target = day("2026-12-24")
        let fire = DayBeforeReminders.fireDate(dayBefore: target, hour: 18, calendar: eastern)
        XCTAssertNotNil(fire)

        let c = eastern.dateComponents([.year, .month, .day, .hour, .minute], from: fire!)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 12)
        XCTAssertEqual(c.day, 23)      // the evening BEFORE
        XCTAssertEqual(c.hour, 18)
        XCTAssertEqual(c.minute, 0)
    }

    /// Stored as an hour, not as a date, so it still means "six in the
    /// evening" on the other side of the clocks changing.
    func testTheHourSurvivesTheClocksChanging() {
        let before = DayBeforeReminders.fireDate(dayBefore: day("2026-10-31"), hour: 18, calendar: eastern)!
        let after = DayBeforeReminders.fireDate(dayBefore: day("2026-11-03"), hour: 18, calendar: eastern)!
        XCTAssertEqual(eastern.component(.hour, from: before), 18)
        XCTAssertEqual(eastern.component(.hour, from: after), 18)
    }

    // MARK: - Which days

    /// The whole point of collapsing runs: a five-day break is one reminder,
    /// not five. Told five nights running, anybody would switch them off.
    func testAWholeBreakGetsOneReminder() throws {
        // 4 January 2027 is a Monday; 8 January is the Friday.
        let engine = try makeEngine(calendar: [
            entry("2027-01-04", "2027-01-08", "Winter Recess", "break")])

        let out = DayBeforeReminders.upcoming(engine: engine, school: nil,
                                              now: day("2027-01-01"), calendar: eastern)

        XCTAssertEqual(out.count, 1, "a five-day break should produce one reminder, not five")
        XCTAssertEqual(out.first?.kind, .closed)
        XCTAssertEqual(out.first?.reason, "Winter Recess")
        XCTAssertEqual(eastern.component(.day, from: out[0].date), 4)
    }

    /// A break that starts on a Friday is still the same break on Monday, so
    /// the look-back has to see past the weekend.
    func testNotRepeatedAfterTheWeekendInTheMiddleOfABreak() throws {
        // 8 January 2027 is a Friday, 11 January the Monday after.
        let engine = try makeEngine(calendar: [
            entry("2027-01-08", "2027-01-12", "Mid-Winter Break", "break")])

        let out = DayBeforeReminders.upcoming(engine: engine, school: nil,
                                              now: day("2027-01-05"), calendar: eastern)

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(eastern.component(.day, from: out[0].date), 8)
    }

    /// Two different kinds back to back are two different pieces of news.
    func testAnEarlyDismissalAfterAClosureIsItsOwnReminder() throws {
        let engine = try makeEngine(calendar: [
            entry("2027-01-04", "2027-01-04", "Teacher Institute Day", "closed"),
            entry("2027-01-05", "2027-01-05", "Conferences", "early_dismissal")])

        let out = DayBeforeReminders.upcoming(engine: engine, school: nil,
                                              now: day("2027-01-01"), calendar: eastern)

        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].kind, .closed)
        XCTAssertEqual(out[1].kind, .earlyDismissal)
    }

    /// A snow day posted to the live feed is announced immediately by
    /// ClosingNotifier. Scheduling a second notification for the same day
    /// would have one app telling somebody twice.
    func testADayAlreadyAnnouncedOnTheFeedIsLeftAlone() throws {
        let engine = try makeEngine(
            calendar: [entry("2027-01-04", "2027-01-04", "Snow Day", "closed")],
            alerts: [ClosingAlert(id: "a1", kind: "closed", date: "2027-01-04",
                                  postedAt: "2027-01-03T15:00:00Z",
                                  text: "All schools closed Monday.",
                                  author: "District", scope: "district", schoolId: nil)])

        let out = DayBeforeReminders.upcoming(engine: engine, school: nil,
                                              now: day("2027-01-01"), calendar: eastern)

        XCTAssertTrue(out.isEmpty, "the alert layer has already said this one")
    }

    func testRegularDaysAndWeekendsAreNeverWorthTelling() {
        XCTAssertFalse(DayBeforeReminders.worthTelling(.regular))
        XCTAssertFalse(DayBeforeReminders.worthTelling(.weekend))
        XCTAssertFalse(DayBeforeReminders.worthTelling(.unknown))
        XCTAssertTrue(DayBeforeReminders.worthTelling(.closed))
        XCTAssertTrue(DayBeforeReminders.worthTelling(.earlyDismissal))
        XCTAssertTrue(DayBeforeReminders.worthTelling(.delayedOpening))
    }

    // MARK: - Against the real calendar

    /// Properties that must hold whatever the district has published, so this
    /// keeps working when the pack is rebuilt next month.
    func testAgainstTheShippedCalendar() throws {
        let loaded = try loadPack()
        let engine = AnswerEngine(pack: loaded.pack, rules: loaded.rules)
        let now = day("2026-09-08")      // a Tuesday early in the school year

        let out = DayBeforeReminders.upcoming(engine: engine, school: nil,
                                              now: now, calendar: eastern)

        XCTAssertLessThanOrEqual(out.count, DayBeforeReminders.maxReminders)

        var last: Date? = nil
        for u in out {
            XCTAssertTrue(u.date > now, "a reminder was planned for a day that has gone")
            XCTAssertTrue(DayBeforeReminders.worthTelling(u.kind), "reminded about a normal day")

            let wd = eastern.component(.weekday, from: u.date)
            XCTAssertFalse(wd == 1 || wd == 7, "reminded about a weekend")

            if let l = last { XCTAssertTrue(u.date > l, "reminders are out of order") }
            last = u.date

            // Every one must produce a sentence, with no holes in it.
            let text = DayBeforeReminders.message(kind: u.kind, reason: u.reason,
                                                  weekday: "Monday", who: "Edison schools")
            XCTAssertFalse(text.contains("  "))
            XCTAssertTrue(text.hasSuffix("."))
            XCTAssertFalse(text.hasSuffix(" ."))
        }
    }

    func testTheLimitIsRespected() throws {
        let loaded = try loadPack()
        let engine = AnswerEngine(pack: loaded.pack, rules: loaded.rules)
        let out = DayBeforeReminders.upcoming(engine: engine, school: nil,
                                              now: day("2026-09-08"),
                                              calendar: eastern, limit: 2)
        XCTAssertLessThanOrEqual(out.count, 2)
    }

    func testIdentifiersAreStableAndOursAlone() {
        let u = DayBeforeReminders.Upcoming(date: day("2026-12-24"), kind: .closed, reason: "x")
        let id = DayBeforeReminders.identifier(for: u, calendar: eastern)
        XCTAssertEqual(id, "dayBefore-2026-12-24-closed")
        XCTAssertTrue(id.hasPrefix(DayBeforeReminders.idPrefix),
                      "the prefix is how these are found and replaced without touching closing alerts")
    }
}
