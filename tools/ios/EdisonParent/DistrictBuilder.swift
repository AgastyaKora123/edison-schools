//
//  DistrictBuilder.swift
//  EdisonParent
//
//  Builds a district's information file on the phone, from that district's
//  own public calendar, so the app works for any district running the same
//  website software rather than only the one it shipped with.
//
//  This is the Swift twin of web/district.js. The two are kept deliberately
//  alike - same order, same names, same decisions - because when an answer
//  differs between the phone and the website, the first question is always
//  which of these two files drifted. DistrictBuilderTests replays the same
//  fixture calendar through both expectations.
//
//  What it cannot do: bell times, office phone numbers and the text of a
//  district's pages need a crawl of the website itself, which is the desktop
//  tool's job. Those come back empty, and the answer engine already says it
//  does not know rather than inventing them.
//

import Foundation

enum DistrictBuilder {

    static let api = "https://thrillshare-cmsv2.services.thrillshare.com/api/v4/o"

    /// What the app knows about a district before it reads anything.
    struct Info {
        var orgId: Int
        var name: String
        var shortName: String = ""
        var url: String = ""
        var timeZone: String = ""
    }

    struct Section {
        var id: String
        var name: String
        var slug: String
    }

    struct Event {
        var uid: String
        var summary: String
        var description: String
        var date: String        // yyyy-MM-dd
        var endDate: String     // INCLUSIVE
        var allDay: Bool
    }

    enum BuildError: LocalizedError {
        case noCalendar
        case badResponse(String, Int)

        var errorDescription: String? {
            switch self {
            case .noCalendar:
                return "That district publishes no calendar."
            case let .badResponse(url, code):
                return "\(url) returned \(code)"
            }
        }
    }

    // MARK: - iCal

    /// RFC 5545 line unfolding: a line break followed by a space continues.
    static func unfold(_ text: String) -> String {
        text.replacingOccurrences(of: "\r?\n[ \t]", with: "", options: .regularExpression)
    }

