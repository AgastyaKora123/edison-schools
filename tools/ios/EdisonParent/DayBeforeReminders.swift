//
//  DayBeforeReminders.swift
//  Schoolo
//
//  New in 1.3: the app tells you the evening before, instead of waiting to be
//  asked.
//
//  How this differs from ClosingNotifier, which already exists:
//
//    ClosingNotifier handles the UNEXPECTED - a snow closing posted to the
//    district's live feed that afternoon. It cannot know in advance, so it
//    depends on iOS granting a background refresh, and it fires the moment it
//    finds something.
//
//    This file handles the PLANNED - every day off, early dismissal and late
//    start already printed in the school calendar. Those dates are known
//    months ahead, so each one is handed to iOS as a dated alarm the moment
//    the app is opened. No background refresh, no network, no server, and it
//    still fires with the phone in Low Power Mode and in Airplane Mode.
//
//  Three decisions worth knowing about:
//
//    A run of days gets ONE reminder. Winter break is ten days off; being
//    told "no school tomorrow" on each of ten evenings is how an app gets its
//    notifications switched off. Only the evening before the first day of a
//    run is used.
//
//    A day already announced on the live feed is skipped here, because
//    ClosingNotifier has already said it. Otherwise a snow day announced at
//    3pm would be announced again at 6pm by a different part of the same app.
//
//    The reminder is 6pm the night before by default - late enough that the
//    day's plans are being made, early enough to still change them.
//

import Foundation
import UserNotifications

enum DayBeforeReminders {

    // MARK: - Settings

    static let enabledKey = "remindDayBefore"
    static let hourKey = "remindDayBeforeHour"
    static let defaultHour = 18

    /// Pending reminders carry this prefix so they can be found and replaced
    /// without touching the closing alerts, which share the same queue.
    static let idPrefix = "dayBefore-"

    /// iOS keeps at most 64 pending notifications per app and silently drops
    /// the rest. Twenty is most of a school year's worth of runs, and leaves
    /// plenty of room for the alert layer.
    static let maxReminders = 20

    /// Far enough to cross a summer and reach the start of the next published
    /// year, so the first day back is not a surprise.
    static let horizonDays = 300

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// The hour of the evening before. Stored as an hour rather than a date
    /// so it means the same thing after the clocks change.
    static var hour: Int {
        guard let h = UserDefaults.standard.object(forKey: hourKey) as? Int,
              (0...23).contains(h) else { return defaultHour }
        return h
    }

    // MARK: - Which days are worth a reminder

    struct Upcoming: Equatable {
        var date: Date
        var kind: DayKind
        var reason: String
    }

    /// Only these three change what a family does the next morning. A regular
    /// day needs no telling, a weekend tells itself, and `.unknown` means the
    /// calendar has run out - which is a thing to admit on screen, not to
    /// wake somebody up for.
    static func worthTelling(_ kind: DayKind) -> Bool {
        kind == .closed || kind == .earlyDismissal || kind == .delayedOpening
    }

    /// The days to remind about, soonest first.
    ///
    /// Pure: give it an engine and a date and it always answers the same way,
    /// which is what makes it testable without a notification queue.
    static func upcoming(engine: AnswerEngine,
                         school: School?,
                         now: Date,
                         calendar cal: Calendar,
                         limit: Int = maxReminders,
                         horizon: Int = horizonDays) -> [Upcoming] {
        var out: [Upcoming] = []
        let today = cal.startOfDay(for: now)
        guard var day = cal.date(byAdding: .day, value: 1, to: today) else { return [] }

        for _ in 0..<horizon {
            let info = engine.dayInfo(day, school: school)

            // info.alert means this came from the live feed, and the alert
            // layer has already notified. Saying it twice is worse than not
            // saying it at all.
            if worthTelling(info.kind), info.alert == nil,
               previousSchoolDayKind(before: day, engine: engine, school: school, calendar: cal) != info.kind {
                out.append(Upcoming(date: day, kind: info.kind, reason: info.reason))
                if out.count >= limit { break }
            }

            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    /// What kind of day the nearest school day BEFORE `day` was.
    ///
    /// Looking back past the weekend is the point: a break that starts on a
    /// Friday is still the same break on Monday, and Monday should not get
    /// its own reminder.
    static func previousSchoolDayKind(before day: Date,
                                      engine: AnswerEngine,
                                      school: School?,
                                      calendar cal: Calendar) -> DayKind? {
        var d = day
        for _ in 0..<7 {
            guard let p = cal.date(byAdding: .day, value: -1, to: d) else { return nil }
            d = p
            let info = engine.dayInfo(d, school: school)
            if info.kind != .weekend { return info.kind }
        }
        return nil
    }

    // MARK: - Words

    static func title(for kind: DayKind) -> String {
        switch kind {
        case .closed:         return "No school tomorrow"
        case .earlyDismissal: return "Early dismissal tomorrow"
        case .delayedOpening: return "Late start tomorrow"
        default:              return "Tomorrow is different"
        }
    }

    /// `who` is "Edison schools" or similar; `weekday` is "Thursday".
    ///
    /// The reason is appended only when it adds something. Districts title an
    /// early dismissal "Early Dismissal", and under a line already reading
    /// "Early dismissal tomorrow" that is the same words twice.
    static func message(kind: DayKind, reason: String, weekday: String, who: String) -> String {
        let base: String
        switch kind {
        case .closed:         base = "\(who) are closed \(weekday)"
        case .earlyDismissal: base = "School lets out early on \(weekday)"
        case .delayedOpening: base = "School opens later than usual on \(weekday)"
        default:              base = "\(weekday) is not a normal school day"
        }

        // Calendar titles arrive from a dozen different district websites and
        // some carry double spaces or a stray newline from the page they were
        // typed on. Tidy here rather than hoping.
        let r = reason
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let add = (r.isEmpty || saysTheSameThing(r, title(for: kind))) ? "" : " — \(r)"
        return base + add + "."
    }

    static func saysTheSameThing(_ a: String, _ b: String) -> Bool {
        func bare(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter }) }
        let x = bare(a), y = bare(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x.contains(y) || y.contains(x)
    }

    /// Whose schools, for the notification text. Taken from the loaded
    /// information rather than from a saved setting, so it is right even on
    /// the very first launch after picking a district.
    static func who(for pack: KnowledgePack?) -> String {
        guard let name = pack?.district.name else { return "School" }
        let short = AnswerEngine.shortDistrictName(name)
        return short.isEmpty ? "School" : "\(short) schools"
    }

    // MARK: - Timing

    /// 6pm (or whatever hour is set) on the evening before `day`.
    static func fireDate(dayBefore day: Date, hour: Int, calendar cal: Calendar) -> Date? {
        guard let eve = cal.date(byAdding: .day, value: -1, to: day) else { return nil }
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: eve)
    }

