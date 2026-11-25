//
//  Models.swift
//  Edison Parent
//
//  Codable mirrors of dist/knowledge-pack.json and ingest/rules/intents.json.
//  Field names match the JSON exactly, so no CodingKeys are needed.
//

import Foundation

// MARK: - Knowledge pack

struct KnowledgePack: Codable {
    var schemaVersion: Int
    var generatedAt: String
    /// True when the app read this district's calendar itself rather than
    /// being handed a file prepared on a desktop. Such a pack has no bell
    /// times, office numbers or page text, so the screens that show those
    /// can say so instead of looking broken.
    var builtInApp: Bool?
    var district: District
    var schools: [School]
    var bells: [BellSchedule]
    var calendar: [CalendarEntry]
    var facts: [Fact]
    var contacts: [Contact]
    /// Where the app polls for closings announced after this pack was built.
    var alertFeedUrl: String?
    /// Each school's own live feed, keyed by school id — where a
    /// single-building closure appears.
    var schoolFeedUrls: [String: String]?
    /// Closings known at build time; the app merges live ones over these.
    var alerts: [ClosingAlert]?
    /// Who works at the saved schools. Never in the file on disk: it is read
    /// from each school's own published directory while the app is running
    /// and merged in before a question is answered, the same way live
    /// closings are. Two thousand names would be four hundred kilobytes of
    /// app going stale the first time somebody changes job.
    var staff: [StaffMember]?

    struct District: Codable {
        var name: String
        var url: String
        var phone: String
        var address: String
        var timeZone: String
        /// Where this district keeps its calendar, events, hours and feed
        /// pages, when they are not at the usual addresses. Optional: packs
        /// built before this existed simply have no entry, and the engine
        /// falls back to the standard paths.
        var pages: [String: String]?
        /// Names for the groupings a district uses beyond elementary, middle
        /// and high - a preschool, an academy, a career centre. Its own names,
        /// from its own file, rather than one district's written into the app.
        var levelLabels: [String: String]?
    }

    /// When the pack was built, for the "last updated" line in Settings.
    var generatedDate: Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: generatedAt)
    }
}

struct School: Codable, Identifiable, Hashable {
    var id: String            // CMS alias: "hhms", "les", ...
    var name: String          // "Herbert Hoover Middle School"
    var shortName: String     // "Herbert Hoover"
    var level: String         // elementary | middle | high | academy | eelc | fdr
    var aliases: [String]
    var orgId: Int
    var host: String
    var url: String
    var sectionId: String

    /// Writing `init(from:)` below costs the free memberwise one, and the
    /// district builder needs to make these itself. Everything a
    /// built-on-the-phone district has no way of knowing defaults to empty.
    init(id: String, name: String, shortName: String = "", level: String = "",
         aliases: [String] = [], orgId: Int = 0, host: String = "",
         url: String = "", sectionId: String = "") {
        self.id = id
        self.name = name
        self.shortName = shortName.isEmpty ? name : shortName
        self.level = level
        self.aliases = aliases
        self.orgId = orgId
        self.host = host
        self.url = url
        self.sectionId = sectionId
    }

    /// Same reasoning as Fact: an empty list written as null, or a field a
    /// district simply does not have, must not throw away the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id        = try c.decode(String.self, forKey: .id)
        name      = try c.decode(String.self, forKey: .name)
        shortName = try c.decodeIfPresent(String.self, forKey: .shortName) ?? name
        level     = try c.decodeIfPresent(String.self, forKey: .level) ?? ""
        aliases   = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        orgId     = try c.decodeIfPresent(Int.self, forKey: .orgId) ?? 0
        host      = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        url       = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        sectionId = try c.decodeIfPresent(String.self, forKey: .sectionId) ?? ""
    }

    /// Everything a question might call this school, longest first so
    /// "james madison primary" is preferred over "madison".
    var matchTerms: [String] {
        var t = [name, shortName] + aliases
        t = t.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        return Array(Set(t.filter { $0.count >= 2 })).sorted { $0.count > $1.count }
    }
}

