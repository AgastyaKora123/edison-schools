//
//  SettingsView.swift
//  Edison Parent
//
//  Pick a default school (so "is there school tomorrow" answers for the right
//  one), see when the information was built, and optionally point the app at a
//  URL to pull a newer pack from.
//

import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {

    @EnvironmentObject private var store: KnowledgeStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage("defaultSchoolId") private var defaultSchoolId = ""
    @AppStorage("refreshURL") private var refreshURL = ""
    @AppStorage(DayBeforeReminders.enabledKey) private var remindDayBefore = false
    @AppStorage(DayBeforeReminders.hourKey) private var remindHour = DayBeforeReminders.defaultHour
    @State private var notifyStatus: UNAuthorizationStatus = .notDetermined
    @State private var reminderCount = 0
    @State private var showDistrictPicker = false

    /// Why there might be no reminders, which is more useful than a bare
    /// zero: "none set" reads like a fault when it only means the published
    /// calendar has run out.
    private var reminderNote: String {
        if notifyStatus != .authorized { return "Allow notifications below and these will start." }
        if reminderCount == 0 { return "Nothing left in the published calendar to remind you about." }
        return reminderCount == 1 ? "1 reminder set." : "\(reminderCount) reminders set."
    }

    /// The district's own website, calendar and feed, from the information
    /// file. Empty entries are dropped rather than shown as dead links.
    private var districtLinks: [(String, String)] {
        guard let d = store.pack?.district else { return [] }
        let site = d.url.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let pages = d.pages ?? [:]
        var out: [(String, String)] = []
        if !site.isEmpty { out.append((d.name, site)) }
        if let c = pages["calendar"] ?? (site.isEmpty ? nil : site + "/events/"), !c.isEmpty {
            out.append(("District calendar", c))
        }
        if let f = pages["feed"] ?? (site.isEmpty ? nil : site + "/live-feed/"), !f.isEmpty {
            out.append(("Closings and announcements", f))
        }
        return out
    }

    /// A named type rather than a tuple: Swift has no key paths into tuple
    /// elements, so `ForEach(..., id: \.0)` would not compile.
    private struct LevelGroup: Identifiable {
        var id: String { level }
        var level: String
        var label: String
        var schools: [School]
    }

    private var schoolsByLevel: [LevelGroup] {
        let order = ["elementary", "middle", "high", "academy", "eelc", "fdr", "other"]
        let groups = Dictionary(grouping: store.pack?.schools ?? [], by: \.level)
        return order.compactMap { lvl in
            guard let list = groups[lvl], !list.isEmpty else { return nil }
            return LevelGroup(level: lvl,
                              label: AnswerEngine.levelLabel(lvl, labels: store.pack?.district.levelLabels),
                              schools: list.sorted { $0.name < $1.name })
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("My school", selection: $defaultSchoolId) {
                        Text("Not set").tag("")
                        ForEach(schoolsByLevel) { group in
                            Section(group.label) {
                                ForEach(group.schools) { s in
                                    Text(s.name).tag(s.id)
                                }
                            }
                        }
                    }
                } header: {
                    Text("My school")
                } footer: {
                    Text("Used when a question doesn't name a school - so \"is there school tomorrow\" answers for yours. Naming a school in the question always wins.")
                }

                Section {
                    Button {
                        showDistrictPicker = true
                    } label: {
                        HStack {
                            Text("Change district")
                            Spacer()
                            Text(store.chosenDistrictName.isEmpty
                                 ? (store.pack?.district.name ?? "")
                                 : store.chosenDistrictName)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } footer: {
                    Text(store.packWasBuiltInApp
                         ? "Read from this district's own published calendar. Bell times and office numbers are not published that way, so the app will say it doesn't know them."
                         : "Works for any district whose website runs on the same system.")
                }

                if let pack = store.pack {
                    Section("Information") {
                        LabeledContent("District", value: pack.district.name)
                        LabeledContent("Schools", value: "\(pack.schools.count)")
                        LabeledContent("Calendar entries", value: "\(pack.calendar.count)")
                        LabeledContent("Pages indexed", value: "\(pack.facts.count)")
                        LabeledContent("Built", value: builtDescription(pack))
                    }
                }

                Section {
                    Toggle("Remind me the night before", isOn: $remindDayBefore)
                        .onChange(of: remindDayBefore) { _, on in
                            Task {
                                if on, notifyStatus != .authorized {
                                    _ = await ClosingNotifier.requestPermission()
                                    notifyStatus = await ClosingNotifier.authorizationStatus()
                                }
                                reminderCount = await store.rescheduleDayBeforeReminders()
                            }
                        }

                    if remindDayBefore {
                        Picker("Send it at", selection: $remindHour) {
                            ForEach(Array(15...21), id: \.self) { h in
                                Text(AnswerEngine.format12(String(format: "%d:00", h))).tag(h)
                            }
                        }
                        .onChange(of: remindHour) { _, _ in
                            Task { reminderCount = await store.rescheduleDayBeforeReminders() }
                        }

                        if notifyStatus == .denied {
                            Link("Notifications are switched off — open Settings",
                                 destination: URL(string: UIApplication.openSettingsURLString)!)
                                .font(.footnote)
                        } else {
                            Text(reminderNote).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("The night before")
                } footer: {
                    Text("Every day off, early dismissal and late start already in the school calendar, sent the evening before. A whole break gets one reminder, not one every night. These are handed to iOS in advance, so they arrive even with no signal and in Low Power Mode.")
                }

                Section {
                    HStack {
                        Text("Closing alerts")
                        Spacer()
                        switch notifyStatus {
                        case .authorized:
                            Label("On", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green).font(.footnote)
                        case .denied:
                            Link("Off — open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                                .font(.footnote)
                        default:
                            Button("Turn on") {
                                Task {
                                    _ = await ClosingNotifier.requestPermission()
                                    notifyStatus = await ClosingNotifier.authorizationStatus()
                                }
                            }
                            .font(.footnote)
                        }
                    }

                    Button {
                        Task {
                            let new = await store.checkAlerts()
                            await ClosingNotifier.notify(new, schoolName: store.defaultSchoolName)
                        }
                    } label: {
                        Text("Check for closings now")
                    }

                    if let t = store.lastAlertCheck {
                        Text("Last checked \(t.formatted(date: .omitted, time: .shortened)) · \(store.activeAlerts.count) active")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Closing alerts")
                } footer: {
                    Text("The district posts weather closings and delayed openings to its public feed the afternoon before. The app checks a few times a day and notifies you. iOS decides when background checks run, so this is a head start, not a guarantee — ParentSquare and the district website are still the authority.")
                }

                Section {
                    TextField("https://…/knowledge-pack.json", text: $refreshURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.footnote)

                    Button {
                        Task { await store.refresh() }
                    } label: {
                        HStack {
                            Text("Check for updated information")
                            if store.isRefreshing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(store.isRefreshing || refreshURL.isEmpty)

                    if let note = store.lastRefreshNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Updates")
                } footer: {
                    Text("Optional. Run the ingest script on a schedule, publish knowledge-pack.json to any static host, and paste the URL here. Without it the app keeps using the information it shipped with.")
                }

                Section {
                    // These come from the information file. Written in, they
                    // sent a parent in another state to Edison's website.
                    ForEach(districtLinks, id: \.0) { label, address in
                        if let u = URL(string: address) {
                            Link(label, destination: u)
                        }
                    }
                } header: {
                    Text("On the district website")
                } footer: {
                    Text("This is an unofficial app. It reads the district's public pages and calendar. For same-day closings, ParentSquare and the district website are the authority.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                notifyStatus = await ClosingNotifier.authorizationStatus()
                reminderCount = await DayBeforeReminders.pendingCount()
            }
            .sheet(isPresented: $showDistrictPicker) { DistrictPickerView().environmentObject(store) }
        }
    }

    private func builtDescription(_ pack: KnowledgePack) -> String {
        guard let d = pack.generatedDate else { return pack.generatedAt }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}
