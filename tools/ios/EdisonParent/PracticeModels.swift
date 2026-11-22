//
//  PracticeModels.swift
//  Schoolo
//
//  A deck of cards, and when to show each one again.
//
//  The scheduling is Leitner boxes, deliberately: five boxes, get it right
//  and the card moves up and comes back later, get it wrong and it drops
//  straight to box one and comes back today. It is not the cleverest
//  algorithm going, but every interval in it can be explained to the person
//  using it in one sentence, and a student who can see why a card came back
//  trusts the thing. A black box that says "trust me, review this" does not
//  get used twice.
//

import Foundation

struct Card: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var front: String
    var back: String

    /// 1...5. New cards start at 1, which means "due now".
    var box: Int = 1
    /// The day this card next comes up. Stored as a date, compared by day.
    var due: Date = .distantPast
    var seen: Int = 0
    var correct: Int = 0

    /// How many days each box waits before the card comes back.
    ///
    /// Roughly tripling: today, tomorrow, later this week, next week, in
    /// three weeks. Close enough to how memory actually fades, and short
    /// enough that a student revising for Friday still sees everything.
    static let intervals = [0, 1, 3, 7, 21]

    func interval(forBox b: Int) -> Int {
        let i = min(max(b, 1), Self.intervals.count) - 1
        return Self.intervals[i]
    }

    /// Answered correctly: up a box, and away for longer.
    mutating func markCorrect(on day: Date, calendar: Calendar = .current) {
        seen += 1
        correct += 1
        box = min(box + 1, Self.intervals.count)
        due = calendar.date(byAdding: .day, value: interval(forBox: box), to: calendar.startOfDay(for: day))
            ?? day
    }

    /// Got it wrong: all the way back to box one, due again today.
    ///
    /// Not down one box. A card you have just failed is a card you do not
    /// know, whatever you managed last week, and pretending otherwise is how
    /// people end up "revising" things they cannot recall.
    mutating func markWrong(on day: Date, calendar: Calendar = .current) {
        seen += 1
        box = 1
        due = calendar.startOfDay(for: day)
    }

    func isDue(on day: Date, calendar: Calendar = .current) -> Bool {
        due <= calendar.startOfDay(for: day)
    }
}

struct Deck: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var created: Date = Date()
    var cards: [Card] = []

    /// The cards waiting today, hardest first.
    ///
    /// Low boxes first means the things being got wrong come up while there
    /// is still attention left for them, rather than at the end of a session
    /// when everyone is tired.
    func due(on day: Date, calendar: Calendar = .current) -> [Card] {
        cards.filter { $0.isDue(on: day, calendar: calendar) }
            .sorted { $0.box < $1.box }
    }

    /// Of the cards seen at least once, how many are in the top two boxes.
    /// Shown as "learned", because that is what it means to a person.
    var learned: Int {
        cards.filter { $0.box >= 4 }.count
    }

    var started: Int {
        cards.filter { $0.seen > 0 }.count
    }
}
