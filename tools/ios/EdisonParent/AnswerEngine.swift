//
//  AnswerEngine.swift
//  Edison Parent
//
//  Port of engine/Answer-Query.ps1. That PowerShell script is the oracle and
//  tests/questions.jsonl is the contract: EdisonParentTests runs the same
//  cases against this code, so a divergence fails the build rather than
//  shipping a wrong answer.
//
//  Deterministic and fully offline - no model call, no network. For the
//  questions parents actually ask ("is there school tomorrow", "what time does
//  middle school start", "when is spring break", "who do I call") the answer
//  has to be a specific date or time, so a resolver over structured data beats
//  retrieval over prose.
//

import Foundation

struct AnswerEngine {

    let pack: KnowledgePack
    let rules: Rules

    /// All dates are interpreted in the district's own time zone, so a parent
    /// asking at 11pm Pacific still gets the district's "tomorrow".
    private let calendar: Calendar

    /// Every link an answer cites comes from the pack, never from a constant
    /// in here. Hard-coded links are how a parent in another district ended
    /// up being given Edison's phone number when they asked about absences.
    struct DistrictLinks {
        var site: String
        var calendar: String
        var events: String
        var hours: String
        var feed: String
    }
    let links: DistrictLinks

    /// The district's name, short enough to put in a sentence.
    let districtShort: String

    /// How to refer to all of them at once: "Edison schools", or "schools in
    /// the district" when the pack does not name one.
    let allSchoolsLabel: String

    /// Words worth ignoring when searching the district's pages. The
    /// district's own name is noise - every page says it - and which words
    /// those are depends on the district, so the list is built per district
    /// rather than written down with one district's name in it.
    let stop: Set<String>

    /// Whether this district publishes its school-day calendar at all.
    ///
    /// Plenty of them do not. They publish events - board meetings, job
    /// fairs, graduations - and keep term dates in a PDF somewhere else.
    /// Conroe ISD is one: 66 entries and not a single closing, break or
    /// early dismissal among them. A sample of twelve districts suggested
    /// about half are like this.
    ///
    /// It matters because without it "is there school tomorrow" is answered
    /// "yes, open" purely because the date is a Tuesday. That is a guess
    /// dressed up as a fact, and the day it is wrong is a holiday - the exact
    /// day a parent most needs it right.
    let publishesSchoolSchedule: Bool

    /// The kinds of entry that make a calendar a school calendar rather than
    /// a list of events.
    static let scheduleKinds: Set<String> = [
        "closed", "break", "early_dismissal", "single_session",
        "delayed_opening", "no_school_students", "first_day", "last_day"
    ]

    init(pack: KnowledgePack, rules: Rules) {
        self.pack = pack
        self.rules = rules
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: pack.district.timeZone) ?? TimeZone(identifier: "America/New_York")!
        cal.locale = Locale(identifier: "en_US")
        self.calendar = cal

        let site = pack.district.url
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        func page(_ key: String, _ fallback: String) -> String {
            if let p = pack.district.pages?[key], !p.isEmpty { return p }
            return site.isEmpty ? "" : site + fallback
        }
        self.links = DistrictLinks(
            site: site,
            calendar: page("calendar", "/page/district-yearly-calendar/"),
            events:   page("events",   "/events/"),
            hours:    page("hours",    "/page/school-hours/"),
            feed:     page("feed",     "/live-feed/"))

        let short = Self.shortDistrictName(pack.district.name)
        self.districtShort = short.isEmpty ? "the district" : short
        self.allSchoolsLabel = short.isEmpty ? "schools in the district" : short + " schools"

