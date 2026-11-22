//
//  HomeView.swift
//  Schoolo
//
//  The first screen: today and tomorrow at a glance, and the two ways in.
//
//  The app used to open straight into the ask screen, which assumes everyone
//  arrives with a question. Plenty don't - they want to glance at the month,
//  or they just want to know about tomorrow without typing anything. Showing
//  the answer to the commonest question before it is asked is the whole point
//  of the top of this screen.
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let error = store.loadError {
                        errorBanner(error)
                    } else {
                        ForEach(store.activeAlerts) { AlertBanner(alert: $0) }
                        glance
                        ways
                        footnote
                    }
                }
                .padding()
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

    // MARK: - Today and tomorrow

    /// Answering the commonest question before it is asked. If the district
    /// publishes no calendar this says so rather than inventing a normal day.
    private var glance: some View {
        VStack(alignment: .leading, spacing: 10) {
            if engine?.publishesSchoolSchedule == false {
                Text("\(engine?.districtShort ?? "This district") hasn't published its school-day calendar, so I can't tell you about closings or breaks.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                dayRow("Today", offset: 0)
                Divider()
                dayRow("Tomorrow", offset: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.09)))
    }

    private func dayRow(_ label: String, offset: Int) -> some View {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
        let info = engine?.dayInfo(date, school: school)
        let kind = info?.kind ?? .regular

        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .frame(width: 78, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline(for: kind))
                    .font(.subheadline)
                    .foregroundStyle(tint(for: kind))
                if let reason = info?.reason, !reason.isEmpty {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func headline(for kind: DayKind) -> String {
        switch kind {
        case .closed:         return "No school"
        case .earlyDismissal: return "Early dismissal"
        case .delayedOpening: return "Delayed opening"
        case .weekend:        return "Weekend"
        default:              return "Normal full day"
        }
    }

    private func tint(for kind: DayKind) -> Color {
        switch kind {
        case .closed:         return .red
        case .earlyDismissal: return .orange
        case .delayedOpening: return .yellow
        case .weekend:        return .secondary
        default:              return .primary
        }
    }

    // MARK: - The two ways in

    private var ways: some View {
        VStack(spacing: 12) {
            NavigationLink { ContentView().environmentObject(store) } label: {
                card(icon: "bubble.left.and.text.bubble.right",
                     title: "Ask a question",
                     detail: "\"Is there school tomorrow?\" - in your own words")
            }
            NavigationLink { CalendarView().environmentObject(store) } label: {
                card(icon: "calendar",
                     title: "Calendar",
                     detail: "See the month, and where the days off fall")
            }
        }
        .buttonStyle(.plain)
    }

    private func card(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 38)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.09)))
    }

    // MARK: - Odds and ends

    private var footnote: some View {
        Text("Unofficial. Everything here comes from what your district publishes. For same-day closings, the district's own announcements are the authority.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Couldn't load", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
            Text(message).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
    }

    /// The short form, because the full name does not fit across a phone.
    private var districtTitle: String {
        guard let name = store.pack?.district.name else { return "Schoolo" }
        let short = AnswerEngine.shortDistrictName(name)
        return short.isEmpty ? "Schoolo" : short
    }
}
