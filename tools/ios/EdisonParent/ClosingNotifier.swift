//
//  ClosingNotifier.swift
//  School Answers
//
//  Local notifications for closings found in the district's live feed, and the
//  background task that looks for them.
//
//  What this is and is not:
//
//  These are LOCAL notifications. The phone finds the closing itself and tells
//  the person; nothing is pushed from a server. That is a deliberate trade:
//  real push (APNs) needs a server, an Apple Developer account and a device
//  token registry, and this app has no backend at all.
//
//  It works because Edison posts closings the afternoon before — 14:00 to
//  16:30 in every case on record. iOS typically runs a background refresh
//  task a handful of times a day, more often for apps people actually open,
//  so an announcement made at 3pm is usually surfaced well before bedtime.
//
//  It is NOT guaranteed. iOS decides when (or whether) to run the task — in
//  Low Power Mode or with Background App Refresh off, never. The app says so
//  in Settings rather than implying an alarm-clock guarantee, and the district
//  channels (ParentSquare, the website) remain the authority.
//

import Foundation
import UserNotifications

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

enum ClosingNotifier {

    /// Must also be listed under BGTaskSchedulerPermittedIdentifiers in
    /// Info.plist, or registration throws at launch.
    static let taskIdentifier = "io.github.agastyakora123.schoolanswers.checkClosings"

    // MARK: - Permission

    static func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: - Notifying

    /// Posts one notification per newly found closing.
    ///
    /// De-duplicated on the alert's id, which is derived from the post id plus
    /// the kind and date — so re-reading the same post never notifies twice,
    /// even across launches.
    static func notify(_ alerts: [ClosingAlert], schoolName: String? = nil) async {
        guard !alerts.isEmpty else { return }
        let center = UNUserNotificationCenter.current()

        guard await authorizationStatus() == .authorized else { return }

        var alreadySent = Set(UserDefaults.standard.stringArray(forKey: "notifiedAlertIds") ?? [])
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        alreadySent.formUnion(pending)
        alreadySent.formUnion(delivered)

        for a in alerts where !alreadySent.contains(a.id) {
            let content = UNMutableNotificationContent()
            content.title = a.headline
            content.body = Self.body(for: a, schoolName: schoolName)
            content.sound = .default
            content.interruptionLevel = a.kind == "closed" ? .timeSensitive : .active

            // Fire immediately: the news is already late by the time we see it.
            let req = UNNotificationRequest(identifier: a.id, content: content, trigger: nil)
            try? await center.add(req)
            alreadySent.insert(a.id)
        }

        // Keep the tail bounded; ids are never reused.
        UserDefaults.standard.set(Array(alreadySent.suffix(200)), forKey: "notifiedAlertIds")
    }

    /// What to call the schools when the parent has not named one. The
    /// chosen district's name is saved alongside its calendar, so a
    /// notification arriving at 6am says whose schools are shut.
    static var districtLabel: String {
        let saved = UserDefaults.standard.string(forKey: "districtName") ?? ""
        let short = AnswerEngine.shortDistrictName(saved)
        return short.isEmpty ? "Schools" : "\(short) schools"
    }

    static func body(for alert: ClosingAlert, schoolName: String?) -> String {
        let when = Self.friendlyDay(alert.date)
        let who = schoolName ?? districtLabel
        switch alert.kind {
        case "closed":
            return "\(who) are closed \(when). Tap for details."
        case "delayed_opening":
            return "\(who) open late \(when) — two-hour delayed opening. Tap for the new start times."
        case "early_dismissal":
            return "\(when.capitalizingFirst) is an early dismissal. Tap for dismissal times."
        default:
            return "\(who): \(alert.text)"
        }
    }

    /// "today" / "tomorrow" / "on Thursday, December 10".
    static func friendlyDay(_ iso: String) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: iso) else { return "soon" }

        let today = cal.startOfDay(for: Date())
        let days = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: d)).day ?? 0
        if days == 0 { return "today" }
        if days == 1 { return "tomorrow" }

        let long = DateFormatter()
        long.locale = Locale(identifier: "en_US")
        long.timeZone = cal.timeZone
        long.dateFormat = "EEEE, MMMM d"
        return "on \(long.string(from: d))"
    }

    // MARK: - Background refresh

    #if canImport(BackgroundTasks)

    /// Call once, before the app finishes launching.
    static func registerBackgroundTask(store: @escaping () -> KnowledgeStore?) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else { return }
            handle(refresh, store: store)
        }
    }

    static func scheduleNextCheck(after seconds: TimeInterval = 4 * 3600) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulator and Low Power Mode both refuse; not worth surfacing.
        }
    }

    private static func handle(_ task: BGAppRefreshTask, store: @escaping () -> KnowledgeStore?) {
        // Always queue the next one first: if this run is killed, the chain
        // continues.
        scheduleNextCheck()

        let work = Task { @MainActor in
            guard let s = store() else { return }
            if s.pack == nil { s.load() }
            let new = await s.checkAlerts()
            let schoolName = UserDefaults.standard.string(forKey: "defaultSchoolId")
                .flatMap { id in s.pack?.schools.first { $0.id == id }?.name }
            await notify(new, schoolName: schoolName)
        }

        task.expirationHandler = { work.cancel() }
        Task {
            _ = await work.result
            task.setTaskCompleted(success: true)
        }
    }

    #endif
}

extension String {
    var capitalizingFirst: String {
        guard let f = first else { return self }
        return f.uppercased() + dropFirst()
    }
}