    static func identifier(for u: Upcoming, calendar cal: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return idPrefix + f.string(from: u.date) + "-" + u.kind.rawValue
    }

    // MARK: - Scheduling

    /// Replaces every reminder this app has queued with a fresh set.
    ///
    /// Replace rather than top up: the calendar can change under the app (a
    /// refreshed pack, a different district), and reconciling two lists is
    /// how duplicate and ghost reminders happen. Cancelling ours and
    /// re-adding is cheap and cannot drift.
    ///
    /// Returns how many were queued, for the Settings screen to show.
    @discardableResult
    static func reschedule(engine: AnswerEngine?,
                           school: School?,
                           timeZoneName: String?,
                           who: String,
                           now: Date = Date()) async -> Int {
        await cancelAll()

        guard isEnabled, let engine else { return 0 }
        guard await ClosingNotifier.authorizationStatus() == .authorized else { return 0 }

        var cal = Calendar(identifier: .gregorian)
        if let name = timeZoneName, let tz = TimeZone(identifier: name) { cal.timeZone = tz }

        let weekdayName = DateFormatter()
        weekdayName.locale = Locale(identifier: "en_US")
        weekdayName.timeZone = cal.timeZone
        weekdayName.dateFormat = "EEEE"

        let center = UNUserNotificationCenter.current()
        let chosenHour = hour
        var queued = 0

        for day in upcoming(engine: engine, school: school, now: now, calendar: cal) {
            // A reminder whose evening has already passed is not scheduled.
            // The home screen is already shouting about tomorrow in letters
            // an inch high, so there is nothing to rescue.
            guard let fire = fireDate(dayBefore: day.date, hour: chosenHour, calendar: cal),
                  fire > now else { continue }

            var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            comps.timeZone = cal.timeZone

            let content = UNMutableNotificationContent()
            content.title = title(for: day.kind)
            content.body = message(kind: day.kind,
                                   reason: day.reason,
                                   weekday: weekdayName.string(from: day.date),
                                   who: who)
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: identifier(for: day, calendar: cal),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))

            do {
                try await center.add(request)
                queued += 1
            } catch {
                // One bad date should not cost the rest of the year.
            }
        }
        return queued
    }

    static func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(idPrefix) }
        guard !ours.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ours)
    }

    static func pendingCount() async -> Int {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(idPrefix) }
            .count
    }
}

extension KnowledgeStore {

    /// One place that knows how to rebuild the reminders, so every caller -
    /// launch, coming back to the app, changing the setting, changing
    /// district, the background task - cannot do it differently.
    @discardableResult
    func rescheduleDayBeforeReminders() async -> Int {
        let chosen = UserDefaults.standard.string(forKey: "defaultSchoolId") ?? ""
        let school = pack?.schools.first { $0.id == chosen }
        return await DayBeforeReminders.reschedule(engine: engine,
                                                   school: school,
                                                   timeZoneName: pack?.district.timeZone,
                                                   who: DayBeforeReminders.who(for: pack))
    }
}
