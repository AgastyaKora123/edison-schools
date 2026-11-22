//
//  DistrictBuilderTests.swift
//  EdisonParentTests
//
//  Checks the parts of DistrictBuilder that do not need the network. The
//  fetching is thin; the parsing and the judgement calls are where the real
//  mistakes live, and every case below is one that has actually gone wrong
//  somewhere in this project.
//

import XCTest
@testable import EdisonParent

final class DistrictBuilderTests: XCTestCase {

    // MARK: - iCal

    /// RFC 5545 says the end of an ALL-DAY event is exclusive: a day off
    /// covering only the 26th is written DTSTART 26th, DTEND 27th. Stored
    /// as written, every break in the app runs a day long and a parent keeps
    /// a child at home on a school day.
    func testAllDayEndDateIsMadeInclusive() throws {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:1
        SUMMARY:Thanksgiving Recess
        DTSTART;VALUE=DATE:20261126
        DTEND;VALUE=DATE:20261128
        END:VEVENT
        END:VCALENDAR
        """
        let events = DistrictBuilder.parseIcs(ics)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].date, "2026-11-26")
        XCTAssertEqual(events[0].endDate, "2026-11-27", "DTEND is exclusive; the last covered day is the 27th")
        XCTAssertTrue(events[0].allDay)
    }

    /// A one-day all-day event must not come back as a zero-day or a
    /// negative one.
    func testOneDayEventStartsAndEndsOnTheSameDay() throws {
        let ics = """
        BEGIN:VEVENT
        UID:2
        SUMMARY:Single Session Day
        DTSTART;VALUE=DATE:20261125
        DTEND;VALUE=DATE:20261126
        END:VEVENT
        """
        let events = DistrictBuilder.parseIcs(ics)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].date, "2026-11-25")
        XCTAssertEqual(events[0].endDate, "2026-11-25")
    }

    /// A timed event's end is NOT exclusive and must be left alone.
    func testTimedEventEndIsNotShifted() throws {
        let ics = """
        BEGIN:VEVENT
        UID:3
        SUMMARY:Board Meeting
        DTSTART:20261202T190000Z
        DTEND:20261202T210000Z
        END:VEVENT
        """
        let events = DistrictBuilder.parseIcs(ics)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].date, "2026-12-02")
        XCTAssertEqual(events[0].endDate, "2026-12-02")
        XCTAssertFalse(events[0].allDay)
    }

    /// Folded lines: a break followed by a space continues the line.
    func testFoldedLinesAreJoined() throws {
        let ics = "BEGIN:VEVENT\r\nUID:4\r\nSUMMARY:Winter Reces\r\n s\r\nDTSTART;VALUE=DATE:20261224\r\nEND:VEVENT"
        let events = DistrictBuilder.parseIcs(ics)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].summary, "Winter Recess")
    }

    func testEscapedCommasAndNewlinesAreUnescaped() throws {
        let ics = """
        BEGIN:VEVENT
        UID:5
        SUMMARY:Early Dismissal\\, All Schools
        DTSTART;VALUE=DATE:20261203
        END:VEVENT
        """
        let events = DistrictBuilder.parseIcs(ics)
        XCTAssertEqual(events[0].summary, "Early Dismissal, All Schools")
    }

    func testTimeZoneIsReadFromTheFeed() {
        XCTAssertEqual(DistrictBuilder.icsTimeZone("X\r\nTZID:America/Chicago\r\nY"), "America/Chicago")
        XCTAssertEqual(DistrictBuilder.icsTimeZone("no timezone here"), "")
    }

    // MARK: - What an entry means

    /// The title decides, and ONLY the title.
    ///
    /// Clarksville's theatre evening came with a description that was a slab
    /// of pasted Word markup. Buried in the stylesheet was "page-break",
    /// which matched the rule for a school break. Classifying on the
    /// description would have told a parent their child had the day off to
    /// watch a play.
    func testDescriptionCannotTurnAnEveningIntoADayOff() {
        let summary = "All The Ways the World Will End But Not You"
        XCTAssertEqual(DistrictBuilder.eventKind(nil, summary), "event")
    }

    func testTitlesAreClassified() {
        XCTAssertEqual(DistrictBuilder.eventKind(nil, "Thanksgiving Recess"), "break")
        XCTAssertEqual(DistrictBuilder.eventKind(nil, "Early Dismissal"), "early_dismissal")
        XCTAssertEqual(DistrictBuilder.eventKind(nil, "Single Session Day"), "single_session")
        XCTAssertEqual(DistrictBuilder.eventKind(nil, "Schools Closed"), "closed")
        XCTAssertEqual(DistrictBuilder.eventKind(nil, "Delayed Opening"), "delayed_opening")
        XCTAssertEqual(DistrictBuilder.eventKind(nil, "Late Start"), "delayed_opening")
        XCTAssertEqual(DistrictBuilder.eventKind(nil, "Picture Day"), "event")
    }

    // MARK: - Names

    func testSectionNamesLoseTheirTrailingNoise() {
        XCTAssertEqual(DistrictBuilder.cleanSectionName("BHS Events"), "BHS")
        XCTAssertEqual(DistrictBuilder.cleanSectionName("Lincoln Elementary Calendar"), "Lincoln Elementary")
        XCTAssertEqual(DistrictBuilder.cleanSectionName("Woodbrook"), "Woodbrook")
        // Stripping everything would leave nothing; keep the original.
        XCTAssertEqual(DistrictBuilder.cleanSectionName("Events"), "Events")
    }

    func testDistrictwideSectionsAreRecognised() {
        XCTAssertTrue(DistrictBuilder.isDistrictSection("District Calendar"))
        XCTAssertTrue(DistrictBuilder.isDistrictSection("All Schools"))
        XCTAssertTrue(DistrictBuilder.isDistrictSection("Events"))
        XCTAssertFalse(DistrictBuilder.isDistrictSection("Lincoln Elementary"))
    }

    /// Districts abbreviate their own schools and expect parents to know:
    /// BHS, BMS, BES.
    func testLevelIsGuessedFromTheName() {
        XCTAssertEqual(DistrictBuilder.guessLevel("Woodrow Wilson High School"), "high")
        XCTAssertEqual(DistrictBuilder.guessLevel("John Adams Middle School"), "middle")
        XCTAssertEqual(DistrictBuilder.guessLevel("Lincoln Elementary"), "elementary")
        XCTAssertEqual(DistrictBuilder.guessLevel("Early Learning Center"), "preschool")
        XCTAssertEqual(DistrictBuilder.guessLevel("BHS Events"), "high")
        XCTAssertEqual(DistrictBuilder.guessLevel("BMS"), "middle")
        XCTAssertEqual(DistrictBuilder.guessLevel("BES"), "elementary")
        XCTAssertEqual(DistrictBuilder.guessLevel("Riverside Academy"), "")
    }

    func testSlugsAreStableAndBounded() {
        XCTAssertEqual(DistrictBuilder.slug("Lincoln Elementary School"), "lincoln-elementary-school")
        XCTAssertEqual(DistrictBuilder.slug("  J.P. Stevens  "), "j-p-stevens")
        XCTAssertLessThanOrEqual(DistrictBuilder.slug(String(repeating: "a", count: 80)).count, 40)
    }

    // MARK: - The directory

    func testDirectoryShipsWithTheApp() throws {
        // Loaded from the test bundle, which gets the same file.
        guard let url = Bundle(for: Self.self).url(forResource: "districts", withExtension: "json") else {
            return XCTFail("districts.json is not in the test bundle.")
        }
        let list = try JSONDecoder().decode([DistrictRef].self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(list.count, 1000, "The directory looks truncated.")

        // Organisation numbers are the key the calendar service is asked for;
        // a duplicate means two districts fighting over one calendar.
        let ids = Set(list.map(\.o))
        XCTAssertEqual(ids.count, list.count, "Two districts share an organisation number.")

        XCTAssertTrue(list.contains { $0.n.localizedCaseInsensitiveContains("Edison") },
                      "The district the app ships with should be in the list too.")
    }
}
