//
//  PracticeTests.swift
//  EdisonParentTests
//
//  The two parts of practice worth testing: reading notes, and deciding
//  when a card comes back. Every case here is something a student would
//  actually paste or do.
//

import XCTest
@testable import EdisonParent

final class NotesParserTests: XCTestCase {

    func testReadsTheWaysPeopleActuallyWriteNotes() {
        let notes = """
        Mitochondria - the powerhouse of the cell
        Photosynthesis: how plants make food from light
        Osmosis — water moving across a membrane
        Diffusion = particles spreading out
        """
        let r = NotesParser.parse(notes)
        XCTAssertEqual(r.cards.count, 4)
        XCTAssertEqual(r.skipped.count, 0)
        XCTAssertEqual(r.cards[0].front, "Mitochondria")
        XCTAssertEqual(r.cards[0].back, "the powerhouse of the cell")
        XCTAssertEqual(r.cards[1].front, "Photosynthesis")
        XCTAssertEqual(r.cards[2].front, "Osmosis")
        XCTAssertEqual(r.cards[3].back, "particles spreading out")
    }

    /// People paste straight out of a bulleted document.
    func testStripsBulletsAndNumbering() {
        let notes = """
        • Mitosis - cell division
        1. Meiosis: makes gametes
        - Enzyme — a biological catalyst
        b) Substrate = what an enzyme acts on
        """
        let r = NotesParser.parse(notes)
        XCTAssertEqual(r.cards.count, 4)
        XCTAssertEqual(r.cards[0].front, "Mitosis")
        XCTAssertEqual(r.cards[1].front, "Meiosis")
        XCTAssertEqual(r.cards[2].front, "Enzyme",
                       "A leading dash is decoration; the middle one is the separator.")
        XCTAssertEqual(r.cards[3].front, "Substrate")
    }

    /// A colon inside a time or a ratio is not a separator, and treating it
    /// as one turns a sentence into a nonsense card.
    func testDoesNotSplitTimesOrRatios() {
        let r = NotesParser.parse("The test is at 3:30 on Friday")
        XCTAssertEqual(r.cards.count, 0)
        XCTAssertEqual(r.skipped.count, 1)
    }

    /// Headings and prose have no pair in them. They are reported rather
    /// than silently dropped: finding out at the test that half your notes
    /// never made it is the worst possible time.
    func testReportsLinesItCannotRead() {
        let notes = """
        Chapter 4 Revision
        Mitochondria - the powerhouse of the cell
        remember to revise the diagrams too
        """
        let r = NotesParser.parse(notes)
        XCTAssertEqual(r.cards.count, 1)
        XCTAssertEqual(r.skipped, ["Chapter 4 Revision", "remember to revise the diagrams too"])
    }

    func testFirstSeparatorWins() {
        let r = NotesParser.parse("Habitat: where something lives: its home")
        XCTAssertEqual(r.cards.count, 1)
        XCTAssertEqual(r.cards[0].front, "Habitat")
        XCTAssertEqual(r.cards[0].back, "where something lives: its home")
    }

    func testIgnoresBlankLines() {
        let r = NotesParser.parse("\n\n  \nAtom: smallest unit of an element\n\n")
        XCTAssertEqual(r.cards.count, 1)
        XCTAssertEqual(r.skipped.count, 0)
    }
}

final class CardSchedulingTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func day(_ offset: Int) -> Date {
        cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date()))!
    }

    func testNewCardsAreDueStraightAway() {
        let c = Card(front: "a", back: "b")
        XCTAssertTrue(c.isDue(on: day(0), calendar: cal))
    }

    func testGettingItRightPushesItFurtherOut() {
        var c = Card(front: "a", back: "b")
        c.markCorrect(on: day(0), calendar: cal)
        XCTAssertEqual(c.box, 2)
        XCTAssertFalse(c.isDue(on: day(0), calendar: cal))
        XCTAssertTrue(c.isDue(on: day(1), calendar: cal))

        c.markCorrect(on: day(1), calendar: cal)
        XCTAssertEqual(c.box, 3)
        XCTAssertFalse(c.isDue(on: day(3), calendar: cal))
        XCTAssertTrue(c.isDue(on: day(4), calendar: cal))
    }

    /// A card you have just failed is a card you do not know, whatever you
    /// managed last week. Dropping only one box lets people "revise" things
    /// they cannot actually recall.
    func testGettingItWrongSendsItBackToTheStart() {
        var c = Card(front: "a", back: "b")
        for i in 0..<4 { c.markCorrect(on: day(i * 30), calendar: cal) }
        XCTAssertEqual(c.box, 5)

        c.markWrong(on: day(200), calendar: cal)
        XCTAssertEqual(c.box, 1, "Straight back to the start, not down one.")
        XCTAssertTrue(c.isDue(on: day(200), calendar: cal), "And due again today.")
    }

    func testTheBoxNeverRunsOffTheEnd() {
        var c = Card(front: "a", back: "b")
        for i in 0..<20 { c.markCorrect(on: day(i * 40), calendar: cal) }
        XCTAssertEqual(c.box, Card.intervals.count)
    }

    /// The hardest cards come up while there is still attention for them,
    /// rather than at the end when everyone is tired.
    func testDueCardsComeBackHardestFirst() {
        var easy = Card(front: "easy", back: "x")
        easy.box = 4
        easy.due = day(-1)
        var hard = Card(front: "hard", back: "y")
        hard.box = 1
        hard.due = day(-1)

        let deck = Deck(name: "Biology", cards: [easy, hard])
        let order = deck.due(on: day(0), calendar: cal).map(\.front)
        XCTAssertEqual(order, ["hard", "easy"])
    }

    func testCardsNotYetDueAreLeftAlone() {
        var c = Card(front: "a", back: "b")
        c.markCorrect(on: day(0), calendar: cal)      // box 2, due tomorrow
        let deck = Deck(name: "d", cards: [c])
        XCTAssertEqual(deck.due(on: day(0), calendar: cal).count, 0)
        XCTAssertEqual(deck.due(on: day(1), calendar: cal).count, 1)
    }
}
