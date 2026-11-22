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
    @AppStorage("defaultSchoolId") private var defaultSchoolId = ""

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
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private func card(icon: String, title: String, detail: String) -> some View {
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
                .frame(width: 86, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(verdict(for: info.kind)).font(.subheadline)
                if !info.reason.isEmpty {
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

    private func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "EEE d MMM"
        return f.string(from: d)
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
