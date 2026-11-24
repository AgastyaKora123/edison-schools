//
//  Lessons.swift
//  "Give me a topic and a grade, and make me something to practise."
//
//  Two kinds of topic live in lessons.json. A written one carries its cards.
//  A generated one names a maker in here, and the app works the questions out
//  itself - which is why maths never runs out and never gets a fact wrong.
//
//  The JavaScript copy in web/lessons.js does the same job. The two are NOT
//  required to produce the same numbers, unlike the answer engine, which must
//  agree word for word across platforms. A parent asking "is there school
//  tomorrow" must get one answer; a child practising times tables does not
//  care whether the phone picked 7 x 8 and the website picked 6 x 9. What
//  both sides are held to, in their own tests, is that the answers are right,
//  that a set of 20 is 20, and that nothing repeats.
//

import Foundation

// MARK: - The shared number sequence

/// Xorshift32. Here so a set of questions is repeatable from a seed, not
/// because anything depends on it being unpredictable.
///
/// This began as a multiply-and-add generator and had to be replaced: the low
/// bits of that kind barely change, so `next() % 2` simply alternated and a
/// request for twenty percentage questions came back with five. Xorshift
/// mixes the whole word, so taking a remainder of a small number is safe.
struct LessonRandom {
    private var state: UInt32

    init(seed: UInt32) {
        state = seed == 0 ? 1 : seed
    }

    mutating func next() -> UInt32 {
        var x = state
        x ^= x << 13
        x ^= x >> 17
        x ^= x << 5
        state = x == 0 ? 1 : x
        return state
    }

    /// A whole number from `low` to `high`, both ends included.
    mutating func between(_ low: Int, _ high: Int) -> Int {
        guard high > low else { return low }
        return low + Int(next() % UInt32(high - low + 1))
    }

    mutating func pick(_ list: [Int]) -> Int {
        guard !list.isEmpty else { return 0 }
        return list[Int(next() % UInt32(list.count))]
    }
}

// MARK: - What a topic looks like

struct LessonCard: Codable, Equatable {
    var q: String
    var a: String
}

struct LessonTopic: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var subject: String
    var note: String?
    /// Present on a generated topic: names the maker to use.
    var make: String?
    /// Present on a generated topic: the settings for each grade.
    var byGrade: [String: GradeSettings]?
    /// Present on a written topic: which grades it suits.
    var grades: [Int]?
    /// Present on a written topic: the cards themselves.
    var cards: [LessonCard]?
}

/// The knobs a maker can be given. All optional because each maker uses its
/// own handful, and a missing one simply means that maker does not want it.
struct GradeSettings: Codable, Equatable {
    var low: Int?
    var high: Int?
    var max: Int?
    var to: Int?
    var digits: Int?
    var maxDenominator: Int?
    var percents: [Int]?
    var maxPower: Int?
}

struct LessonBook: Codable {
    var version: Int
    var grades: [Int]
    var topics: [LessonTopic]
}

/// A lesson once it has been built, before it becomes a deck of the user's own.
struct MadeLesson: Equatable {
    var topicId: String
    var name: String
    var subject: String
    var cards: [LessonCard]
}

// MARK: - The library

enum LessonLibrary {

    private static let places = ["ones", "tens", "hundreds", "thousands",
                                 "ten thousands", "hundred thousands"]

    /// Loaded once. A missing or unreadable file leaves an empty library and
    /// the screen simply does not offer topics, rather than crashing.
    static let book: LessonBook? = load()

    static func load(from bundle: Bundle = .main) -> LessonBook? {
        guard let url = bundle.url(forResource: "lessons", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LessonBook.self, from: data)
    }

    static var all: [LessonTopic] { book?.topics ?? [] }

    static var grades: [Int] { book?.grades ?? [3, 4, 5, 6, 7, 8] }

    static func suits(_ topic: LessonTopic, grade: Int) -> Bool {
        if topic.make != nil {
            return topic.byGrade?[String(grade)] != nil
        }
        return (topic.grades ?? []).contains(grade)
    }

    static func forGrade(_ grade: Int, in topics: [LessonTopic]? = nil) -> [LessonTopic] {
        (topics ?? all).filter { suits($0, grade: grade) }
    }

