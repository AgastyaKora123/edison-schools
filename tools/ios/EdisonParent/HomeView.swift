//
//  HomeView.swift
//  Schoolo
//
//  The first screen: the answer, then the two ways in.
//
//  The app exists to answer one question, so that question's answer is the
//  screen - a single coloured card you can read from across the kitchen,
//  with everything else deliberately smaller. Tomorrow is the headline
//  because "is there school tomorrow" is the question; today is a line
//  underneath, because by the time you are asking, today is usually settled.
//
//  The colours are the point rather than decoration: a parent should know
//  the answer from the colour before reading a word of it.
//

import SwiftUI

struct HomeView: View {

    @EnvironmentObject private var store: KnowledgeStore
    @EnvironmentObject private var practice: PracticeStore
    @AppStorage("defaultSchoolId") private var defaultSchoolId = ""
    @AppStorage(DayBeforeReminders.enabledKey) private var remindDayBefore = false

    @State private var showSettings = false

    private var engine: AnswerEngine? { store.engine }

    private var school: School? {
        guard !defaultSchoolId.isEmpty else { return nil }
        return store.pack?.schools.first { $0.id == defaultSchoolId }
    }

    /// The district's own time zone: a parent checking from another state
    /// should still get the district's tomorrow, not their own.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        if let name = store.pack?.district.timeZone, let tz = TimeZone(identifier: name) {
            c.timeZone = tz
        }
        return c
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = store.loadError {
                        errorBanner(error)
                    } else {
                        ForEach(store.activeAlerts) { AlertBanner(alert: $0) }
                        if engine?.publishesSchoolSchedule == false {
                            noSchedule
                        } else {
                            hero
                            todayLine
                        }
                        ways
                        comingUp
                        remindOffer
                        footnote
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 28)
            }
            .navigationTitle(districtTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
        }
    }

    // MARK: - The answer

    private var tomorrow: Date {
        cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    }

    private var hero: some View {
        let info = engine?.dayInfo(tomorrow, school: school)
        let kind = info?.kind ?? .regular

        return VStack(alignment: .leading, spacing: 7) {
            Text("TOMORROW")
                .font(.caption.weight(.heavy))
                .kerning(1.6)
                .opacity(0.72)

            Text(verdict(for: kind))
                .font(.system(size: 38, weight: .bold, design: .serif))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)

            if let reason = info?.reason, !reason.isEmpty {
                Text(reason)
                    .font(.subheadline)
                    .opacity(0.92)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(longDate(tomorrow))
                .font(.footnote)
                .opacity(0.72)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(tint(for: kind))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var todayLine: some View {
        let info = engine?.dayInfo(Date(), school: school)
        let kind = info?.kind ?? .regular

        return HStack(spacing: 9) {
            Circle().fill(tint(for: kind)).frame(width: 8, height: 8)
            Text("Today").font(.subheadline.weight(.semibold))
            Text(verdict(for: kind)).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    /// Short enough to be read at a glance, and never hedged.
    private func verdict(for kind: DayKind) -> String {
        switch kind {
        case .closed:         return "No school"
        case .earlyDismissal: return "Early dismissal"
        case .delayedOpening: return "Delayed opening"
        case .weekend:        return "Weekend"
        case .unknown:        return "Beyond the calendar"
        default:              return "School as normal"
        }
    }

    /// Deep rather than bright: this card fills the screen, and a fluorescent
    /// red rectangle is unpleasant to be told bad news by.
    private func tint(for kind: DayKind) -> Color {
        switch kind {
        case .closed:         return Color(red: 0.631, green: 0.192, blue: 0.161)
        case .earlyDismissal: return Color(red: 0.698, green: 0.412, blue: 0.086)
        case .delayedOpening: return Color(red: 0.627, green: 0.498, blue: 0.075)
        case .weekend:        return Color(red: 0.278, green: 0.345, blue: 0.396)
        case .unknown:        return Color(red: 0.388, green: 0.420, blue: 0.447)
        default:              return Color(red: 0.145, green: 0.400, blue: 0.298)
        }
    }

    // MARK: - When the district publishes nothing

    private var noSchedule: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOT PUBLISHED")
                .font(.caption.weight(.heavy)).kerning(1.6).opacity(0.72)
            Text("No school calendar")
                .font(.system(size: 30, weight: .bold, design: .serif))
            Text("\(engine?.districtShort ?? "This district") publishes events but not its school-day schedule, so there are no closings or breaks to show.")
                .font(.subheadline).opacity(0.92)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(Color(red: 0.388, green: 0.420, blue: 0.447))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - The two ways in

    private var ways: some View {
        VStack(spacing: 10) {
            NavigationLink { ContentView().environmentObject(store) } label: {
                card(icon: "bubble.left.and.text.bubble.right",
                     title: "Ask a question",
                     detail: "\"When is spring break?\" - in your own words")
            }
            NavigationLink { CalendarView().environmentObject(store) } label: {
                card(icon: "calendar",
                     title: "Calendar",
                     detail: "The month, and where the days off fall")
            }
            NavigationLink { PracticeView().environmentObject(practice) } label: {
                card(icon: "rectangle.stack",
                     title: "Practice",
                     detail: practiceDetail,
                     badge: practice.dueCount())
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private var practiceDetail: String {
        let decks = practice.decks.count
        if decks == 0 { return "Turn your notes into questions" }
        let due = practice.dueCount()
        return due == 0
            ? "Nothing due - come back tomorrow"
            : "\(due) card\(due == 1 ? "" : "s") waiting"
    }

    private func card(icon: String, title: String, detail: String, badge: Int = 0) -> some View {
        HStack(spacing: 15) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 30)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if badge > 0 {
                Text("\(badge)")
                    .font(.caption.weight(.bold)).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 15)
        .padding(.horizontal, 17)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - Coming up

    /// The next few days that are not a normal full day.
    ///
    /// Weekends are skipped deliberately. They are not a normal full day
    /// either, but nobody needs telling that Saturday is coming, and a list
    /// of them would bury the two dates that actually matter.
    ///
    /// Ninety days is far enough to carry a parent across a break without
    /// walking the whole school year on every launch.
    private var upcoming: [(date: Date, info: AnswerEngine.DayInfo)] {
        guard let engine else { return [] }
        var out: [(Date, AnswerEngine.DayInfo)] = []
        var day = tomorrow

        for _ in 0..<90 {
            let info = engine.dayInfo(day, school: school)
            if info.kind != .regular && info.kind != .weekend && info.kind != .unknown {
                out.append((day, info))
                if out.count == 4 { break }
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    @ViewBuilder
    private var comingUp: some View {
        let rows = upcoming
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("COMING UP")
                    .font(.caption.weight(.heavy))
                    .kerning(1.6)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 9)

                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        if i > 0 { Divider().padding(.leading, 17) }
                        comingUpRow(row.date, row.info)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )
            }
            .padding(.top, 8)
        }
    }

    private func comingUpRow(_ date: Date, _ info: AnswerEngine.DayInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Circle()
                .fill(tint(for: info.kind))
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }

            Text(shortDate(date))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 100, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(verdict(for: info.kind)).font(.subheadline)
                // Districts often title an early dismissal "Early Dismissal",
                // which under a line already reading "Early dismissal" is
                // just the same words twice.
                if !info.reason.isEmpty, !saysTheSameThing(info.reason, verdict(for: info.kind)) {
                    Text(info.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 17)
    }

    /// Whether a calendar entry's title is really just the verdict again.
    /// Compared without case, spaces or punctuation, so "Early Dismissal"
    /// and "early dismissal." both count.
    private func saysTheSameThing(_ a: String, _ b: String) -> Bool {
        func bare(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        return bare(a) == bare(b)
    }

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "EEE d MMM"
        return f.string(from: d)
    }

    /// A setting nobody finds is a setting nobody has. Shown only while
    /// reminders are off and there is actually something to be reminded
    /// about, and it disappears for good the moment they are switched on.
    @ViewBuilder
    private var remindOffer: some View {
        if !remindDayBefore, !upcoming.isEmpty {
            Button { showSettings = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bell.badge")
                        .foregroundStyle(tint(for: .closed))
                    Text("Get told the night before")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .font(.subheadline)
                .padding(.vertical, 13)
                .padding(.horizontal, 15)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.primary.opacity(0.07), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
        }
    }

    // MARK: - Odds and ends

    private var footnote: some View {
        Text("Unofficial. Everything here comes from what your district publishes. For same-day closings, the district's own announcements are the authority.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 4)
            .padding(.top, 6)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Couldn't load", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.14)))
    }

    private func longDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: d)
    }

    /// The short form; the full name does not fit across a phone.
    private var districtTitle: String {
        guard let name = store.pack?.district.name else { return "Schoolo" }
        let short = AnswerEngine.shortDistrictName(name)
        return short.isEmpty ? "Schoolo" : short
    }
}