struct BellSchedule: Codable {
    var level: String
    var label: String
    var regular: TimeSpan?
    var delayed: TimeSpan?
    var early: TimeSpan?

    struct TimeSpan: Codable {
        var start: String     // "08:55"
        var end: String       // "15:30"
    }

    func span(for dayKind: DayKind) -> TimeSpan? {
        switch dayKind {
        case .delayedOpening: return delayed
        case .earlyDismissal: return early
        default:              return regular
        }
    }
}

struct CalendarEntry: Codable {
    var date: String          // inclusive start, yyyy-MM-dd
    var endDate: String       // INCLUSIVE end - ingest already un-did iCal's
                              // exclusive DTEND, so a one-day event has
                              // date == endDate.
    var title: String
    var rawTitle: String
    var kind: String          // closed | break | early_dismissal | single_session
                              // | delayed_opening | no_school_students
                              // | first_day | last_day | event
    var scope: String         // district | school
    var schoolIds: [String]
    var allDay: Bool
    var startTime: String?
    var url: String

    /// As with School: the tolerant decoder below costs the free memberwise
    /// initialiser, and the district builder makes these itself.
    init(date: String, endDate: String, title: String, rawTitle: String,
         kind: String, scope: String, schoolIds: [String], allDay: Bool,
         startTime: String?, url: String) {
        self.date = date
        self.endDate = endDate
        self.title = title
        self.rawTitle = rawTitle
        self.kind = kind
        self.scope = scope
        self.schoolIds = schoolIds
        self.allDay = allDay
        self.startTime = startTime
        self.url = url
    }

    /// Same reasoning as Fact and School. A districtwide entry has no school
    /// ids, and an empty list is written as null.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date      = try c.decode(String.self, forKey: .date)
        endDate   = try c.decodeIfPresent(String.self, forKey: .endDate) ?? date
        title     = try c.decode(String.self, forKey: .title)
        rawTitle  = try c.decodeIfPresent(String.self, forKey: .rawTitle) ?? title
        kind      = try c.decodeIfPresent(String.self, forKey: .kind) ?? "event"
        scope     = try c.decodeIfPresent(String.self, forKey: .scope) ?? "district"
        schoolIds = try c.decodeIfPresent([String].self, forKey: .schoolIds) ?? []
        allDay    = try c.decodeIfPresent(Bool.self, forKey: .allDay) ?? true
        startTime = try c.decodeIfPresent(String.self, forKey: .startTime)
        url       = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
    }
}

struct Fact: Codable, Identifiable {
    var id: String
    var title: String
    var text: String
    var url: String
    var schoolId: String
    var tags: [String]
    /// "parent" or "staff". Staff pages are kept so the app covers everything
    /// the district publishes, but they rank below parent pages.
    var audience: String?

    /// A missing or null list of tags means no tags, not a broken file.
    ///
    /// This mattered more than it looks. The information file had `"tags":
    /// null` on 148 pages - PowerShell writes an empty list that way - and
    /// the strict decoder refused the entire file over it. Not one page of
    /// the district's information loaded, and every single check in the app
    /// failed on the same line. The file is also fixed at the other end, but
    /// one bad field should never cost the whole app.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(String.self, forKey: .id)
        title    = try c.decode(String.self, forKey: .title)
        text     = try c.decode(String.self, forKey: .text)
        url      = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        schoolId = try c.decodeIfPresent(String.self, forKey: .schoolId) ?? ""
        tags     = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        audience = try c.decodeIfPresent(String.self, forKey: .audience)
    }
}

/// An operational announcement read out of the district's public live feed -
/// a weather closing, a delayed opening, an added early dismissal. These
/// outrank the published calendar, which is exactly wrong on a snow day.
struct ClosingAlert: Codable, Identifiable, Hashable {
    var id: String
    var kind: String          // closed | delayed_opening | early_dismissal
    var date: String          // yyyy-MM-dd, the day it affects
    var postedAt: String
    var text: String
    var author: String
    var scope: String
    /// Empty for a district-wide announcement; otherwise the only school it
    /// applies to. Lincoln losing heat must not close Woodbrook.
    var schoolId: String?

