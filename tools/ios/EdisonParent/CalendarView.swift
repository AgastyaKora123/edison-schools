//
//  CalendarView.swift
//  Schoolo
//
//  A month at a glance.
//
//  Asking is better when you have a question. Browsing is better when you
//  don't - when you want to see where the days off fall before booking
//  something, or just to know what sort of month it is. The two are not
//  competing; they answer different moods.
//
//  Only days that are not a normal full day are marked. A calendar where
//  every square is coloured tells you nothing.
//

import SwiftUI

struct CalendarView: View {

    @EnvironmentObject private var store: KnowledgeStore
    @AppStorage("defaultSchoolId") private var defaultSchoolId = ""

    @State private var month: Date = Date()
    @State private var selected: Date?

    private var engine: AnswerEngine? { store.engine }

    private var school: School? {
        guard !defaultSchoolId.isEmpty else { return nil }
        return store.pack?.schools.first { $0.id == defaultSchoolId }
    }

    /// The district's own time zone, so a parent looking at this in another
    /// state still sees the district's month rather than their own.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        if let name = store.pack?.district.timeZone, let tz = TimeZone(identifier: name) {
            c.timeZone = tz
        }
        return c
    }

    var body: some View {
        Group {
            if engine == nil {
                ContentUnavailableView("No calendar yet",
                                       systemImage: "calendar",
                                       description: Text("The app is still loading its information."))
            } else if engine?.publishesSchoolSchedule == false {
                noSchedule
            } else {
                calendar
            }
        }
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - When the district publishes nothing

    private var noSchedule: some View {
        ContentUnavailableView {
            Label("Nothing published", systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text("\(engine?.districtShort ?? "This district") publishes events to its calendar but not its school-day schedule, so there are no closings or breaks to show.\n\nThey are usually on the district's own calendar page.")
        } actions: {
            if let s = engine?.links.calendar, let u = URL(string: s), !s.isEmpty {
                Link("Open the district's calendar", destination: u)
            }
        }
    }

    // MARK: - The month

    private var calendar: some View {
        ScrollView {
            VStack(spacing: 18) {
                monthHeader
                weekdayHeader
                grid
                if let selected { dayDetail(selected) }
                legend
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    private var monthHeader: some View {
        HStack {
            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left").padding(8)
            }
            .accessibilityLabel("Previous month")

            Spacer()
            Text(monthTitle)
                .font(.headline)
                .monospacedDigit()
            Spacer()

            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right").padding(8)
            }
            .accessibilityLabel("Next month")
        }
        .padding(.top, 8)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 4) {
            ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { _, d in
                Text(d)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var grid: some View {
        let days = monthDays()
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7),
                         spacing: 4) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 46)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let info = engine?.dayInfo(day, school: school)
        let kind = info?.kind ?? .regular
        let isToday = cal.isDateInToday(day)
        let isSelected = selected.map { cal.isDate($0, inSameDayAs: day) } ?? false

        return Button {
            selected = isSelected ? nil : day
        } label: {
            VStack(spacing: 3) {
                Text("\(cal.component(.day, from: day))")
                    .font(.callout.weight(isToday ? .bold : .regular))
                    .monospacedDigit()
                Circle()
                    .fill(colour(for: kind))
                    .frame(width: 6, height: 6)
                    .opacity(colour(for: kind) == .clear ? 0 : 1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isToday ? Color.accentColor : .clear, lineWidth: 1.5)
            )
            .foregroundStyle(kind == .weekend ? Color.secondary : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText(day, kind: kind, info: info))
    }

    /// Only the days that are not a normal full day get a dot. A calendar
    /// where everything is coloured says nothing.
    private func colour(for kind: DayKind) -> Color {
        switch kind {
        case .closed:         return .red
        case .earlyDismissal: return .orange
        case .delayedOpening: return .yellow
        default:              return .clear
        }
    }

    private func label(for kind: DayKind) -> String {
        switch kind {
        case .closed:         return "No school"
        case .earlyDismissal: return "Early dismissal"
        case .delayedOpening: return "Delayed opening"
        case .weekend:        return "Weekend"
        default:              return "Normal full day"
        }
    }

    private func accessibilityText(_ day: Date, kind: DayKind, info: AnswerEngine.DayInfo?) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "EEEE d MMMM"
        var s = f.string(from: day) + ", " + label(for: kind)
        if let reason = info?.reason, !reason.isEmpty { s += ", " + reason }
        return s
    }

    // MARK: - The day you tapped

    private func dayDetail(_ day: Date) -> some View {
        let info = engine?.dayInfo(day, school: school)
        let entries = engine?.entries(on: day, school: school) ?? []
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "EEEE, d MMMM yyyy"

        return VStack(alignment: .leading, spacing: 8) {
            Text(f.string(from: day)).font(.subheadline.weight(.semibold))
            Text(label(for: info?.kind ?? .regular))
                .font(.caption)
                .foregroundStyle(colour(for: info?.kind ?? .regular) == .clear
                                 ? Color.secondary : colour(for: info?.kind ?? .regular))
            if entries.isEmpty {
                Text("Nothing on the calendar for this day.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                    Text("• " + e.title).font(.footnote)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.09)))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach([DayKind.closed, .earlyDismissal, .delayedOpening], id: \.self) { k in
                HStack(spacing: 5) {
                    Circle().fill(colour(for: k)).frame(width: 6, height: 6)
                    Text(label(for: k)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Dates

    private var monthTitle: String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "MMMM yyyy"
        return f.string(from: month)
    }

    private func shiftMonth(_ by: Int) {
        if let d = cal.date(byAdding: .month, value: by, to: month) {
            month = d
            selected = nil
        }
    }

    /// The month's days, padded with blanks so the first lands on its weekday.
    private func monthDays() -> [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: month),
              let first = cal.date(from: cal.dateComponents([.year, .month], from: month))
        else { return [] }

        let leading = cal.component(.weekday, from: first) - 1   // Sunday = 0
        var out: [Date?] = Array(repeating: nil, count: leading)
        for d in range {
            if let day = cal.date(byAdding: .day, value: d - 1, to: first) { out.append(day) }
        }
        return out
    }
}