    static func unescapeText(_ s: String) -> String {
        guard !s.isEmpty else { return "" }
        var out = s.replacingOccurrences(of: "\\n", with: "\n")
        out = out.replacingOccurrences(of: "\\N", with: "\n")
        out = out.replacingOccurrences(of: "\\,", with: ",")
        out = out.replacingOccurrences(of: "\\;", with: ";")
        out = out.replacingOccurrences(of: "\\\\", with: "\\")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct RawProp {
        var params: String
        var value: String
    }

    static func propRaw(_ body: String, _ name: String) -> RawProp? {
        let pattern = "^\(name)([^:\\r\\n]*):(.*)$"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return nil
        }
        let ns = body as NSString
        guard let m = re.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let params = m.range(at: 1).location == NSNotFound ? "" : ns.substring(with: m.range(at: 1))
        let value = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
        return RawProp(params: params,
                       value: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func prop(_ body: String, _ name: String) -> String {
        propRaw(body, name)?.value ?? ""
    }

    struct YMD: Comparable {
        var y: Int, m: Int, d: Int
        var iso: String { String(format: "%04d-%02d-%02d", y, m, d) }
        static func < (a: YMD, b: YMD) -> Bool { a.iso < b.iso }
    }

    /// "20261126" or "20261126T143000Z" -> YMD. Nil if unparseable.
    static func parseIcsDate(_ v: String) -> YMD? {
        let s = v.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 8 else { return nil }
        let digits = Array(s.prefix(8))
        guard digits.allSatisfy({ $0.isNumber }),
              let y = Int(String(digits[0...3])),
              let mo = Int(String(digits[4...5])),
              let d = Int(String(digits[6...7])),
              (1...12).contains(mo), (1...31).contains(d) else { return nil }
        return YMD(y: y, m: mo, d: d)
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    static func addDays(_ p: YMD, _ n: Int) -> YMD {
        var comps = DateComponents()
        comps.year = p.y; comps.month = p.m; comps.day = p.d
        guard let base = utcCalendar.date(from: comps),
              let moved = utcCalendar.date(byAdding: .day, value: n, to: base) else { return p }
        let c = utcCalendar.dateComponents([.year, .month, .day], from: moved)
        return YMD(y: c.year ?? p.y, m: c.month ?? p.m, d: c.day ?? p.d)
    }

    /// Parses VEVENT blocks into plain records.
    ///
    /// The one thing worth stating twice: for an all-day event the iCalendar
    /// end date is EXCLUSIVE. A day off covering only the 26th is written
    /// DTSTART 26th, DTEND 27th. Stored as-is, every break in the app would
    /// run a day long. The end is converted to the last day actually covered,
    /// so a one-day event has the same start and end.
    static func parseIcs(_ text: String) -> [Event] {
        let body = unfold(text)
        var out: [Event] = []

        guard let re = try? NSRegularExpression(pattern: "BEGIN:VEVENT([\\s\\S]*?)END:VEVENT") else {
            return out
        }
        let ns = body as NSString
        for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            guard m.range(at: 1).location != NSNotFound else { continue }
            let b = ns.substring(with: m.range(at: 1))

            guard let startRaw = propRaw(b, "DTSTART") else { continue }

            let paramsSayDate = startRaw.params.range(of: "VALUE=DATE(?!-TIME)",
                                                      options: .regularExpression) != nil
            let valueIsBareDate = startRaw.value.range(of: "^\\d{8}$",
                                                       options: .regularExpression) != nil
            let allDay = paramsSayDate || valueIsBareDate

            guard let start = parseIcsDate(startRaw.value) else { continue }

            var end = start
            if let endRaw = propRaw(b, "DTEND"), !endRaw.value.isEmpty,
               var e = parseIcsDate(endRaw.value) {
                if allDay {
                    e = addDays(e, -1)
                    if e < start { e = start }
                }
                end = e
            }

            out.append(Event(uid: prop(b, "UID"),
                             summary: unescapeText(prop(b, "SUMMARY")),
                             description: unescapeText(prop(b, "DESCRIPTION")),
                             date: start.iso,
                             endDate: end.iso,
                             allDay: allDay))
        }
        return out
    }

    /// The timezone the district publishes its calendar in.
    static func icsTimeZone(_ text: String) -> String {
        guard let r = text.range(of: "TZID:[^\\r\\n;]+", options: .regularExpression) else { return "" }
        return String(text[r]).replacingOccurrences(of: "TZID:", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - What an entry means

    static let defaultKinds: [Rules.EventKindRule] = [
        .init(kind: "delayed_opening", pattern: "delayed\\s+opening|late\\s+start|delayed\\s+start|2\\s*hour\\s+delay"),
        .init(kind: "early_dismissal", pattern: "early\\s+dismissal|early\\s+release|minimum\\s+day"),
        .init(kind: "single_session", pattern: "single\\s+session"),
        .init(kind: "break", pattern: "\\b(recess|break)\\b"),
        .init(kind: "no_school_students", pattern: "no\\s+school\\s+for\\s+students|students?\\s+do\\s+not\\s+report|staff\\s+(only|development|in-?service)|professional\\s+development\\s+day"),
        .init(kind: "closed", pattern: "schools?\\s+closed|school\\s+closed|closed\\b|no\\s+school"),
        .init(kind: "last_day", pattern: "last\\s+day\\s+of\\s+school"),
        .init(kind: "first_day", pattern: "first\\s+day\\s+of\\s+school|schools?\\s+open\\b")
    ]

    /// What a calendar entry means - decided from its title and nothing else.
    ///
    /// The description used to count too, and it cost a real wrong answer.
    /// Clarksville's theatre evening came with a description that was a slab
    /// of pasted Word markup; buried in the stylesheet was "page-break",
    /// which matched the rule for a school break. The app would have told a
    /// parent their child had the day off to watch a play.
    ///
    /// Descriptions are whatever somebody pasted in. The title is the entry.
    /// Missing a closing that was only ever mentioned in a description is a
    /// miss; inventing one is a parent keeping a child at home.
    static func eventKind(_ rules: Rules?, _ summary: String) -> String {
        let list = rules?.eventKinds?.isEmpty == false ? rules!.eventKinds! : defaultKinds
        let hay = summary.lowercased()
        for r in list where hay.range(of: r.pattern, options: .regularExpression) != nil {
            return r.kind
        }
        return "event"
    }

    static func cleanTitle(_ rules: Rules?, _ summary: String) -> String {
        var s = summary
        for p in rules?.titlePrefixes ?? [] {
            s = s.replacingOccurrences(of: p, with: "",
                                       options: [.regularExpression, .caseInsensitive])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Ids and names

    static func slug(_ s: String) -> String {
        let lowered = s.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "^-|-$", with: "", options: .regularExpression)
        return String(lowered.prefix(40))
    }

    /// A district names its calendars for its own staff: "BHS Events",
    /// "Lincoln Elementary Calendar". The trailing word is noise on a list of
    /// schools a parent is picking from.
    static func cleanSectionName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "\\s*[-–—]?\\s*\\b(events?|calendar|activities|athletics?)\\s*$",
                                  with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? name.trimmingCharacters(in: .whitespaces) : cleaned
    }

    /// A guess at what kind of school this is, from its name alone.
    ///
    /// Only used for a district whose pages nobody has read. It is a guess
    /// and it is treated as one: nothing that matters hangs off it, because a
    /// district read this way has no bell times to attach to a level anyway.
    static func guessLevel(_ name: String) -> String {
        let raw = cleanSectionName(name)
        let n = raw.lowercased()
        func has(_ p: String) -> Bool { n.range(of: p, options: .regularExpression) != nil }

        if has("pre-?k|preschool|early (learning|childhood)|kindergarten") { return "preschool" }
        if has("\\bhigh\\b|senior\\b") { return "high" }
        if has("\\bmiddle\\b|junior|\\bjr\\b|intermediate") { return "middle" }
        if has("\\belementary\\b|primary") { return "elementary" }

        // Districts abbreviate their own schools and expect parents to know:
        // BHS, BMS, BES. The initial is the town; the rest is the level.
        let letters = raw.replacingOccurrences(of: "[^A-Za-z]", with: "", options: .regularExpression)
        if let r = letters.range(of: "^[A-Z]{1,4}(HS|MS|ES|JHS|JH)$", options: .regularExpression),
           r.lowerBound == letters.startIndex {
            if letters.hasSuffix("HS") && !letters.hasSuffix("JHS") { return "high" }
            if letters.hasSuffix("MS") || letters.hasSuffix("JHS") || letters.hasSuffix("JH") { return "middle" }
            if letters.hasSuffix("ES") { return "elementary" }
        }
        return ""
    }

    /// Which section is the whole district rather than one school.
    static func isDistrictSection(_ name: String) -> Bool {
        name.range(of: "\\b(district|districtwide|all schools|division)\\b",
                   options: [.regularExpression, .caseInsensitive]) != nil
        || name.range(of: "^\\s*(events|calendar|main)\\s*$",
                      options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Fetching

    private static func get(_ url: String) async throws -> Data {
        guard let u = URL(string: url) else { throw BuildError.badResponse(url, 0) }
        var req = URLRequest(url: u)
        req.cachePolicy = .reloadRevalidatingCacheData
        req.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw BuildError.badResponse(url, code) }
        return data
    }

    /// The district's calendar sections. One per school, plus a districtwide one.
    static func fetchSections(orgId: Int) async throws -> [Section] {
        // page_no far past the end: the sections come back in the summary,
        // and the twenty events we would otherwise download do not.
        let data = try await get("\(api)/\(orgId)/cms/events?page_no=9999")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meta = root["meta"] as? [String: Any],
              let raw = meta["sections"] as? [[String: Any]] else { return [] }

        return raw.compactMap { s in
            let name = (s["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let id: String
            if let n = s["id"] as? Int { id = String(n) }
            else if let t = s["id"] as? String { id = t }
            else { return nil }
            return Section(id: id, name: name, slug: s["slug"] as? String ?? "")
        }
    }

    // MARK: - Build

    /// Builds the same shape of information file the bundled district uses,
    /// so the answer engine cannot tell the difference.
    static func build(info: Info,
                      rules: Rules?,
                      onStep: @escaping (String) -> Void = { _ in }) async throws -> KnowledgePack {

        onStep("Finding the schools")
        let sections = try await fetchSections(orgId: info.orgId)
        guard !sections.isEmpty else { throw BuildError.noCalendar }

        let districtSections = sections.filter { isDistrictSection($0.name) }
        let schoolSections = sections.filter { !isDistrictSection($0.name) }

        let schools: [School] = schoolSections.map { s in
            let label = cleanSectionName(s.name)
            var aliases = [label.lowercased()]
            if s.name.lowercased() != label.lowercased() { aliases.append(s.name.lowercased()) }
            return School(id: slug(s.name),
                          name: label,
                          shortName: label,
                          level: guessLevel(s.name),
                          aliases: aliases,
                          sectionId: s.id)
        }

        // One request per calendar: the district's own first, then each
        // school's. A few at a time rather than all at once - a large
        // district has a hundred schools, and a hundred simultaneous requests
        // is both rude to a service that costs nobody anything to use and
        // liable to be throttled by the phone itself.
        onStep("Reading the calendar")
        let wanted = districtSections + schoolSections
        var feeds: [(section: Section, text: String)] = []
        let atOnce = 6

        var i = 0
        while i < wanted.count {
            let batch = Array(wanted[i..<min(i + atOnce, wanted.count)])
            let got = await withTaskGroup(of: (Section, String).self) { group -> [(Section, String)] in
                for s in batch {
                    group.addTask {
                        do {
                            let d = try await get("\(api)/\(info.orgId)/cms/events/generate_ical?section_ids=\(s.id)")
                            return (s, String(data: d, encoding: .utf8) ?? "")
                        } catch {
                            // One school's calendar missing is not a failure.
                            return (s, "")
                        }
                    }
                }
                var acc: [(Section, String)] = []
                for await r in group { acc.append(r) }
                return acc
            }
            feeds.append(contentsOf: got.map { (section: $0.0, text: $0.1) })
            i += atOnce
            if wanted.count > atOnce {
                onStep("Reading the calendar (\(min(i, wanted.count)) of \(wanted.count))")
            }
        }

        var timeZone = info.timeZone
        var parsed: [(ev: Event, districtWide: Bool, section: Section)] = []
        for f in feeds where !f.text.isEmpty {
            if timeZone.isEmpty { timeZone = icsTimeZone(f.text) }
            let districtWide = isDistrictSection(f.section.name)
            for ev in parseIcs(f.text) {
                parsed.append((ev: ev, districtWide: districtWide, section: f.section))
            }
        }

        // Some districts keep no districtwide calendar at all - every date is
        // published under each school. Without a stand-in, a parent who has
        // not picked a school yet would be told nothing is on the calendar,
        // which is false and looks broken.
        //
        // So where there is no districtwide calendar, a date that several
        // schools publish identically IS the district's: that is what a
        // districtwide closing looks like when written out school by school.
        // A date only one school lists stays that school's.
        let haveDistrictSection = parsed.contains { $0.districtWide }
        var shared = Set<String>()
        if !haveDistrictSection {
            var bySection: [String: Set<String>] = [:]
            for p in parsed {
                let key = p.ev.date + "|" + p.ev.summary.lowercased()
                bySection[key, default: []].insert(p.section.id)
            }
            for (key, ids) in bySection where ids.count >= 2 { shared.insert(key) }
        }

        var calendar: [CalendarEntry] = []
        var seen = Set<String>()
        for p in parsed {
            let ev = p.ev
            let key = ev.date + "|" + ev.summary.lowercased()
            let isDistrict = p.districtWide || shared.contains(key)

            // Schools republish the district's dates, so the same day arrives
            // several times. The district's copy wins, and a date promoted to
            // districtwide is kept once however many schools listed it.
            if seen.contains(key) { continue }
            if isDistrict { seen.insert(key) }

            calendar.append(CalendarEntry(
                date: ev.date,
                endDate: ev.endDate,
                title: cleanTitle(rules, ev.summary),
                rawTitle: ev.summary,
                kind: eventKind(rules, ev.summary),
                scope: isDistrict ? "district" : "school",
                schoolIds: isDistrict ? [] : [slug(p.section.name)],
                allDay: ev.allDay,
                startTime: nil,
                url: ""))
        }
        calendar.sort { $0.date < $1.date }

        // Some entries repeat weekly with no end, so the feed hands back
        // every occurrence to the year 2099: nine and a half thousand entries
        // for a district with about three hundred real dates. Nothing past
        // the end of this school year is any use to a parent, and keeping it
        // would fill the phone with picture days in 2074.
        let now = Date()
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC")!
        let month = gregorian.component(.month, from: now)
        let year = gregorian.component(.year, from: now)
        let endYear = month >= 8 ? year + 1 : year
        let horizon = "\(endYear)-08-31"
        let trimmed = calendar.filter { $0.date <= horizon }

        let site = info.url.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let pages: [String: String] = site.isEmpty
            ? [:]
            : ["calendar": site + "/events/", "events": site + "/events/",
               "hours": site, "feed": site + "/live-feed/"]

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]

        return KnowledgePack(
            schemaVersion: 1,
            generatedAt: stamp.string(from: now),
            builtInApp: true,
            district: KnowledgePack.District(
                name: info.name.isEmpty ? "Your district" : info.name,
                url: site,
                phone: "",
                address: "",
                timeZone: timeZone.isEmpty ? "America/New_York" : timeZone,
                pages: pages,
                levelLabels: nil),
            schools: schools,
            bells: [],
            calendar: trimmed,
            facts: [],
            contacts: [],
            alertFeedUrl: "\(api)/\(info.orgId)/cms/live_feeds",
            alerts: [])
    }
}
