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
    /// asking at 11pm Pacific still gets Edison's "tomorrow".
    private let calendar: Calendar

    init(pack: KnowledgePack, rules: Rules) {
        self.pack = pack
        self.rules = rules
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: pack.district.timeZone) ?? TimeZone(identifier: "America/New_York")!
        cal.locale = Locale(identifier: "en_US")
        self.calendar = cal
    }

    // MARK: - Entry point

    func answer(_ query: String, today: Date = Date(), defaultSchoolId: String = "") -> Answer {
        let norm = Self.normalize(query)
        let todayStart = calendar.startOfDay(for: today)

        guard !norm.isEmpty else {
            return make("Ask me anything about Edison schools - hours, closings, the calendar, absences.",
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
            breakName: resolveBreak(norm)
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

    func resolveLevel(_ norm: String) -> String? {
        var best: String? = nil
        var bestLen = 0
        for (level, words) in rules.levelWords {
            for w in words where w.count > bestLen {
                if Self.containsPhrase(norm, w) { best = level; bestLen = w.count }
            }
        }
        return best
    }

    func resolveScheduleKind(_ norm: String) -> String? {
        var best: String? = nil
        var bestLen = 0
        for (kind, words) in rules.scheduleWords {
            for w in words where w.count > bestLen {
                if Self.containsPhrase(norm, w) { best = kind; bestLen = w.count }
            }
        }
        return best
    }

    func resolveBreak(_ norm: String) -> String? {
        var best: String? = nil
        var bestLen = 0
        for (name, words) in rules.breaks {
            for w in words where w.count > bestLen {
                if Self.containsPhrase(norm, w) { best = name; bestLen = w.count }
            }
        }
        return best
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

    static func levelLabel(_ level: String) -> String {
        switch level {
        case "elementary": return "Elementary schools (K-5)"
        case "middle":     return "Middle schools"
        case "high":       return "High schools"
        case "academy":    return "Edison Success Academy"
        case "eelc":       return "Edison Early Learning Center"
        case "fdr":        return "FDR Preschool"
        default:           return level
        }
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
                let line = "\(Self.levelLabel(lvl)): \(Self.format12(span.start)) to \(Self.format12(span.end))"
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

    func resolveSchoolStatus(_ ctx: Context) -> Answer {
        let slot = ctx.date ?? DateSlot(start: ctx.today, end: ctx.today, isRange: false, phrase: "today")
        let label = ctx.school?.name ?? "Edison schools"
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
                        sources: ["https://www.edison.k12.nj.us/events/"],
                        schoolId: ctx.school?.id ?? "")
        }

        let date = slot.start
        let info = dayInfo(date, school: ctx.school)
        var src: [String] = []
        if let e = info.entry { src.append(e.url) }
        if info.alert != nil { src.append("https://www.edison.k12.nj.us/live-feed/") }
        src.append("https://www.edison.k12.nj.us/page/district-yearly-calendar/")

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
                            sources: ["https://www.edison.k12.nj.us/events/"], confidence: 0.85)
            }
            let lines = hits.map { "\(dateShort($0.0)) - \($0.1)" }
            return make("For \(slot.phrase):\n" + lines.joined(separator: "\n"),
                        intent: "day_schedule", kind: "range",
                        sources: ["https://www.edison.k12.nj.us/events/"], confidence: 0.9)
        }

        let date = slot.start
        let info = dayInfo(date, school: ctx.school)
        var src: [String] = []
        if let e = info.entry { src.append(e.url) }
        src.append("https://www.edison.k12.nj.us/page/school-hours/")

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
                            sources: ["https://www.edison.k12.nj.us/page/school-hours/"], confidence: 0.95)
            }
            if info.kind == .closed {
                let why = info.reason.isEmpty ? "" : " (\(info.reason))"
                return make("Schools are closed on \(dateLong(d))\(why).",
                            intent: "bell_times", kind: "closed",
                            sources: ["https://www.edison.k12.nj.us/page/district-yearly-calendar/"], confidence: 0.92)
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
                    sources: ["https://www.edison.k12.nj.us/page/school-hours/"],
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
                        sources: ["https://www.edison.k12.nj.us/events/"], confidence: 0.6)
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
            return make("I couldn't find \(brk ?? "that break") on the published calendar.",
                        intent: "break_dates", kind: "none",
                        sources: ["https://www.edison.k12.nj.us/page/district-yearly-calendar/"], confidence: 0.4)
        }

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
                        sources: ["https://www.edison.k12.nj.us/page/district-yearly-calendar/"],
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
                    sources: [pick.url, "https://www.edison.k12.nj.us/page/district-yearly-calendar/"],
                    confidence: 0.92)
    }

    // MARK: - Resolver: calendar list

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
                        kind: "none", sources: ["https://www.edison.k12.nj.us/events/"], confidence: 0.7)
        }

        let lines = rows.sorted { $0.0 < $1.0 }.prefix(12).map { r -> String in
            let d = calendar.isDate(r.0, inSameDayAs: r.1)
                ? dateShort(r.0)
                : "\(dateShort(r.0))-\(dateShort(r.1))"
            return "\(d): \(r.2)"
        }
        return make("\(slot.phrase):\n" + lines.joined(separator: "\n"),
                    intent: "calendar_list", kind: "list",
                    sources: ["https://www.edison.k12.nj.us/events/"], confidence: 0.85)
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
                        sources: ["https://www.edison.k12.nj.us/page/chain-of-communication/"], confidence: 0.35)
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
        "child", "children", "son", "daughter", "school", "schools", "edison", "district", "please", "tell"
    ]

    func resolveFactSearch(_ ctx: Context) -> Answer {
        let all = Self.tokens(ctx.norm).filter { $0.count > 2 }
        var terms = all.filter { !Self.stopWords.contains($0) }
        if terms.isEmpty { terms = all }

        guard !terms.isEmpty else {
            return make("Ask me about school hours, closings, the calendar, absences, buses, meals or policies.",
                        intent: "fact_search", kind: "empty", confidence: 0.1)
        }

        let hits = factMatches(terms: terms, school: ctx.school, top: 3)
        guard let first = hits.first else {
            return make("I couldn't find that in the district's published pages. Try rewording, or check https://www.edison.k12.nj.us",
                        intent: "fact_search", kind: "none",
                        sources: ["https://www.edison.k12.nj.us"], confidence: 0.15)
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
