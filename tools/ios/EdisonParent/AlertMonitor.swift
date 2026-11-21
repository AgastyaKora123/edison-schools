//
//  AlertMonitor.swift
//  Edison Parent
//
//  Reads emergency closings out of the district's public live feed.
//
//  Port of engine/Alerts.ps1; tests/alerts.jsonl is the contract, and every
//  fixture in it is a verbatim post from the real feed — including the three
//  false positives that tripped the first version ("Closed session: 5:30 PM",
//  "we closed it out by having Rutgers players…", a Memorial Day save-the-date
//  four months out).
//
//  Why polling works here: Edison posts weather closings and delayed openings
//  the AFTERNOON BEFORE — 14:00 to 16:30 in every case on record, never at
//  5am. A phone that checks a few times a day catches them with hours to
//  spare.
//

import Foundation

struct AlertParser {

    let rules: Rules
    private let calendar: Calendar

    init(rules: Rules, timeZone: String = "America/New_York") {
        self.rules = rules
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(identifier: "America/New_York")!
        cal.locale = Locale(identifier: "en_US")
        self.calendar = cal
    }

    // MARK: - One post

    struct RawAlert {
        var kind: String
        var date: Date
        var line: String
    }

    /// Extracts the operational alerts in one live-feed post body.
    func alerts(inStatus status: String, postedAt: Date) -> [RawAlert] {
        guard let cfg = rules.alerts else { return [] }
        let text = Self.htmlToText(status)
        guard !text.isEmpty else { return [] }

        let postedDay = calendar.startOfDay(for: postedAt)
        var out: [RawAlert] = []

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.count >= 8 else { continue }
            let low = line.lowercased()

            // Hard rejects beat any positive match.
            if cfg.reject.contains(where: { low.contains($0.lowercased()) }) { continue }

            // Closure outranks a shortened day, matching the calendar's
            // precedence: if a line says both, there is no school.
            var kind = ""
            for k in ["closed", "delayed_opening", "early_dismissal"] {
                if let phrases = cfg.kinds[k],
                   phrases.contains(where: { low.contains($0.lowercased()) }) {
                    kind = k
                    break
                }
            }
            guard !kind.isEmpty else { continue }

            if cfg.subjectRequiredFor.contains(kind) {
                guard cfg.subjects.contains(where: { AnswerEngine.containsPhrase(low, $0) }) else { continue }
            }

            guard let date = alertDate(in: line, postedAt: postedDay) else { continue }

            // A weather post always means today or tomorrow. The lead window
            // stops a save-the-date note from overriding the calendar.
            let lead = calendar.dateComponents([.day], from: postedDay, to: date).day ?? 0
            guard lead >= -1, lead <= cfg.maxLeadDays else { continue }

            out.append(RawAlert(kind: kind, date: date, line: line))
        }
        return out
    }

    /// An explicit date wins; "tomorrow"/"today" relative to the post is the
    /// fallback. Tolerates the district's real punctuation, e.g. "Closed on
    /// Monday, January, 26." — note the comma between month and day.
    func alertDate(in line: String, postedAt: Date) -> Date? {
        let low = line.lowercased()
        let monthNames = rules.months.keys.sorted { $0.count > $1.count }
        let alt = monthNames.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")

        let engine = AnswerEngine(pack: Self.emptyPack, rules: rules)

        if let g = AnswerEngine.capture(low, "(?<![a-z])(\(alt))\\.?\\s*,?\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:\\s*,?\\s*(\\d{4}))?(?![0-9])"),
           let mName = g[1], let dStr = g[2], let mo = rules.months[mName], let day = Int(dStr) {
            let year = g.count > 3 ? Int(g[3] ?? "") : nil
            if let d = engine.resolveMonthDay(month: mo, day: day, year: year, today: postedAt) { return d }
        }

        if let g = AnswerEngine.capture(low, "(?<![0-9])(\\d{1,2})[/.\\-](\\d{1,2})(?:[/.\\-](\\d{2,4}))?(?![0-9])"),
           let mStr = g[1], let dStr = g[2], let mo = Int(mStr), let day = Int(dStr) {
            var year: Int? = nil
            if g.count > 3, let yStr = g[3], var y = Int(yStr) {
                if y < 100 { y += 2000 }
                year = y
            }
            if let d = engine.resolveMonthDay(month: mo, day: day, year: year, today: postedAt) { return d }
        }

        if AnswerEngine.matches(low, "(?<![a-z])tomorrow(?![a-z])") {
            return calendar.date(byAdding: .day, value: 1, to: postedAt)
        }
        if AnswerEngine.matches(low, "(?<![a-z])today(?![a-z])") {
            return postedAt
        }
        return nil
    }

    // MARK: - Whole feed

    /// Parses a `/live_feeds` response body into merged alerts.
    ///
    /// Pass `schoolId` when reading one school's own feed: those alerts apply
    /// only to that school.
    func alerts(inFeed data: Data, schoolId: String = "", now: Date = Date()) -> [ClosingAlert] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let posts = root["live_feeds"] as? [[String: Any]] else { return [] }

        let freshDays = rules.alerts?.freshDays ?? 14
        guard let cutoff = calendar.date(byAdding: .day, value: -freshDays, to: now) else { return [] }

        var found: [ClosingAlert] = []
        for post in posts {
            let status = post["status"] as? String ?? ""
            let pubRaw = (post["publishing_at"] as? String) ?? (post["formatted_date"] as? String) ?? ""
            guard let posted = Self.parseFeedDate(pubRaw), posted >= cutoff else { continue }

            let id: String
            if let n = post["id"] as? Int { id = String(n) }
            else { id = (post["id"] as? String) ?? UUID().uuidString }

            for a in alerts(inStatus: status, postedAt: posted) {
                found.append(ClosingAlert(
                    id: "\(id)-\(a.kind)-\(AnswerEngine.iso(a.date))",
                    kind: a.kind,
                    date: AnswerEngine.iso(a.date),
                    postedAt: ISO8601DateFormatter().string(from: posted),
                    text: a.line,
                    author: post["author_name"] as? String ?? "",
                    scope: schoolId.isEmpty ? "district" : "school",
                    schoolId: schoolId.isEmpty ? nil : schoolId
                ))
            }
        }
        return Self.merge(found)
    }

    /// One alert per (school, kind, date), keeping the most recently posted
    /// wording — then drops any school alert that merely repeats a district
    /// one. Every school republishes the district's closing posts verbatim,
    /// so without this a district snow day shows up 21 times.
    static func merge(_ alerts: [ClosingAlert]) -> [ClosingAlert] {
        var best: [String: ClosingAlert] = [:]
        for a in alerts {
            let key = "\(a.schoolId ?? "")|\(a.kind)|\(a.date)"
            if let existing = best[key] {
                let lhs = a.postedDate ?? .distantPast
                let rhs = existing.postedDate ?? .distantPast
                if lhs <= rhs { continue }
            }
            best[key] = a
        }

        let all = Array(best.values)
        let districtKeys = Set(all
            .filter { ($0.schoolId ?? "").isEmpty }
            .map { "\($0.kind)|\($0.date)" })

        return all
            .filter { a in
                guard let sid = a.schoolId, !sid.isEmpty else { return true }
                return !districtKeys.contains("\(a.kind)|\(a.date)")
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Helpers

    static func parseFeedDate(_ s: String) -> Date? {
        if let d = ISO8601DateFormatter.withFractionalSeconds.date(from: s) { return d }
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        // "2026-02-23 14:16:59" — the feed's formatted_date fallback.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)
    }

    /// Live-feed bodies are small HTML fragments, mostly <br> and <p>.
    static func htmlToText(_ html: String) -> String {
        var t = html
        t = t.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?is)<br\\s*/?>", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?is)</(p|div|li|tr|h[1-6])>", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
        t = decodeEntities(t)
        t = t.replacingOccurrences(of: "[\\u00a0\\u200b]", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?m)^[ \\t]+|[ \\t]+$", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "(\r?\n){2,}", with: "\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ s: String) -> String {
        var t = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&#39;": "'", "&apos;": "'", "&nbsp;": " ", "&rsquo;": "\u{2019}",
                   "&lsquo;": "\u{2018}", "&ldquo;": "\u{201c}", "&rdquo;": "\u{201d}",
                   "&ndash;": "\u{2013}", "&mdash;": "\u{2014}", "&hellip;": "…"]
        for (k, v) in map { t = t.replacingOccurrences(of: k, with: v) }
        return t
    }

    /// A minimal pack, only so date helpers on AnswerEngine can be reused
    /// without a real one loaded.
    static let emptyPack = KnowledgePack(
        schemaVersion: 1, generatedAt: "",
        district: .init(name: "", url: "", phone: "", address: "", timeZone: "America/New_York"),
        schools: [], bells: [], calendar: [], facts: [], contacts: [],
        alertFeedUrl: nil, schoolFeedUrls: nil, alerts: nil
    )
}
