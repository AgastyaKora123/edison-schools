//
//  LessonsTests.swift
//  EdisonParentTests
//
//  "Give me a topic and a grade."
//
//  The maths questions are worked out by the app rather than written down,
//  which removes one risk (a typo in a file) and adds another (a wrong
//  formula, repeated for ever). So every generated answer is checked here by
//  doing the arithmetic independently - parsing the question back out of its
//  own text and recomputing it. A wrong answer in a revision app is worse
//  than no answer, because somebody would learn it.
//
//  The JavaScript copy runs the same checks in web/tests.html. The two are
//  not required to produce the same numbers, only to be right.
//

import XCTest
@testable import EdisonParent

final class LessonsTests: XCTestCase {

    private func book() throws -> LessonBook {
        guard let found = LessonLibrary.load(from: Bundle(for: LessonsTests.self)) else {
            throw XCTSkip("lessons.json is not in the test bundle's resources.")
        }
        return found
    }

    private func topics() throws -> [LessonTopic] { try book().topics }

    // MARK: - The library itself

    func testTheTopicsAreThere() throws {
        let all = try topics()
        XCTAssertGreaterThanOrEqual(all.count, 12, "the library is too thin to be worth offering")
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "two topics share an id")

        for t in all {
            XCTAssertFalse(t.name.isEmpty, "\(t.id) has no name")
            XCTAssertFalse(t.subject.isEmpty, "\(t.id) has no subject")
            if t.make == nil {
                XCTAssertFalse((t.grades ?? []).isEmpty, "written topic \(t.id) suits no grade")
                XCTAssertGreaterThanOrEqual((t.cards ?? []).count, 8,
                                            "written topic \(t.id) is too thin")
                for c in t.cards ?? [] {
                    XCTAssertFalse(c.q.trimmingCharacters(in: .whitespaces).isEmpty,
                                   "a card in \(t.id) has no question")
                    XCTAssertFalse(c.a.trimmingCharacters(in: .whitespaces).isEmpty,
                                   "a card in \(t.id) has no answer")
                }
            } else {
                XCTAssertFalse((t.byGrade ?? [:]).isEmpty,
                               "generated topic \(t.id) has no settings for any grade")
            }
        }
    }

    func testEveryGradeHasSomethingToOffer() throws {
        let all = try topics()
        for grade in try book().grades {
            let offered = LessonLibrary.forGrade(grade, in: all)
            XCTAssertGreaterThanOrEqual(offered.count, 5,
                                        "grade \(grade) has almost nothing to practise")
        }
    }

    /// Someone typing a topic should not have to guess the filing. A partial
    /// word, the wrong case and a subject name should all find something.
    func testSearchIsForgiving() throws {
        let all = try topics()
        XCTAssertFalse(LessonLibrary.search("frac", grade: 5, in: all).isEmpty)
        XCTAssertFalse(LessonLibrary.search("FRACTIONS", grade: 5, in: all).isEmpty)
        XCTAssertFalse(LessonLibrary.search("times", grade: 4, in: all).isEmpty)
        XCTAssertFalse(LessonLibrary.search("maths", grade: 4, in: all).isEmpty)
        XCTAssertTrue(LessonLibrary.search("quantum chromodynamics", grade: 4, in: all).isEmpty,
                      "a topic nobody wrote should come back empty, not wrong")
    }

    func testAGradeOnlyOffersWhatSuitsIt() throws {
        let all = try topics()
        // Percentages start at grade 5 in the library; grade 3 should not see them.
        let young = LessonLibrary.forGrade(3, in: all).map(\.id)
        XCTAssertFalse(young.contains("percent-of"),
                       "a third grader is being offered percentages")
        let older = LessonLibrary.forGrade(7, in: all).map(\.id)
        XCTAssertTrue(older.contains("percent-of"))
    }

    // MARK: - Checking the maths by doing it again

    private func gcd(_ x: Int, _ y: Int) -> Int {
        var a = x, b = y
        while b != 0 { let t = a % b; a = b; b = t }
        return a
    }

    /// Pulls the numbers back out of a question and says whether the answer
    /// given is the right one. Returns nil if the question is not in the
    /// shape this topic is supposed to produce, which is itself a failure.
    private func isCorrect(topicId: String, q: String, a: String) -> Bool? {
        func ints(_ s: String) -> [Int] {
            s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        }
        let n = ints(q)

        // Fractions are the one topic whose answer is not a plain number.
        if topicId == "simplifying-fractions" {
            let parts = a.split(separator: "/").compactMap { Int($0) }
            guard parts.count == 2, n.count == 2, n[1] != 0 else { return nil }
            let g = gcd(n[0], n[1])
            return parts[0] == n[0] / g
                && parts[1] == n[1] / g
                && gcd(parts[0], parts[1]) == 1
                && parts[1] != n[1]          // it really was reducible
        }

        guard let answer = Int(a) else { return nil }

        switch topicId {
        case "times-tables":
            guard n.count == 2 else { return nil }
            return answer == n[0] * n[1]

        case "division-facts":
            guard n.count == 2, n[1] != 0, n[0] % n[1] == 0 else { return nil }
            return answer == n[0] / n[1]

        case "adding-subtracting":
            guard n.count == 2 else { return nil }
            if q.contains("+") { return answer == n[0] + n[1] }
            guard q.contains("\u{2212}") else { return nil }
            return n[0] >= n[1] && answer == n[0] - n[1]

        case "rounding":
            guard n.count == 1 else { return nil }
            let to = q.hasSuffix("ten") ? 10 : (q.hasSuffix("hundred") ? 100 : 1000)
            return answer == ((n[0] + to / 2) / to) * to

        case "place-value":
            guard n.count == 1 else { return nil }
            let places = ["ones", "tens", "hundreds", "thousands",
                          "ten thousands", "hundred thousands"]
            // Longest first, so "ten thousands" is not read as "tens".
            guard let place = places.enumerated()
                .sorted(by: { $0.element.count > $1.element.count })
                .first(where: { q.contains(" \($0.element) place") })?.offset
            else { return nil }
            var digits = n[0]
            for _ in 0..<place { digits /= 10 }
            return answer == digits % 10

        case "percent-of":
            guard n.count == 2 else { return nil }
            return answer == n[0] * n[1] / 100

        case "area-perimeter":
            guard n.count == 2 else { return nil }
            if q.contains("area") { return answer == n[0] * n[1] }
            guard q.contains("perimeter") else { return nil }
            return answer == 2 * (n[0] + n[1])

        default:
            return nil
        }
    }

    /// The one that matters. Every generated topic, every grade it claims to
    /// support, three different seeds: each answer recomputed from scratch.
    func testEveryGeneratedAnswerIsActuallyCorrect() throws {
        let all = try topics()
        var checked = 0

        for topic in all where topic.make != nil {
            for key in (topic.byGrade ?? [:]).keys.sorted() {
                guard let grade = Int(key) else { continue }
                for seed in [UInt32(1), 777, 20_261_124] {
                    guard let made = LessonLibrary.make(topicId: topic.id,
                                                        grade: grade,
                                                        count: 20,
                                                        seed: seed,
                                                        in: all) else {
                        XCTFail("\(topic.id) grade \(grade) produced nothing")
                        continue
                    }

                    XCTAssertEqual(made.cards.count, 20,
                                   "\(topic.id) grade \(grade) seed \(seed) made only \(made.cards.count)")
                    XCTAssertEqual(Set(made.cards.map(\.q)).count, made.cards.count,
                                   "\(topic.id) grade \(grade) repeated a question")

                    for card in made.cards {
                        checked += 1
                        let verdict = isCorrect(topicId: topic.id, q: card.q, a: card.a)
                        XCTAssertNotNil(verdict,
                                        "\(topic.id): could not read back \"\(card.q)\" -> \"\(card.a)\"")
                        XCTAssertEqual(verdict, true,
                                       "\(topic.id) grade \(grade): WRONG \"\(card.q)\" -> \"\(card.a)\"")
                    }
                }
            }
        }

        // If the loop silently did nothing, the test above would pass while
        // checking nothing at all. This is the guard against that.
        XCTAssertGreaterThan(checked, 1000, "barely any questions were checked")
    }

    // MARK: - What comes out the other end

    func testAWrittenTopicBecomesADeckOfItsOwn() throws {
        let all = try topics()
        guard let made = LessonLibrary.make(topicId: "planets", grade: 4, count: 20, seed: 1, in: all) else {
            return XCTFail("the planets topic did not build")
        }
        XCTAssertEqual(made.name, "The planets \u{00b7} grade 4")
        XCTAssertGreaterThanOrEqual(made.cards.count, 8)

        let deck = LessonLibrary.deck(from: made)
        XCTAssertEqual(deck.lessonId, "planets")
        XCTAssertNil(deck.packId, "a lesson is not a ready-made set")
        XCTAssertEqual(deck.cards.count, made.cards.count)
        XCTAssertEqual(deck.cards.first?.front, made.cards.first?.q)
        XCTAssertEqual(deck.cards.first?.back, made.cards.first?.a)
        XCTAssertTrue(deck.cards.allSatisfy { $0.box == 1 },
                      "a new deck should be entirely due")
    }

    func testAskingTwiceGivesDifferentQuestions() throws {
        let all = try topics()
        let first = LessonLibrary.make(topicId: "times-tables", grade: 5, count: 20, seed: 1, in: all)
        let second = LessonLibrary.make(topicId: "times-tables", grade: 5, count: 20, seed: 2, in: all)
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        XCTAssertNotEqual(first?.cards.map(\.q), second?.cards.map(\.q),
                          "two different seeds gave the identical set")
    }

    func testTheSameSeedGivesTheSameQuestions() throws {
        let all = try topics()
        let a = LessonLibrary.make(topicId: "rounding", grade: 4, count: 10, seed: 99, in: all)
        let b = LessonLibrary.make(topicId: "rounding", grade: 4, count: 10, seed: 99, in: all)
        XCTAssertEqual(a?.cards, b?.cards)
    }

    func testAskingForAGradeATopicDoesNotSupportGivesNothing() throws {
        let all = try topics()
        XCTAssertNil(LessonLibrary.make(topicId: "percent-of", grade: 3, count: 20, seed: 1, in: all),
                     "percentages are not a grade 3 topic and should not be built")
        XCTAssertNil(LessonLibrary.make(topicId: "no-such-topic", grade: 5, count: 20, seed: 1, in: all))
    }

    /// The bug that prompted the number generator to be replaced: with a weak
    /// one, a request for twenty percentage questions came back with five.
    func testTheThinnestTopicStillFillsASet() throws {
        let all = try topics()
        for grade in [5, 6, 7, 8] {
            let made = LessonLibrary.make(topicId: "percent-of", grade: grade, count: 20, seed: 3, in: all)
            XCTAssertEqual(made?.cards.count, 20,
                           "percentages at grade \(grade) could not fill a set of 20")
        }
    }
}