    var postedDate: Date? {
        ISO8601DateFormatter().date(from: postedAt)
            ?? ISO8601DateFormatter.withFractionalSeconds.date(from: postedAt)
    }

    /// Closure outranks a delayed opening outranks a shortened day.
    var rank: Int {
        switch kind {
        case "closed":          return 3
        case "delayed_opening": return 2
        case "early_dismissal": return 1
        default:                return 0
        }
    }

    var headline: String {
        switch kind {
        case "closed":          return "Schools closed"
        case "delayed_opening": return "Delayed opening"
        case "early_dismissal": return "Early dismissal"
        default:                return "District announcement"
        }
    }
}

extension ISO8601DateFormatter {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// One person on a school's published staff list.
///
/// Names, job titles and departments only. The directory feed these come from
/// also carries an email field; it is read and discarded on the way in, and
/// this type has nowhere to put it on purpose. Most Edison schools leave that
/// field blank and its high school has explicitly hidden every one of its
/// entries, so a parent who needs to email a teacher is sent to the school's
/// own page - current, and the district's to change.
struct StaffMember: Codable {
    var schoolId: String
    var name: String
    var first: String
    var last: String
    var title: String
    var department: String
}

struct Contact: Codable {
    var schoolId: String
    var phone: String
    var fax: String
    var address: String
    var phones: [String]
    var emails: [String]
    var url: String
}

// MARK: - Rules

struct Rules: Codable {
    var rulesVersion: Int
    var dateWords: [String: DateWord]
    var weekdays: [String: Int]
    var months: [String: Int]
    var breaks: [String: [String]]
    var levelWords: [String: [String]]
    var scheduleWords: [String: [String]]
    var intents: [Intent]
    var alerts: AlertRules?
    var disclaimer: String?

    /// Named days that are not on any school calendar but that people ask
    /// about anyway - "is there school on christmas eve". Month and day.
    var holidays: [String: [Int]]?

    /// Wording that means "some particular day" without naming one. If the
    /// question has one of these and no date could be worked out, saying so
    /// beats confidently answering about today.
    var dayHints: [String]?

    /// What a calendar entry means, worked out from its title. Used when the
    /// app reads a district's calendar itself rather than being handed a
    /// prepared file.
    var eventKinds: [EventKindRule]?

    /// Noise districts put at the front of their calendar titles -
    /// "Districtwide:", "MON - ", "8:00 am - ".
    var titlePrefixes: [String]?

    struct EventKindRule: Codable {
        var kind: String
        var pattern: String
    }

    /// How to read closings out of the district's live feed. Shared verbatim
    /// with engine/Alerts.ps1 so both parsers behave identically.
    struct AlertRules: Codable {
        var feedPath: String
        var freshDays: Int
        var maxLeadDays: Int
        var kinds: [String: [String]]
        var subjectRequiredFor: [String]
        var subjects: [String]
        var reject: [String]
    }

    struct DateWord: Codable {
        var offsetDays: Int
    }

    struct Intent: Codable {
        var id: String
        var resolver: String
        var priority: Double
        /// Hard gate: at least one of these must appear in the query, or the
        /// intent scores zero however well its patterns match.
        var requireAny: [String]?
        var patterns: [String]
        var keywords: [String: Double]
    }
}

// MARK: - Engine output

enum DayKind: String {
    case weekend
    case closed
    case earlyDismissal = "early_dismissal"
    case delayedOpening = "delayed_opening"
    case regular
    case unknown
}

struct Answer: Identifiable {
    let id = UUID()
    var text: String
    var intent: String
    var kind: String
    var sources: [String]
    var confidence: Double
    var schoolId: String
    var debug: Debug

    struct Debug {
        var resolver: String
        var topIntent: String
        var topScore: Double
        var dateSlot: String
        var schoolSlot: String
        var levelSlot: String
        var scheduleSlot: String
        var breakSlot: String
    }
}
