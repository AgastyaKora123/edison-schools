//
//  PracticePacksTests.swift
//  EdisonParentTests
//
//  The ready-made practice sets that ship inside the app.
//
//  The times tables are checked by doing the multiplication here, in Swift,
//  rather than trusting the script that wrote the file. A wrong answer in a
//  revision app is worse than no answer: somebody would learn it.
//

import XCTest
@testable import EdisonParent

final class PracticePacksTests: XCTestCase {

    private func packs() throws -> [PracticePack] {
        let found = PackLibrary.load(from: Bundle(for: PracticePacksTests.self))
        if found.isEmpty {
            throw XCTSkip("practice-packs.json is not in the test bundle's resources.")
        }
        return found
    }

    func testTheSetsAreThere() throws {
        let all = try packs()
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(Set(all.map(\.id)),
                       ["times-tables", "states-capitals", "science-words", "test-vocabulary"])
    }

    func testEveryCardHasBothSides() throws {
        for pack in try packs() {
            XCTAssertFalse(pack.name.isEmpty, "\(pack.id) has no name")
            XCTAssertFalse(pack.subject.isEmpty, "\(pack.id) has no subject")
            XCTAssertGreaterThanOrEqual(pack.cards.count, 20, "\(pack.id) is too thin to be worth offering")

            for card in pack.cards {
                XCTAssertFalse(card.q.trimmingCharacters(in: .whitespaces).isEmpty,
                               "a card in \(pack.id) has no question")
                XCTAssertFalse(card.a.trimmingCharacters(in: .whitespaces).isEmpty,
                               "a card in \(pack.id) has no answer: \(card.q)")
            }
        }
    }

    func testNoCardIsAskedTwiceInTheSameSet() throws {
        for pack in try packs() {
            let fronts = pack.cards.map { $0.q.lowercased() }
            XCTAssertEqual(Set(fronts).count, fronts.count,
                           "\(pack.id) asks the same question twice")
        }
    }

    /// Done independently of the script that generated the file.
    func testTheTimesTablesAreActuallyCorrect() throws {
        guard let tables = try packs().first(where: { $0.id == "times-tables" }) else {
            return XCTFail("no times tables set")
        }
        var checked = 0
        for card in tables.cards {
            let parts = card.q.components(separatedBy: "\u{00D7}")
            XCTAssertEqual(parts.count, 2, "cannot read \(card.q)")
            guard parts.count == 2,
                  let a = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let b = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
                return XCTFail("cannot read \(card.q)")
            }
            XCTAssertEqual(Int(card.a), a * b, "\(card.q) says \(card.a)")
            checked += 1
        }
        XCTAssertEqual(checked, 28, "6 to 12, each pair once, is 28 cards")
    }

    func testCapitalsAreAllFiftyStates() throws {
        guard let states = try packs().first(where: { $0.id == "states-capitals" }) else {
            return XCTFail("no states set")
        }
        XCTAssertEqual(states.cards.count, 50)
        // Spot checks on the ones people get wrong, because the biggest city
        // is somewhere else.
        func answer(_ state: String) -> String? {
            states.cards.first { $0.q.contains(state) }?.a
        }
        XCTAssertEqual(answer("New York"), "Albany")
        XCTAssertEqual(answer("Illinois"), "Springfield")
        XCTAssertEqual(answer("Nevada"), "Carson City")
        XCTAssertEqual(answer("Pennsylvania"), "Harrisburg")
        XCTAssertEqual(answer("New Jersey"), "Trenton")
    }

    // MARK: - Turning one into a deck

    func testAddingASetMakesAFreshDeckOfItsOwn() throws {
        let pack = try packs()[0]
        let deck = PackLibrary.deck(from: pack)

        XCTAssertEqual(deck.name, pack.name)
        XCTAssertEqual(deck.cards.count, pack.cards.count)
        XCTAssertEqual(deck.packId, pack.id, "the picker needs this to know it has been added")
        XCTAssertEqual(deck.cards.first?.front, pack.cards.first?.q)
        XCTAssertEqual(deck.cards.first?.back, pack.cards.first?.a)

        // Nothing learned yet, and everything due now: a set just added
        // should be ready to study, not scheduled for next week.
        for card in deck.cards {
            XCTAssertEqual(card.box, 1)
            XCTAssertEqual(card.seen, 0)
            XCTAssertTrue(card.isDue(on: Date()))
        }
    }

    /// Two copies of the same set must not share card identities, or
    /// answering one would move the other.
    func testTwoCopiesAreIndependent() throws {
        let pack = try packs()[0]
        let a = PackLibrary.deck(from: pack)
        let b = PackLibrary.deck(from: pack)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.cards.first?.id, b.cards.first?.id)
    }

    /// A deck saved by 1.2 has no packId at all. It must still load.
    func testDecksFromTheVersionBeforeStillDecode() throws {
        let json = """
        [{"id":"4E8F7D4E-0000-0000-0000-000000000001","name":"Biology",
          "created":0,"cards":[]}]
        """
        let decks = try JSONDecoder().decode([Deck].self, from: Data(json.utf8))
        XCTAssertEqual(decks.count, 1)
        XCTAssertNil(decks[0].packId)
        XCTAssertEqual(decks[0].name, "Biology")
    }
}