        var words = Self.stopWords
        for w in pack.district.name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted) where w.count > 2 {
            words.insert(w)
        }
        self.stop = words

        self.publishesSchoolSchedule = pack.calendar.contains {
            Self.scheduleKinds.contains($0.kind)
        }
    }

    /// What to say when the district simply has not published the thing being
    /// asked about. Naming the district makes clear it is them and not the
    /// app, and the link is where the answer actually lives.
    func noScheduleAnswer(_ intent: String) -> Answer {
        var t = "\(districtShort) publishes events to its calendar but not its school-day schedule, "
        t += "so I don't know its closings, breaks or early dismissals."
        if !links.calendar.isEmpty {
            t += "\n\nThose are usually on the district's own calendar page."
        }
        return make(t, intent: intent, kind: "no_schedule",
                    sources: [links.calendar, links.site], confidence: 0.6)
    }

    /// "Edison Township Public Schools" -> "Edison". "Conroe ISD" -> "Conroe".
    /// Districts name themselves in half a dozen house styles; what a parent
    /// calls theirs is almost always the first distinctive word or two.
    ///
    /// Mirrors Get-ShortDistrictName in engine/Answer-Query.ps1 and
    /// shortenDistrict in web/engine.js, including the order of the two
    /// passes - qualifiers first, then the kind of body it is.
    static func shortDistrictName(_ full: String) -> String {
        guard !full.isEmpty else { return "" }
        let qualifiers = "\\b(independent|unified|consolidated|community|county|township|city|area|regional|local|joint|union|central|public|charter)\\b"
        let kinds = "\\b(school district|schools district|school system|schools|school|district|isd|usd|cusd|cisd|sd|psd|cs|academy|academies|corporation|corp)\\b"

        var s = full.replacingOccurrences(of: qualifiers, with: " ",
                                          options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: kinds, with: " ",
                                   options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        // Stripping everything means the name was made only of those words.
        // Fall back to what the district actually calls itself.
        if s.isEmpty {
            s = full.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        return s.split(separator: " ").prefix(2).joined(separator: " ")
    }

    // MARK: - Entry point

    func answer(_ query: String, today: Date = Date(), defaultSchoolId: String = "") -> Answer {
        let norm = Self.normalize(query)
        let todayStart = calendar.startOfDay(for: today)

        guard !norm.isEmpty else {
            return make("Ask me anything about (allSchoolsLabel) - hours, closings, the calendar, absences.",
                        intent: "empty", kind: "empty", confidence: 0,
                        debug: .init(resolver: "empty", topIntent: "", topScore: 0,
                                     dateSlot: "", schoolSlot: "", levelSlot: "",
                                     scheduleSlot: "", breakSlot: ""))
        }

        var school = resolveSchool(norm)
        if school == nil, !defaultSchoolId.isEmpty {
            school = pack.schools.first { $0.id == defaultSchoolId }
        }

        let ctx = Context(
            query: query,
            norm: norm,
            today: todayStart,
            school: school,
            level: resolveLevel(norm),
            date: resolveDate(norm, today: todayStart),
            scheduleKind: resolveScheduleKind(norm),
            breakName: resolveBreak(norm),
            counting: Self.asksForCount(norm)
        )

        let scores = intentScores(norm)
        let top = scores.first

        // Below this, the query is not clearly any intent - retrieval is a
        // better bet than a resolver guessing at a date.
        var resolver = (top?.score ?? 0) >= 3.0 ? (top?.resolver ?? "fact_search") : "fact_search"

        // Slot evidence disambiguates intents that share vocabulary.
        if ctx.breakName != nil, !Self.containsPhrase(norm, "next") {
            resolver = "break_dates"
        } else if (Self.containsPhrase(norm, "next") || Self.containsPhrase(norm, "upcoming")),
                  ctx.scheduleKind != nil, ctx.date == nil {
            resolver = "next_occurrence"
        }

        // Counting or enumerating is the list question, however it is worded.
        // Without this, "how many early dismissal days are in this school
        // year" landed on day_schedule, found no date, and answered about
        // today - "Saturday, November 21 is a Saturday, so there is no
        // school." Keying off the shape of the question is what fixes that
        // for phrasings nobody has thought of yet.
        if Self.oneDayResolvers.contains(resolver), ctx.date == nil {
            if Self.asksForAll(norm),
               ctx.scheduleKind != nil || Self.matches(norm, Self.multiDaySubjectRe) {
                resolver = "list_occurrences"
            } else if Self.asksForCount(norm) {
                // Counting something that is not on the calendar at all -
                // "how many schools are in the district". Still not a
                // question about today.
                resolver = "fact_search"
            }
        }

        let debug = Answer.Debug(
            resolver: resolver,
            topIntent: top?.id ?? "",
            topScore: top?.score ?? 0,
            dateSlot: ctx.date.map { "\(Self.iso($0.start))..\(Self.iso($0.end)) (\($0.phrase))" } ?? "",
            schoolSlot: ctx.school?.id ?? "",
            levelSlot: ctx.level ?? "",
            scheduleSlot: ctx.scheduleKind ?? "",
            breakSlot: ctx.breakName ?? ""
        )

        var result: Answer
        switch resolver {
        case "school_status":   result = resolveSchoolStatus(ctx)
        case "day_schedule":    result = resolveDaySchedule(ctx)
        case "bell_times":      result = resolveBellTimes(ctx)
        case "next_occurrence": result = resolveNextOccurrence(ctx)
        case "break_dates":     result = resolveBreakDates(ctx)
        case "calendar_list":   result = resolveCalendarList(ctx)
        case "list_occurrences": result = resolveListOccurrences(ctx)
        case "absence_report":  result = resolveAbsenceReport(ctx)
        case "contact_info":    result = resolveContactInfo(ctx)
        default:                result = resolveFactSearch(ctx)
        }
        result.debug = debug
        return result
    }

    // MARK: - Context

    struct Context {
        var query: String
        var norm: String
        var today: Date
        var school: School?
        var level: String?
        var date: DateSlot?
        var scheduleKind: String?
        var breakName: String?
        /// They asked for a number, so the list answer leads with one.
        var counting: Bool = false
    }

    struct DateSlot {
        var start: Date
        var end: Date
        var isRange: Bool
        var phrase: String
    }

    // MARK: - Text normalisation

    static func normalize(_ q: String) -> String {
        var s = q.lowercased()
        s = s.replacingOccurrences(of: "\u{2018}", with: "'")
        s = s.replacingOccurrences(of: "\u{2019}", with: "'")
        s = s.replacingOccurrences(of: "\u{02bc}", with: "'")
        s = s.replacingOccurrences(of: "&", with: " and ")
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789/:'-. ")
        s = String(s.map { allowed.contains($0) ? $0 : " " })
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func tokens(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Whole-word phrase containment, so "sun" does not match "sunday".
    static func containsPhrase(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: needle)
            .replacingOccurrences(of: "\\ ", with: "\\s+")
        let pattern = "(?<![a-z0-9])\(escaped)(?![a-z0-9])"
        return haystack.range(of: pattern, options: .regularExpression) != nil
    }

    static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    static func capture(_ s: String, _ pattern: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    // MARK: - The shape of the question

    // Whether someone wants a number, a list, or a yes-or-no about one day is
    // a property of the SHAPE of the question, not of its vocabulary. "How
    // many early dismissals are there this year" and "is today an early
    // dismissal" share every keyword that matters; only the shape separates
    // them. A word list in the rules file will always miss a phrasing. This
    // does not, which is why the routing below keys off it.
    //
    // These four mirror COUNTING_RE, SPAN_RE, ENUMERATE_RE and
    // MULTI_DAY_SUBJECT in web/engine.js, and the same four in
    // engine/Answer-Query.ps1. Change one, change all three.
    static let countingRe =
        "(?:^|[^a-z0-9])(how many|how much|how often|number of|count of)(?:[^a-z0-9]|$)"
    static let spanRe =
        "(?:^|[^a-z0-9])(this (school )?year|the (school )?year|whole year|rest of the|all year|left|remaining)(?:[^a-z0-9]|$)"
    static let enumerateRe =
        "(?:^|[^a-z0-9])(list|every|all the|all of the)(?:[^a-z0-9]|$)"
    static let multiDaySubjectRe =
        "(?:^|[^a-z0-9])(days? off|holidays?|closings?|closures?|no school|half days?|early dismissals?|single sessions?|late starts?|delayed openings?|snow days?)(?:[^a-z0-9]|$)"

    /// Resolvers that answer about one particular day. Any of them reached by
    /// a counting question is a routing mistake, not a hard question.
    static let oneDayResolvers: Set<String> =
        ["school_status", "day_schedule", "bell_times", "fact_search"]

    static func asksForCount(_ norm: String) -> Bool { matches(norm, countingRe) }

    static func asksForAll(_ norm: String) -> Bool {
        matches(norm, countingRe) || matches(norm, enumerateRe) || matches(norm, spanRe)
    }

    // MARK: - Date slot

    func resolveDate(_ norm: String, today: Date) -> DateSlot? {
        // 1. week / month ranges
        if Self.containsPhrase(norm, "next week") {
            let s = calendar.date(byAdding: .day, value: 7, to: weekStart(today))!
            return DateSlot(start: s, end: calendar.date(byAdding: .day, value: 6, to: s)!,
                            isRange: true, phrase: "next week")
        }
        if Self.containsPhrase(norm, "this week") {
            let s = weekStart(today)
            return DateSlot(start: s, end: calendar.date(byAdding: .day, value: 6, to: s)!,
                            isRange: true, phrase: "this week")
        }
        if Self.containsPhrase(norm, "next month") {
            let first = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
            let s = calendar.date(byAdding: .month, value: 1, to: first)!
            let e = calendar.date(byAdding: .day, value: -1, to: calendar.date(byAdding: .month, value: 1, to: s)!)!
            return DateSlot(start: s, end: e, isRange: true, phrase: "next month")
        }
        if Self.containsPhrase(norm, "this month") {
            let s = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
            let e = calendar.date(byAdding: .day, value: -1, to: calendar.date(byAdding: .month, value: 1, to: s)!)!
            return DateSlot(start: s, end: e, isRange: true, phrase: "this month")
        }

        // 2. relative day words, longest first so "day after tomorrow" wins
        for key in rules.dateWords.keys.sorted(by: { $0.count > $1.count }) {
            if Self.containsPhrase(norm, key) {
                let d = calendar.date(byAdding: .day, value: rules.dateWords[key]!.offsetDays, to: today)!
                return DateSlot(start: d, end: d, isRange: false, phrase: key)
            }
        }

        // 3. month + day, either order
        let monthNames = rules.months.keys.sorted { $0.count > $1.count }
        let alt = monthNames.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")

        if let g = Self.capture(norm, "(?<![a-z])(\(alt))\\.?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:\\s*,?\\s*(\\d{4}))?(?![0-9])"),
           let mName = g[1], let dStr = g[2], let mo = rules.months[mName], let day = Int(dStr) {
            if let d = resolveMonthDay(month: mo, day: day, year: g.count > 3 ? Int(g[3] ?? "") : nil, today: today) {
                return DateSlot(start: d, end: d, isRange: false, phrase: "\(mName) \(dStr)")
            }
        }
        if let g = Self.capture(norm, "(?<![0-9])(\\d{1,2})(?:st|nd|rd|th)?\\s+(?:of\\s+)?(\(alt))\\.?(?:\\s*,?\\s*(\\d{4}))?(?![0-9])"),
           let dStr = g[1], let mName = g[2], let mo = rules.months[mName], let day = Int(dStr) {
            if let d = resolveMonthDay(month: mo, day: day, year: g.count > 3 ? Int(g[3] ?? "") : nil, today: today) {
                return DateSlot(start: d, end: d, isRange: false, phrase: "\(dStr) \(mName)")
            }
        }

        // 4. bare month name = that whole month.
        //    Checked BEFORE the numeric form, matching the order in
        //    engine/Answer-Query.ps1. The two only disagree on a query
        //    carrying both a month word and an M/D number, but the engines
        //    are only an oracle for each other if they stay in step.
        for n in monthNames where Self.containsPhrase(norm, n) {
            let mo = rules.months[n]!
            var comps = calendar.dateComponents([.year, .month], from: today)
            var year = comps.year!
            if mo < comps.month! - 6 { year += 1 }
            comps = DateComponents(year: year, month: mo, day: 1)
            guard let s = calendar.date(from: comps) else { continue }
            let e = calendar.date(byAdding: .day, value: -1, to: calendar.date(byAdding: .month, value: 1, to: s)!)!
            return DateSlot(start: s, end: e, isRange: true, phrase: n)
        }

        // 5. numeric M/D, M/D/YY
        if let g = Self.capture(norm, "(?<![0-9])(\\d{1,2})[/\\-](\\d{1,2})(?:[/\\-](\\d{2,4}))?(?![0-9])"),
           let mStr = g[1], let dStr = g[2], let mo = Int(mStr), let day = Int(dStr) {
            var year: Int? = nil
            if g.count > 3, let yStr = g[3], var y = Int(yStr) {
                if y < 100 { y += 2000 }
                year = y
            }
            if let d = resolveMonthDay(month: mo, day: day, year: year, today: today) {
                return DateSlot(start: d, end: d, isRange: false, phrase: "\(mStr)/\(dStr)")
            }
        }

        // 5b. named holidays. Longest name first, so "christmas eve" is not
        //     swallowed by "christmas". These are days nobody puts on a
        //     school calendar - the calendar has "Winter Recess", not
        //     "Christmas Eve" - but which parents ask about by name. Without
        //     this, "is there school on christmas eve" found no date at all
        //     and was answered about today.
        for n in (rules.holidays ?? [:]).keys.sorted(by: { $0.count > $1.count })
        where Self.containsPhrase(norm, n) {
            guard let md = rules.holidays?[n], md.count >= 2 else { continue }
            if let d = resolveMonthDay(month: md[0], day: md[1], year: nil, today: today) {
                return DateSlot(start: d, end: d, isRange: false, phrase: n)
            }
        }

        // 6. weekday names. "next friday" = first Friday strictly after today;
        //    bare / "this" friday = first Friday from today onward.
        for n in rules.weekdays.keys.sorted(by: { $0.count > $1.count }) where Self.containsPhrase(norm, n) {
            let target = rules.weekdays[n]!     // Sunday = 0, matching .weekday - 1
            let isNext = Self.matches(norm, "(?<![a-z])next\\s+\(NSRegularExpression.escapedPattern(for: n))")
            let d = nextWeekday(from: today, weekday: target, strictlyAfter: isNext)
            return DateSlot(start: d, end: d, isRange: false, phrase: isNext ? "next \(n)" : n)
        }

        return nil
    }

    /// Picks the year that makes a bare "march 10" read naturally: future
    /// readings are cheap, past ones cost triple, so in November "march 10"
    /// means next March.
    func resolveMonthDay(month: Int, day: Int, year: Int?, today: Date) -> Date? {
        guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }
        if let y = year, y > 0 {
            return calendar.date(from: DateComponents(year: y, month: month, day: day))
        }
        let thisYear = calendar.component(.year, from: today)
        var best: Date? = nil
        var bestScore = Double.greatestFiniteMagnitude
        for y in [thisYear - 1, thisYear, thisYear + 1] {
            guard let cand = calendar.date(from: DateComponents(year: y, month: month, day: day)) else { continue }
            // Reject rolled-over dates (Feb 30 becomes Mar 2).
            guard calendar.component(.month, from: cand) == month,
                  calendar.component(.day, from: cand) == day else { continue }
            let delta = cand.timeIntervalSince(today) / 86400.0
            let score = delta >= -3 ? abs(delta) : abs(delta) * 3
            if score < bestScore { bestScore = score; best = cand }
        }
        return best
    }

    /// Monday-based week start, matching the PowerShell oracle.
    func weekStart(_ d: Date) -> Date {
        let dow = calendar.component(.weekday, from: d) - 1   // Sunday = 0
        let back = dow == 0 ? 6 : dow - 1
        return calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: d))!
    }

    func nextWeekday(from: Date, weekday: Int, strictlyAfter: Bool) -> Date {
        let start = strictlyAfter ? calendar.date(byAdding: .day, value: 1, to: from)! : from
        for i in 0..<8 {
            let d = calendar.date(byAdding: .day, value: i, to: start)!
            if calendar.component(.weekday, from: d) - 1 == weekday { return calendar.startOfDay(for: d) }
        }
        return from
    }

    // MARK: - Other slots

    func resolveSchool(_ norm: String) -> School? {
        var best: School? = nil
        var bestLen = 0
        for s in pack.schools {
            for term in s.matchTerms where term.count > bestLen {
                if Self.containsPhrase(norm, term) { best = s; bestLen = term.count }
            }
        }
        return best
    }

    /// Like containsPhrase, but lets the last word be plural. "How many late
    /// starts this year" was finding no schedule kind at all, because the
    /// list holds "late start" and the whole-word match stopped at the "s".
    /// Listing every plural by hand is the treadmill; allowing one is not.
    static func containsPhrasePlural(_ hay: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: needle)
            .replacingOccurrences(of: "\\ ", with: "\\s+")
        return matches(hay, "(?:^|[^a-z0-9])\(escaped)(?:es|s)?(?:[^a-z0-9]|$)")
    }

    /// Squash repeated letters: "dissmisal" and "dismissal" both become
    /// "dismisal". Doubled or dropped double letters are far and away the
    /// commonest typo in these particular words, and a parent typing
    /// "dissmisal" means exactly what a parent typing "dismissal" means.
    static func squashDoubles(_ s: String) -> String {
        s.replacingOccurrences(of: "([a-z])\\1+", with: "$1", options: .regularExpression)
    }

    /// The longest matching word wins, so "early dismissal" beats "early".
    /// Exact matches are tried across the whole list first; only if nothing
    /// matches at all is the typo-tolerant pass used, and then only on words
    /// of six letters or more - on short words squashing destroys meaning,
    /// and a day "off" is not a day "of".
    static func longestMapMatch(_ norm: String, _ map: [String: [String]]) -> String? {
        var best: String? = nil
        var bestLen = 0
        for (key, words) in map {
            for w in words where w.count > bestLen && containsPhrasePlural(norm, w) {
                best = key; bestLen = w.count
            }
        }
        if best != nil { return best }

        let squashed = squashDoubles(norm)
        for (key, words) in map {
            for w in words where w.count > bestLen {
                guard w.filter({ $0.isLetter }).count >= 6 else { continue }
                if containsPhrasePlural(squashed, squashDoubles(w)) {
                    best = key; bestLen = w.count
                }
            }
        }
        return best
    }

    func resolveLevel(_ norm: String) -> String? {
        Self.longestMapMatch(norm, rules.levelWords)
    }

    func resolveScheduleKind(_ norm: String) -> String? {
        Self.longestMapMatch(norm, rules.scheduleWords)
    }

    func resolveBreak(_ norm: String) -> String? {
        Self.longestMapMatch(norm, rules.breaks)
    }

    // MARK: - Intent scoring

    struct ScoredIntent {
        var id: String
        var resolver: String
        var priority: Double
        var score: Double
    }

    func intentScores(_ norm: String) -> [ScoredIntent] {
        let toks = Set(Self.tokens(norm))
        var out: [ScoredIntent] = []

        for intent in rules.intents {
            // requireAny is a hard gate for intents whose patterns must be
            // broad: without it, "who do I contact about bullying" matches
            // absence_report's who/contact shape.
            if let req = intent.requireAny, !req.isEmpty {
                if !req.contains(where: { Self.containsPhrase(norm, $0) }) {
                    out.append(.init(id: intent.id, resolver: intent.resolver,
                                     priority: intent.priority, score: 0))
                    continue
                }
            }

            var score = 0.0
            for (k, w) in intent.keywords {
                if k.contains(" ") {
                    if Self.containsPhrase(norm, k) { score += w }
                } else if toks.contains(k) {
                    score += w
                }
            }
            for p in intent.patterns where Self.matches(norm, p) {
                score += 8.0
            }
            out.append(.init(id: intent.id, resolver: intent.resolver,
                             priority: intent.priority, score: score))
        }

        return out.sorted {
            $0.score != $1.score ? $0.score > $1.score : $0.priority > $1.priority
        }
    }

    // MARK: - Calendar lookup

    static func iso(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    func parsePackDate(_ s: String) -> Date? {
        guard s.count == 10 else { return nil }
        let p = s.split(separator: "-")
        guard p.count == 3, let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: d))
    }

    func entries(on date: Date, school: School?) -> [CalendarEntry] {
        let day = calendar.startOfDay(for: date)
        return pack.calendar.filter { e in
            guard let s = parsePackDate(e.date) else { return false }
            let end = parsePackDate(e.endDate) ?? s
            guard day >= s && day <= end else { return false }
            if e.scope == "district" { return true }
            guard let sid = school?.id else { return false }
            return e.schoolIds.contains(sid)
        }
    }

    var schoolYearEnd: Date? {
        pack.calendar
            .filter { $0.scope == "district" }
            .compactMap { parsePackDate($0.endDate) ?? parsePackDate($0.date) }
            .max()
    }

    struct DayInfo {
        var kind: DayKind
        var reason: String
        var entry: CalendarEntry?
        var alert: ClosingAlert? = nil
    }

    /// The most recently posted live alert covering `date`, highest rank first.
    ///
    /// A district alert applies to everyone; a school's own alert applies only
    /// to that school, so a water main break at Lincoln never answers "is
    /// there school tomorrow" for a Woodbrook parent.
    func alert(on date: Date, school: School?) -> ClosingAlert? {
        let key = Self.iso(calendar.startOfDay(for: date))
        let sid = school?.id
        return (pack.alerts ?? [])
            .filter { a in
                guard a.date == key, a.rank > 0 else { return false }
                guard let asid = a.schoolId, !asid.isEmpty else { return true }
                return asid == sid
            }
            .max { lhs, rhs in
                lhs.rank != rhs.rank
                    ? lhs.rank < rhs.rank
                    : (lhs.postedDate ?? .distantPast) < (rhs.postedDate ?? .distantPast)
            }
    }

    func dayInfo(_ date: Date, school: School?) -> DayInfo {
        let wd = calendar.component(.weekday, from: date)   // 1 = Sunday
        if wd == 1 || wd == 7 { return DayInfo(kind: .weekend, reason: "", entry: nil) }

        // A live alert outranks the published calendar: a snow closing is
        // exactly the case where the calendar says "normal full day" and is
        // wrong.
        if let a = alert(on: date, school: school), let mapped = DayKind(rawValue: a.kind) {
            var reason = a.text
            if reason.count > 160 { reason = String(reason.prefix(157)) + "..." }
            return DayInfo(kind: mapped, reason: reason, entry: nil, alert: a)
        }

        let es = entries(on: date, school: school)

        // A closure beats a shortened day: if both are listed there is no school.
        if let e = es.first(where: { $0.kind == "closed" || $0.kind == "break" }) {
            return DayInfo(kind: .closed, reason: e.title, entry: e)
        }
        if let e = es.first(where: { $0.kind == "no_school_students" }) {
            return DayInfo(kind: .closed, reason: e.title, entry: e)
        }
        if let e = es.first(where: { $0.kind == "early_dismissal" || $0.kind == "single_session" }) {
            return DayInfo(kind: .earlyDismissal, reason: e.title, entry: e)
        }
        if let e = es.first(where: { $0.kind == "delayed_opening" }) {
            return DayInfo(kind: .delayedOpening, reason: e.title, entry: e)
        }

        // Past the published year (summer), say so rather than claim "open".
        if let end = schoolYearEnd, date > end {
            return DayInfo(kind: .unknown, reason: "after the published school year", entry: nil)
        }
        return DayInfo(kind: .regular, reason: "", entry: nil)
    }

    // MARK: - Bells

    static func format12(_ hhmm: String) -> String {
        let p = hhmm.split(separator: ":")
        guard p.count == 2, let h = Int(p[0]), let m = Int(p[1]) else { return hhmm }
        let ap = h >= 12 ? "PM" : "AM"
        var h12 = h % 12
        if h12 == 0 { h12 = 12 }
        return String(format: "%d:%02d %@", h12, m, ap)
    }

    /// The three levels nearly every district has. Anything beyond them -
    /// an academy, a preschool, a career centre - is named by the district
    /// itself in its own file, because "Edison Success Academy" is not a
    /// thing any other district has.
    static let genericLevelLabels: [String: String] = [
        "elementary": "Elementary schools",
        "middle": "Middle schools",
        "high": "High schools"
    ]

    static func titleCase(_ s: String) -> String {
        let spaced = s.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
        return spaced.split(separator: " ", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Static form, for views that hold a pack but not an engine.
    static func levelLabel(_ level: String, labels: [String: String]?) -> String {
        if let own = labels?[level], !own.isEmpty { return own }
        return genericLevelLabels[level] ?? titleCase(level)
    }

    func levelLabel(_ level: String) -> String {
        Self.levelLabel(level, labels: pack.district.levelLabels)
    }

    func bellLines(_ ctx: Context, dayKind: DayKind) -> String {
        var levels: [String]
        if let l = ctx.level { levels = [l] }
        else if let s = ctx.school { levels = [s.level] }
        else { levels = ["elementary", "middle", "high"] }

        var lines: [String] = []
        for lvl in levels {
            for b in pack.bells where b.level == lvl {
                guard let span = b.span(for: dayKind), !span.start.isEmpty else { continue }
                let line = "\(levelLabel(lvl)): \(Self.format12(span.start)) to \(Self.format12(span.end))"
                if !lines.contains(line) { lines.append(line) }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Formatting

    private func fmt(_ pattern: String, _ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = pattern
        return f.string(from: d)
    }

    /// Alert text is quoted verbatim from the district and often already ends
    /// in punctuation; don't produce "December 10..".
    static func terminated(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let last = t.last else { return "" }
        return ".!?".contains(last) ? t : t + "."
    }

    func dateLong(_ d: Date) -> String  { fmt("EEEE, MMMM d, yyyy", d) }
    func dateShort(_ d: Date) -> String { fmt("EEE, MMM d", d) }
    func weekdayName(_ d: Date) -> String { fmt("EEEE", d) }

    func dateRange(_ s: Date, _ e: Date) -> String {
        if calendar.isDate(s, inSameDayAs: e) { return dateLong(s) }
        let sy = calendar.component(.year, from: s), ey = calendar.component(.year, from: e)
        let sm = calendar.component(.month, from: s), em = calendar.component(.month, from: e)
        if sy == ey && sm == em {
            return "\(fmt("MMMM", s)) \(calendar.component(.day, from: s))-\(calendar.component(.day, from: e)), \(sy)"
        }
        if sy == ey { return "\(fmt("MMMM d", s)) - \(fmt("MMMM d", e)), \(sy)" }
        return "\(fmt("MMMM d, yyyy", s)) - \(fmt("MMMM d, yyyy", e))"
    }

    func make(_ text: String, intent: String, kind: String, sources: [String] = [],
              confidence: Double = 0.8, schoolId: String = "",
              debug: Answer.Debug = .init(resolver: "", topIntent: "", topScore: 0, dateSlot: "",
                                          schoolSlot: "", levelSlot: "", scheduleSlot: "", breakSlot: "")) -> Answer {
        var seen = Set<String>()
        let uniq = sources.filter { !$0.isEmpty && seen.insert($0).inserted }
        return Answer(text: text, intent: intent, kind: kind, sources: uniq,
                      confidence: confidence, schoolId: schoolId, debug: debug)
    }

    // MARK: - Resolver: school status

    /// The question points at some particular day - "on", "the day of", a
    /// holiday, a break - but no date could be worked out of it.
    func asksAboutSomeOtherDay(_ norm: String) -> Bool {
        (rules.dayHints ?? []).contains { norm.contains($0) }
    }

    func resolveSchoolStatus(_ ctx: Context) -> Answer {
        // Falling back to today here is how "is there school on some random
        // day" got answered "Yes - schools are open on Monday, November 23."
        // Confident, specific, and about a day nobody asked about. Saying
        // plainly that the day was not understood is worth more.
        if ctx.date == nil, asksAboutSomeOtherDay(ctx.norm) {
            return make("I'm not sure which day you mean. Try naming the date - "
                        + "\"is there school on December 24\" - or ask about today or tomorrow.",
                        intent: "school_status", kind: "unclear_date",
                        sources: [links.calendar], confidence: 0.2)
        }

        // Without a published schedule, every weekday looks like a normal
        // school day, so this would answer "yes, open" on Thanksgiving.
        guard publishesSchoolSchedule else { return noScheduleAnswer("school_status") }

        let slot = ctx.date ?? DateSlot(start: ctx.today, end: ctx.today, isRange: false, phrase: "today")
        let label = ctx.school?.name ?? allSchoolsLabel
        let isAre = ctx.school != nil ? "is" : "are"

        if slot.isRange {
            var lines: [String] = []
            var d = slot.start
            while d <= slot.end {
                let info = dayInfo(d, school: ctx.school)
                if info.kind != .weekend {
                    let desc: String
                    switch info.kind {
                    case .closed:         desc = "closed - \(info.reason)"
                    case .earlyDismissal: desc = "early dismissal - \(info.reason)"
                    case .delayedOpening: desc = "delayed opening - \(info.reason)"
                    case .regular:        desc = "normal full day"
                    default:              desc = "no calendar entry"
                    }
                    lines.append("\(dateShort(d)): \(desc)")
                }
                d = calendar.date(byAdding: .day, value: 1, to: d)!
            }
            return make("\(label) for \(slot.phrase):\n" + lines.joined(separator: "\n"),
                        intent: "school_status", kind: "range",
                        sources: [links.events],
                        schoolId: ctx.school?.id ?? "")
        }

        let date = slot.start
        let info = dayInfo(date, school: ctx.school)
        var src: [String] = []
        if let e = info.entry { src.append(e.url) }
        if info.alert != nil { src.append(links.feed) }
        src.append(links.calendar)

        // An announcement is worth marking as one - a parent should see that
        // this came from the district saying so today, not from the calendar.
        var alertNote = ""
        if let a = info.alert {
            if let p = a.postedDate {
                alertNote = "\nDistrict announcement posted \(fmt("EEE MMM d, h:mm a", p))."
            } else {
                alertNote = "\nFrom a district announcement."
            }
        }

        switch info.kind {
        case .weekend:
            return make("\(dateLong(date)) is a \(weekdayName(date)), so there is no school.",
                        intent: "school_status", kind: "weekend", sources: src, confidence: 0.95)
        case .closed:
            var t = "No - \(label) \(isAre) closed on \(dateLong(date))."
            if !info.reason.isEmpty { t += " Reason: " + Self.terminated(info.reason) }
            t += alertNote
            return make(t, intent: "school_status", kind: "closed", sources: src, confidence: 0.95)
        case .earlyDismissal:
            var t = "Yes - \(label) \(isAre) open on \(dateLong(date)), but it is an early dismissal day (\(info.reason))."
            let bl = bellLines(ctx, dayKind: .earlyDismissal)
            if !bl.isEmpty { t += "\n" + bl }
            return make(t, intent: "school_status", kind: "early_dismissal", sources: src, confidence: 0.9)
        case .delayedOpening:
            var t = "Yes - \(label) \(isAre) open on \(dateLong(date)), on a delayed opening (\(info.reason))."
            let bl = bellLines(ctx, dayKind: .delayedOpening)
            if !bl.isEmpty { t += "\n" + bl }
            t += alertNote
            return make(t, intent: "school_status", kind: "delayed_opening", sources: src, confidence: 0.9)
        case .regular:
            return make("Yes - \(label) \(isAre) open on \(dateLong(date)), a normal full day.",
                        intent: "school_status", kind: "open", sources: src, confidence: 0.85)
        case .unknown:
            return make("I don't have a calendar entry for \(dateLong(date)) (\(info.reason)). Check the district calendar to be sure.",
                        intent: "school_status", kind: "unknown", sources: src, confidence: 0.4)
        }
    }

    // MARK: - Resolver: day schedule

    func resolveDaySchedule(_ ctx: Context) -> Answer {
        let asked = ctx.scheduleKind
        guard publishesSchoolSchedule else { return noScheduleAnswer("day_schedule") }
        let slot = ctx.date ?? DateSlot(start: ctx.today, end: ctx.today, isRange: false, phrase: "today")

        if slot.isRange {
            var hits: [(Date, String)] = []
            var d = slot.start
            while d <= slot.end {
                let info = dayInfo(d, school: ctx.school)
                if let a = asked, info.kind.rawValue == a {
                    hits.append((d, info.reason))
                } else if asked == nil, [.earlyDismissal, .delayedOpening, .closed].contains(info.kind) {
                    hits.append((d, "\(info.kind.rawValue): \(info.reason)"))
                }
                d = calendar.date(byAdding: .day, value: 1, to: d)!
            }
            if hits.isEmpty {
                let what = asked?.replacingOccurrences(of: "_", with: " ") ?? "schedule change"
                return make("No \(what) is listed for \(slot.phrase).",
                            intent: "day_schedule", kind: "none",
                            sources: [links.events], confidence: 0.85)
            }
            let lines = hits.map { "\(dateShort($0.0)) - \($0.1)" }
            return make("For \(slot.phrase):\n" + lines.joined(separator: "\n"),
                        intent: "day_schedule", kind: "range",
                        sources: [links.events], confidence: 0.9)
        }

        let date = slot.start
        let info = dayInfo(date, school: ctx.school)
        var src: [String] = []
        if let e = info.entry { src.append(e.url) }
        src.append(links.hours)

        if info.kind == .weekend {
            return make("\(dateLong(date)) is a \(weekdayName(date)) - no school.",
                        intent: "day_schedule", kind: "weekend", sources: src, confidence: 0.95)
        }
        if info.kind == .closed {
            let why = info.reason.isEmpty ? "" : " (\(info.reason))"
            return make("Schools are closed on \(dateLong(date))\(why), so there is no dismissal.",
                        intent: "day_schedule", kind: "closed", sources: src, confidence: 0.92)
        }

        // The district runs "Single Session Day" and "Early Dismissal" on the
        // same shortened bell schedule, and dayInfo folds both into
        // .earlyDismissal. Fold the question the same way, or asking about a
        // single session day on a single session day answers "no". The
        // calendar's own title is echoed back, so the reply still names it.
        var effective = asked ?? "early_dismissal"
        if effective == "single_session" { effective = "early_dismissal" }
        let what = effective.replacingOccurrences(of: "_", with: " ")
        let article = "aeiou".contains(what.first ?? "x") ? "an" : "a"

        if info.kind.rawValue == effective {
            var t = "Yes - \(dateLong(date)) is \(article) \(what) (\(info.reason))."
            let bl = bellLines(ctx, dayKind: DayKind(rawValue: effective) ?? .regular)
            if !bl.isEmpty { t += "\n" + bl }
            return make(t, intent: "day_schedule", kind: effective, sources: src, confidence: 0.92)
        }

        var t = "No - \(dateLong(date)) is not \(article) \(what)."
        if info.kind == .regular {
            t += " It is a normal full day."
            let bl = bellLines(ctx, dayKind: .regular)
            if !bl.isEmpty { t += "\n" + bl }
        } else if info.kind == .earlyDismissal || info.kind == .delayedOpening {
            t += " It is listed as \(info.kind.rawValue.replacingOccurrences(of: "_", with: " ")) (\(info.reason))."
        }
        return make(t, intent: "day_schedule", kind: "no", sources: src, confidence: 0.88)
    }

    // MARK: - Resolver: bell times

    func resolveBellTimes(_ ctx: Context) -> Answer {
        let date: Date? = (ctx.date?.isRange == false) ? ctx.date?.start : nil
        var dayKind = DayKind.regular
        var reason = ""

        // "what time does school start on a delayed opening" names a day type
        // rather than a date - answer for that schedule.
        if date == nil, let sk = ctx.scheduleKind {
            switch sk {
            case "delayed_opening": dayKind = .delayedOpening
            case "early_dismissal", "single_session": dayKind = .earlyDismissal
            default: break
            }
        }

        if let d = date {
            let info = dayInfo(d, school: ctx.school)
            if info.kind == .weekend {
                return make("\(dateLong(d)) is a \(weekdayName(d)) - no school.",
                            intent: "bell_times", kind: "weekend",
                            sources: [links.hours], confidence: 0.95)
            }
            if info.kind == .closed {
                let why = info.reason.isEmpty ? "" : " (\(info.reason))"
                return make("Schools are closed on \(dateLong(d))\(why).",
                            intent: "bell_times", kind: "closed",
                            sources: [links.calendar], confidence: 0.92)
            }
            if info.kind == .earlyDismissal || info.kind == .delayedOpening {
                dayKind = info.kind
                reason = info.reason
            }
        }

        let bl = bellLines(ctx, dayKind: dayKind)
        if bl.isEmpty {
            return make("I don't have published hours for that.", intent: "bell_times",
                        kind: "none", confidence: 0.3)
        }

        let head: String
        if let d = date {
            head = dayKind == .regular
                ? "Hours for \(dateLong(d)):"
                : "\(dateLong(d)) is \(dayKind.rawValue.replacingOccurrences(of: "_", with: " ")) (\(reason)). Hours:"
        } else if dayKind == .delayedOpening {
            head = "Delayed opening hours:"
        } else if dayKind == .earlyDismissal {
            head = "Early dismissal / single session hours:"
        } else {
            head = "Regular school hours:"
        }

        var t = "\(head)\n\(bl)"
        if dayKind == .regular && date == nil {
            t += "\nDelayed opening starts 2 hours later; early dismissal/single session ends early."
        }
        return make(t, intent: "bell_times", kind: dayKind.rawValue,
                    sources: [links.hours],
                    confidence: 0.9, schoolId: ctx.school?.id ?? "")
    }

    // MARK: - Resolver: next occurrence

    func resolveNextOccurrence(_ ctx: Context) -> Answer {
        let wanted: [String]
        switch ctx.scheduleKind {
        case "early_dismissal": wanted = ["early_dismissal", "single_session"]
        case "single_session":  wanted = ["single_session"]
        case "delayed_opening": wanted = ["delayed_opening"]
        case "closed":          wanted = ["closed", "break"]
        default:                wanted = ["closed", "break", "early_dismissal", "single_session", "delayed_opening"]
        }

        let sid = ctx.school?.id
        var best: CalendarEntry? = nil
        var bestDate: Date? = nil

        for e in pack.calendar where wanted.contains(e.kind) {
            if e.scope != "district" {
                guard let sid, e.schoolIds.contains(sid) else { continue }
            }
            guard let s = parsePackDate(e.date), s >= ctx.today else { continue }
            if bestDate == nil || s < bestDate! { bestDate = s; best = e }
        }

        guard let pick = best, let s = bestDate else {
            let what = ctx.scheduleKind?.replacingOccurrences(of: "_", with: " ") ?? "schedule change"
            return make("Nothing further is published for a \(what) this school year.",
                        intent: "next_occurrence", kind: "none",
                        sources: [links.events], confidence: 0.6)
        }

        let e2 = parsePackDate(pick.endDate) ?? s
        let days = calendar.dateComponents([.day], from: ctx.today, to: s).day ?? 0
        let when = days == 0 ? "today" : (days == 1 ? "tomorrow" : "in \(days) days")
        var t = "The next one is \(dateRange(s, e2)) - \(pick.title) (\(when))."
        if ["early_dismissal", "single_session", "delayed_opening"].contains(pick.kind) {
            let bl = bellLines(ctx, dayKind: pick.kind == "delayed_opening" ? .delayedOpening : .earlyDismissal)
            if !bl.isEmpty { t += "\n" + bl }
        }
        return make(t, intent: "next_occurrence", kind: pick.kind, sources: [pick.url], confidence: 0.9)
    }

    // MARK: - Resolver: break dates

    func resolveBreakDates(_ ctx: Context) -> Answer {
        var brk = ctx.breakName
        if brk == nil {
            if Self.matches(ctx.norm, "last day") { brk = "summer break" }
            else if Self.matches(ctx.norm, "first day|when does school start|when does school begin") { brk = "__first__" }
        }

        var cands: [CalendarEntry] = []
        if brk == "__first__" {
            cands = pack.calendar.filter { $0.kind == "first_day" }
        } else {
            let syn = brk.flatMap { rules.breaks[$0] } ?? ["recess", "break"]
            cands = pack.calendar.filter { e in
                let t = e.title.lowercased()
                return syn.contains { t.contains($0.lowercased()) }
            }
        }

        guard !cands.isEmpty else {
            if !publishesSchoolSchedule { return noScheduleAnswer("break_dates") }
            return make("I couldn't find \(brk ?? "that break") on the published calendar.",
                        intent: "break_dates", kind: "none",
                        sources: [links.calendar], confidence: 0.4)
        }

        // A break closes the whole district, so the district's own entry is
        // the answer. Without this, one school's "FDR Thanksgiving Feast" or
        // "Single Session Day- Spring Break" outranks the actual recess and
        // the parent is told the wrong week.
        let districtOnly = cands.filter { $0.scope == "district" }
        if !districtOnly.isEmpty { cands = districtOnly }

        // Prefer the next upcoming one; fall back to the most recent.
        let future = cands
            .compactMap { e -> (CalendarEntry, Date)? in
                guard let d = parsePackDate(e.date), d >= ctx.today else { return nil }
                return (e, d)
            }
            .sorted { $0.1 < $1.1 }

        // Fall back to the most recent past one. Not force-unwrapped: every
        // candidate could have an unparseable date.
        let past = cands
            .compactMap { e -> (CalendarEntry, Date)? in
                guard let d = parsePackDate(e.date) else { return nil }
                return (e, d)
            }
            .sorted { $0.1 > $1.1 }

        guard let pick = future.first?.0 ?? past.first?.0 else {
            return make("I couldn't read the dates for \(brk ?? "that break").",
                        intent: "break_dates", kind: "none",
                        sources: [links.calendar],
                        confidence: 0.2)
        }

        guard let s = parsePackDate(pick.date) else {
            return make("I couldn't read that calendar entry.", intent: "break_dates", kind: "none", confidence: 0.2)
        }
        let e2 = parsePackDate(pick.endDate) ?? s
        let nDays = (calendar.dateComponents([.day], from: s, to: e2).day ?? 0) + 1

        var t = "\(pick.title): \(dateRange(s, e2))"
        if nDays > 1 { t += " (\(nDays) days)" }
        t += "."

        if s >= ctx.today {
            let away = calendar.dateComponents([.day], from: ctx.today, to: s).day ?? 0
            t += away == 0 ? " That starts today." : (away == 1 ? " That starts tomorrow." : " That starts in \(away) days.")
            var back = calendar.date(byAdding: .day, value: 1, to: e2)!
            while [1, 7].contains(calendar.component(.weekday, from: back)) {
                back = calendar.date(byAdding: .day, value: 1, to: back)!
            }
            t += " Students return \(dateShort(back))."
        }

        return make(t, intent: "break_dates", kind: "break",
                    sources: [pick.url, links.calendar],
                    confidence: 0.92)
    }

    // MARK: - Resolver: calendar list

    // MARK: - Resolver: every occurrence, for the whole year

    /// "List every early dismissal", "what are all the days off this year",
    /// "how many half days are there".
    ///
    /// Shows the whole school year rather than the next fortnight: someone
    /// asking for the list is planning, not checking today. Without this,
    /// "list early dismissal days" matched on the words "early dismissal" and
    /// was answered as "is TODAY an early dismissal" - a flat, useless no.
    func resolveListOccurrences(_ ctx: Context) -> Answer {
        let wanted: [String]
        let label: String
        switch ctx.scheduleKind {
        case "early_dismissal":
            wanted = ["early_dismissal", "single_session"]
            label = "Early dismissal and single session days"
        case "single_session":
            wanted = ["single_session"]
            label = "Single session days"
        case "delayed_opening":
            wanted = ["delayed_opening"]
            label = "Delayed openings"
        case "closed":
            wanted = ["closed", "break"]
            label = "Days schools are closed"
        default:
            wanted = ["closed", "break", "early_dismissal", "single_session", "delayed_opening"]
            label = "Days that are not a normal full day"
        }

        let sid = ctx.school?.id
        let todayKey = Self.iso(ctx.today)

        // Schools republish the district's own dates on their own calendars,
        // so one districtwide early dismissal appears once for the district
        // and again for each of your children's schools. Collapse by date and
        // title, and let the district's copy win.
        var byKey: [String: CalendarEntry] = [:]
        for e in pack.calendar {
            guard wanted.contains(e.kind) else { continue }
            if e.scope != "district" {
                guard let sid, e.schoolIds.contains(sid) else { continue }
            }
            let key = e.date + "|" + e.title.lowercased()
            if let prev = byKey[key] {
                if prev.scope != "district", e.scope == "district" { byKey[key] = e }
            } else {
                byKey[key] = e
            }
        }
        let rows = byKey.values.sorted { $0.date < $1.date }

        guard !rows.isEmpty else {
            if !publishesSchoolSchedule { return noScheduleAnswer("list_occurrences") }
            return make("Nothing like that is on the published calendar.",
                        intent: "list_occurrences", kind: "none",
                        sources: [links.calendar], confidence: 0.5)
        }

        let upcoming = rows.filter { (($0.endDate.isEmpty ? $0.date : $0.endDate)) >= todayKey }
        let past = rows.count - upcoming.count

        let lines = upcoming.map { r -> String in
            guard let s = parsePackDate(r.date) else { return r.title }
            let e = parsePackDate(r.endDate) ?? s
            let d = calendar.isDate(s, inSameDayAs: e)
                ? dateShort(s)
                : "\(dateShort(s))-\(dateShort(e))"
            return "\(d) - \(r.title)"
        }

        var t: String
        if ctx.counting {
            // They asked for a number, so lead with the number - for the
            // whole year, which is what "in this school year" means, not just
            // what is left. The list that follows is the part they can still
            // plan around.
            t = "\(label): \(rows.count) on this school year's calendar."
            t += upcoming.isEmpty
                ? " None left."
                : " \(upcoming.count) still to come:\n" + lines.joined(separator: "\n")
            if past > 0 { t += "\n\n(\(past) already passed.)" }
        } else if upcoming.isEmpty {
            t = "\(label): none left this school year."
            if past > 0 { t += "\n\n(\(past) already passed this school year.)" }
        } else {
            t = "\(label) still to come (\(upcoming.count)):\n" + lines.joined(separator: "\n")
            if past > 0 { t += "\n\n(\(past) already passed this school year.)" }
        }

        return make(t, intent: "list_occurrences", kind: "list",
                    sources: [links.calendar], confidence: 0.92, schoolId: sid ?? "")
    }

    func resolveCalendarList(_ ctx: Context) -> Answer {
        let slot = ctx.date ?? DateSlot(start: ctx.today,
                                        end: calendar.date(byAdding: .day, value: 13, to: ctx.today)!,
                                        isRange: true, phrase: "the next two weeks")
        let sid = ctx.school?.id

        var rows: [(Date, Date, String)] = []
        for e in pack.calendar {
            guard let s = parsePackDate(e.date) else { continue }
            let en = parsePackDate(e.endDate) ?? s
            guard en >= slot.start, s <= slot.end else { continue }
            if e.scope != "district" {
                guard let sid, e.schoolIds.contains(sid) else { continue }
            }
            rows.append((s, en, e.title))
        }

        guard !rows.isEmpty else {
            return make("Nothing is listed for \(slot.phrase).", intent: "calendar_list",
                        kind: "none", sources: [links.events], confidence: 0.7)
        }

        let lines = rows.sorted { $0.0 < $1.0 }.prefix(12).map { r -> String in
            let d = calendar.isDate(r.0, inSameDayAs: r.1)
                ? dateShort(r.0)
                : "\(dateShort(r.0))-\(dateShort(r.1))"
            return "\(d): \(r.2)"
        }
        return make("\(slot.phrase):\n" + lines.joined(separator: "\n"),
                    intent: "calendar_list", kind: "list",
                    sources: [links.events], confidence: 0.85)
    }

    // MARK: - Resolver: absence

    func resolveAbsenceReport(_ ctx: Context) -> Answer {
        let terms = ["absent", "absence", "attendance", "report", "phone", "call", "secretary", "email", "sick"]

        var hits = factMatches(terms: terms, school: ctx.school,
                               requireTags: ["absent", "attendance", "absence"], top: 2)

        if let s = ctx.school {
            // Absence procedure is per school, so only that school's own page
            // will do. A district page that merely mentions "call" or "email"
            // - the parent help desk, say - is not an answer to "who do I call
            // about Lincoln", and neither is another school's attendance page.
            hits = hits.filter { $0.fact.schoolId == s.id }

            if hits.isEmpty,
               let c = pack.contacts.first(where: { $0.schoolId == s.id }), !c.phone.isEmpty {
                var t = "Call the \(s.name) office to report an absence: \(c.phone)."
                if let email = c.emails.first { t += " You can also email \(email)." }
                t += "\n\(s.shortName) does not publish a separate attendance page, so this is the main office line."
                return make(t, intent: "absence_report", kind: "contact",
                            sources: [c.url], confidence: 0.7, schoolId: s.id)
            }
        } else if hits.isEmpty {
            hits = factMatches(terms: terms, school: ctx.school, top: 2)
        }

        guard let f = hits.first?.fact else {
            return make("Report an absence by calling your child's school office. The district's main number is \(pack.district.phone).",
                        intent: "absence_report", kind: "fallback",
                        sources: [links.site], confidence: 0.35)
        }

        let excerpt = factExcerpt(f, terms: terms)
        var t: String
        if let s = ctx.school {
            t = "To report an absence at \(s.name):\n\(excerpt)"
        } else {
            t = "Absences are reported to your child's own school office. From \(f.title):\n\(excerpt)"
            t += "\n\nTell me which school and I'll give you that office's number."
        }
        return make(t, intent: "absence_report", kind: "fact", sources: [f.url],
                    confidence: 0.85, schoolId: ctx.school?.id ?? "")
    }

    // MARK: - Resolver: contact info

    func resolveContactInfo(_ ctx: Context) -> Answer {
        if let s = ctx.school {
            let rec = pack.contacts.first { $0.schoolId == s.id }
            var lines = [s.name]
            if let r = rec {
                if !r.address.isEmpty { lines.append("Address: \(r.address)") }
                if !r.phone.isEmpty   { lines.append("Phone: \(r.phone)") }
                if !r.fax.isEmpty     { lines.append("Fax: \(r.fax)") }
                let extra = r.phones.filter { $0 != r.phone }.prefix(2)
                if !extra.isEmpty { lines.append("Also: " + extra.joined(separator: ", ")) }
                let em = r.emails.prefix(2)
                if !em.isEmpty { lines.append("Email: " + em.joined(separator: ", ")) }
            }
            lines.append("Website: \(s.url)")

            if lines.count > 2 {
                return make(lines.joined(separator: "\n"), intent: "contact_info", kind: "school",
                            sources: [s.url], confidence: 0.88, schoolId: s.id)
            }
            var t = lines.joined(separator: "\n")
            t += "\n\nDistrict main line: \(pack.district.phone)"
            return make(t, intent: "contact_info", kind: "school_partial",
                        sources: [s.url], confidence: 0.6, schoolId: s.id)
        }

        var lines = [pack.district.name]
        if !pack.district.phone.isEmpty   { lines.append("Phone: \(pack.district.phone)") }
        if !pack.district.address.isEmpty { lines.append("Address: \(pack.district.address)") }
        if !pack.district.url.isEmpty     { lines.append("Website: \(pack.district.url)") }
        var t = lines.joined(separator: "\n")
        t += "\n\nFor a specific school, name it and I'll give you that office."
        return make(t, intent: "contact_info", kind: "district",
                    sources: [pack.district.url], confidence: 0.85)
    }

    // MARK: - Resolver: fact search

    static let stopWords: Set<String> = [
        "what", "when", "where", "who", "how", "why", "is", "are", "do", "does", "did", "the", "a", "an",
        "my", "our", "i", "we", "you", "to", "for", "of", "in", "on", "at", "it", "its", "be", "can", "could",
        "should", "would", "will", "there", "their", "and", "or", "if", "about", "from", "me", "kid", "kids",
        "child", "children", "son", "daughter", "school", "schools", "district", "please", "tell"
    ]

    func resolveFactSearch(_ ctx: Context) -> Answer {
        let all = Self.tokens(ctx.norm).filter { $0.count > 2 }
        var terms = all.filter { !stop.contains($0) }
        if terms.isEmpty { terms = all }

        guard !terms.isEmpty else {
            return make("Ask me about school hours, closings, the calendar, absences, buses, meals or policies.",
                        intent: "fact_search", kind: "empty", confidence: 0.1)
        }

        let hits = factMatches(terms: terms, school: ctx.school, top: 3)
        guard let first = hits.first else {
            return make("I couldn't find that in the district's published pages. Try rewording, or check (links.site)",
                        intent: "fact_search", kind: "none",
                        sources: [links.site], confidence: 0.15)
        }

        var t = "\(first.fact.title):\n" + factExcerpt(first.fact, terms: terms)
        var srcs = [first.fact.url]
        if hits.count > 1 {
            let rest = hits.dropFirst()
            t += "\n\nAlso relevant: " + rest.map(\.fact.title).joined(separator: "; ") + "."
            srcs.append(contentsOf: rest.map(\.fact.url))
        }
        return make(t, intent: "fact_search", kind: "fact", sources: srcs,
                    confidence: min(0.8, 0.35 + 0.1 * first.score))
    }

    // MARK: - Retrieval

    struct FactHit { var fact: Fact; var score: Double }

    /// BM25-flavoured scoring. Title and tags are boosted because district
    /// page bodies are short and the page NAME usually carries the topic.
    func factMatches(terms: [String], school: School?, requireTags: [String] = [], top: Int = 3) -> [FactHit] {
        guard !pack.facts.isEmpty, !terms.isEmpty else { return [] }

        struct Doc { var fact: Fact; var title: String; var tags: String; var bag: [String: Double] }
        var df: [String: Double] = [:]
        var docs: [Doc] = []
        docs.reserveCapacity(pack.facts.count)

        for f in pack.facts {
            let title = f.title.lowercased()
            let tags = f.tags.joined(separator: " ").lowercased()
            var bag: [String: Double] = [:]
            for t in Self.tokens("\(title) \(f.text.lowercased()) \(tags)") {
                bag[t, default: 0] += 1
            }
            for k in bag.keys { df[k, default: 0] += 1 }
            docs.append(Doc(fact: f, title: title, tags: tags, bag: bag))
        }
        let n = Double(docs.count)

        var scored: [FactHit] = []
        for d in docs {
            if !requireTags.isEmpty, !requireTags.contains(where: { d.tags.contains($0) }) { continue }

            var score = 0.0
            for t in terms {
                let tf = d.bag[t] ?? 0
                guard tf > 0 else { continue }
                let dfv = df[t] ?? 1
                let idf = log(1.0 + (n - dfv + 0.5) / (dfv + 0.5))
                score += idf * (tf / (tf + 1.5))
                if Self.containsPhrase(d.title, t) { score += idf * 1.2 }
                if Self.containsPhrase(d.tags, t)  { score += idf * 1.0 }
            }
            guard score > 0 else { continue }

            // A question about one school is answered from that school's page
            // or a district-wide one, never from a different school's. Lincoln
            // has no attendance page, and a mere score penalty let JMI's page
            // win, handing a Lincoln parent JMI's attendance email.
            if let sid = school?.id {
                if d.fact.schoolId == sid { score *= 2.2 }
                else if !d.fact.schoolId.isEmpty { continue }
            } else if !d.fact.schoolId.isEmpty {
                score *= 0.7
            }

            // Staff pages (payroll, certification, tuition reimbursement) are
            // in the pack so the app covers everything the district
            // publishes, but a parent's question should not be answered from
            // one unless they clearly asked about it. If the query terms
            // overlap the page's own title, the penalty lifts.
            if d.fact.audience == "staff" {
                let deliberate = terms.contains { Self.containsPhrase(d.title, $0) }
                if !deliberate { score *= 0.2 }
            }

            scored.append(FactHit(fact: d.fact, score: score))
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(top))
    }

    /// Pulls the lines that mention the query terms, so an answer is a few
    /// relevant lines rather than a whole page.
    func factExcerpt(_ fact: Fact, terms: [String], maxChars: Int = 420) -> String {
        let lines = fact.text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "" }

        var scored: [(Int, Int, String)] = []
        for (i, line) in lines.enumerated() {
            let l = line.lowercased()
            var hits = terms.reduce(0) { $0 + (Self.containsPhrase(l, $1) ? 1 : 0) }
            if Self.matches(l, "\\d{3}[-.\\s]\\d{3}[-.\\s]\\d{4}") { hits += 2 }
            if Self.matches(l, "@[a-z0-9.\\-]+\\.[a-z]{2,}")       { hits += 1 }
            scored.append((i, hits, line))
        }

        var keep = scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(6).map { $0 }
        if keep.isEmpty { keep = Array(scored.prefix(4)) }
        let ordered = keep.sorted { $0.0 < $1.0 }

        var out = ""
        for k in ordered {
            if !out.isEmpty { out += "\n" }
            if out.count + k.2.count > maxChars { break }
            out += k.2
        }
        return out.isEmpty ? lines[0] : out
    }
}