    /// Deliberately forgiving matching. A child typing a topic should not have
    /// to guess the exact words it was filed under, so every typed word only
    /// has to appear somewhere in the name, subject, note or id.
    static func search(_ text: String, grade: Int?, in topics: [LessonTopic]? = nil) -> [LessonTopic] {
        let pool = grade.map { forGrade($0, in: topics) } ?? (topics ?? all)
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return pool }
        let words = query.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        return pool.filter { topic in
            let hay = "\(topic.name) \(topic.subject) \(topic.note ?? "") \(topic.id)".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    static func byId(_ id: String, in topics: [LessonTopic]? = nil) -> LessonTopic? {
        (topics ?? all).first { $0.id == id }
    }

    // MARK: - The makers

    private static func makeCard(_ kind: String,
                                 _ r: inout LessonRandom,
                                 _ p: GradeSettings) -> LessonCard? {
        switch kind {
        case "timesTables":
            let a = r.between(p.low ?? 2, p.high ?? 12)
            let b = r.between(2, 12)
            return LessonCard(q: "\(a) \u{00d7} \(b)", a: String(a * b))

        case "division":
            let by = r.between(p.low ?? 2, p.high ?? 12)
            let answer = r.between(2, 12)
            return LessonCard(q: "\(by * answer) \u{00f7} \(by)", a: String(answer))

        case "addSubtract":
            let a = r.between(10, p.max ?? 99)
            let b = r.between(10, p.max ?? 99)
            if r.next() % 2 == 0 {
                return LessonCard(q: "\(a) + \(b)", a: String(a + b))
            }
            let big = Swift.max(a, b), small = Swift.min(a, b)
            return LessonCard(q: "\(big) \u{2212} \(small)", a: String(big - small))

        case "rounding":
            let to = p.to ?? 10
            let n = r.between(to, p.max ?? 999)
            let name = to == 10 ? "ten" : (to == 100 ? "hundred" : "thousand")
            let rounded = ((n + to / 2) / to) * to
            return LessonCard(q: "Round \(n) to the nearest \(name)", a: String(rounded))

        case "placeValue":
            let digits = p.digits ?? 3
            let low = Int(pow(10.0, Double(digits - 1)))
            let high = Int(pow(10.0, Double(digits))) - 1
            let n = r.between(low, high)
            let place = r.between(0, digits - 1)
            let digit = (n / Int(pow(10.0, Double(place)))) % 10
            return LessonCard(q: "Which digit is in the \(places[place]) place of \(n)?",
                              a: String(digit))

        case "simplifyFraction":
            let maxD = p.maxDenominator ?? 12
            var b = r.between(2, Swift.max(2, maxD / 2))
            var a = r.between(1, Swift.max(1, b - 1))
            let g = gcd(a, b)
            a /= g; b /= g
            if b < 2 { a = 1; b = 2 }
            let maxK = maxD / b
            let k = r.between(2, maxK < 2 ? 2 : maxK)
            return LessonCard(q: "Write \(a * k)/\(b * k) in its simplest form",
                              a: "\(a)/\(b)")

        case "percentOf":
            let percents = p.percents ?? [10, 50]
            let pc = r.pick(percents)
            let steps = Swift.max(1, (p.max ?? 100) / 20)
            let n = 20 * r.between(1, steps)
            return LessonCard(q: "What is \(pc)% of \(n)?", a: String(pc * n / 100))

        case "oneStepEquations":
            // Four shapes, so it is not the same sum dressed differently
            // twenty times.
            let x = r.between(1, p.max ?? 20)
            switch r.next() % 4 {
            case 0:
                let add = r.between(1, p.max ?? 20)
                return LessonCard(q: "Solve: x + \(add) = \(x + add)", a: String(x))
            case 1:
                // Never more than x, so the right-hand side cannot go
                // negative. Grade 6 meets this before negative numbers.
                let take = r.between(1, x)
                return LessonCard(q: "Solve: x \u{2212} \(take) = \(x - take)", a: String(x))
            case 2:
                let by = r.between(2, 12)
                return LessonCard(q: "Solve: \(by)x = \(by * x)", a: String(x))
            default:
                let div = r.between(2, 12)
                return LessonCard(q: "Solve: x \u{00f7} \(div) = \(x)", a: String(div * x))
            }

        case "negativeNumbers":
            // The second number is always positive, so a question never
            // reads "5 + −3", which is a different skill and a different
            // lesson.
            let max = p.max ?? 20
            let a = r.between(-max, max)
            let b = r.between(1, max)
            let plus = r.next() % 2 == 0
            let result = plus ? a + b : a - b
            return LessonCard(q: "\(neg(a))\(plus ? " + " : " \u{2212} ")\(b)",
                              a: neg(result))

        case "exponents":
            let base = r.between(p.low ?? 2, p.high ?? 12)
            let power = r.between(2, p.maxPower ?? 3)
            var value = 1
            for _ in 0..<power { value *= base }
            return LessonCard(q: "\(base) to the power of \(power)", a: String(value))

        case "volumeBox":
            let a = r.between(2, p.max ?? 8)
            let b = r.between(2, p.max ?? 8)
            let c = r.between(2, p.max ?? 8)
            return LessonCard(q: "A box is \(a) by \(b) by \(c). What is its volume?",
                              a: String(a * b * c))

        case "addFractionsSame":
            // Same denominator only. The answer is always in its simplest
            // form, because that is what a teacher will be marking.
            let d = r.between(3, p.maxDenominator ?? 10)
            let a = r.between(1, d - 1)
            let b = r.between(1, d - a)
            let top = a + b
            let answer: String
            if top == d {
                answer = "1"
            } else {
                let g = gcd(top, d)
                answer = "\(top / g)/\(d / g)"
            }
            return LessonCard(q: "\(a)/\(d) + \(b)/\(d)", a: answer)

        case "primeOrComposite":
            // From 10 up, so the answer is never obvious at a glance.
            let n = r.between(10, p.max ?? 50)
            var prime = true
            var i = 2
            while i * i <= n {
                if n % i == 0 { prime = false; break }
                i += 1
            }
            return LessonCard(q: "Is \(n) prime or composite?",
                              a: prime ? "Prime" : "Composite")

        case "areaPerimeter":
            let w = r.between(2, p.max ?? 10)
            let h = r.between(2, p.max ?? 10)
            if r.next() % 2 == 0 {
                return LessonCard(q: "A rectangle is \(w) by \(h). What is its area?",
                                  a: String(w * h))
            }
            return LessonCard(q: "A rectangle is \(w) by \(h). What is its perimeter?",
                              a: String(2 * (w + h)))

        default:
            return nil
        }
    }

    /// A minus sign, not a hyphen. The same character is used for
    /// subtraction throughout, so a question and its answer look consistent.
    private static func neg(_ n: Int) -> String {
        n < 0 ? "\u{2212}\(abs(n))" : String(n)
    }

    static func gcd(_ x: Int, _ y: Int) -> Int {
        var a = x, b = y
        while b != 0 { let t = a % b; a = b; b = t }
        return a == 0 ? 1 : a
    }

    // MARK: - Building one

    /// A written topic hands back what it holds. A generated one is worked
    /// out, skipping repeats so a set of 20 really is 20 different questions.
    static func make(topicId: String,
                     grade: Int,
                     count: Int = 20,
                     seed: UInt32 = 1,
                     in topics: [LessonTopic]? = nil) -> MadeLesson? {
        guard let topic = byId(topicId, in: topics), suits(topic, grade: grade) else { return nil }
        let title = "\(topic.name) \u{00b7} grade \(grade)"

        guard let kind = topic.make else {
            return MadeLesson(topicId: topic.id,
                              name: title,
                              subject: topic.subject,
                              cards: Array((topic.cards ?? []).prefix(count)))
        }

        guard let params = topic.byGrade?[String(grade)] else { return nil }
        var rand = LessonRandom(seed: seed)
        var cards: [LessonCard] = []
        var seen = Set<String>()
        var tries = 0
        while cards.count < count && tries < count * 40 {
            tries += 1
            guard let card = makeCard(kind, &rand, params) else { return nil }
            if seen.contains(card.q) { continue }
            seen.insert(card.q)
            cards.append(card)
        }
        return MadeLesson(topicId: topic.id, name: title, subject: topic.subject, cards: cards)
    }
}

// MARK: - Turning one into a deck

extension LessonLibrary {
    /// No packId on purpose: a maths topic can be asked for again and again,
    /// and each time should be a new deck of fresh questions rather than a row
    /// that says "already added".
    static func deck(from made: MadeLesson) -> Deck {
        Deck(name: made.name,
             cards: made.cards.map { Card(front: $0.q, back: $0.a) },
             lessonId: made.topicId)
    }
}
