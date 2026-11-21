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

    struct District: Codable {
        var name: String
        var url: String
        var phone: String
        var address: String
        var timeZone: String
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
