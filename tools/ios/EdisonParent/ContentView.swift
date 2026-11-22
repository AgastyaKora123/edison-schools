//
//  ContentView.swift
//  Edison Parent
//
//  The ask-a-question screen: a transcript, a text field, and suggestion
//  chips for the handful of things parents ask most.
//

import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var store: KnowledgeStore
    @AppStorage("defaultSchoolId") private var defaultSchoolId = ""

    @State private var draft = ""
    @State private var turns: [Turn] = []
    @State private var showSettings = false
    @FocusState private var fieldFocused: Bool

    struct Turn: Identifiable {
        let id = UUID()
        var question: String
        var answer: Answer
    }

    private let suggestions = [
        "Is there school tomorrow?",
        "What time does school start?",
        "When is the next early dismissal?",
        "When is spring break?",
        "How do I report my child absent?",
        "What's on the calendar next week?"
    ]

    var body: some View {
        NavigationStack {
            Group {
                if let error = store.loadError {
                    errorState(error)
                } else {
                    transcript
                }
            }
            .navigationTitle(districtTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(store)
            }
            .safeAreaInset(edge: .bottom) { composer }
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    // A closing is the one thing worth showing before the
                    // person asks anything.
                    ForEach(store.activeAlerts) { alert in
                        AlertBanner(alert: alert)
                    }
                    if turns.isEmpty { welcome }
                    ForEach(turns) { turn in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(turn.question)
                                .font(.callout.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .multilineTextAlignment(.trailing)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 14))
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            AnswerCard(answer: turn.answer)
                        }
                        .id(turn.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: turns.count) {
                if let last = turns.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// The short form, because "Edison Township Public Schools" does not fit
    /// across the top of a phone and is truncated to something worse.
    private var districtTitle: String {
        guard let name = store.pack?.district.name else { return "School Answers" }
        let short = AnswerEngine.shortDistrictName(name)
        return short.isEmpty ? "School Answers" : short
    }

    /// "Edison schools", or "your schools" when no district is loaded yet.
    private var schoolsLabel: String {
        guard let name = store.pack?.district.name else { return "your schools" }
        let short = AnswerEngine.shortDistrictName(name)
        return short.isEmpty ? "your schools" : "\(short) schools"
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ask about \(schoolsLabel)")
                .font(.title3.bold())
            Text("Hours, closings, early dismissals, breaks, absences, buses, meals and policies - answered from the district's own published information, on your phone, with no account.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let pack = store.pack {
                if defaultSchoolId.isEmpty {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Pick your school for more specific answers", systemImage: "building.2")
                            .font(.footnote.weight(.medium))
                    }
                    .padding(.top, 2)
                } else if let s = pack.schools.first(where: { $0.id == defaultSchoolId }) {
                    Label(s.name, systemImage: "building.2")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Try one of these")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            ForEach(suggestions, id: \.self) { s in
                Button { ask(s) } label: {
                    HStack {
                        Text(s).font(.subheadline)
                        Spacer()
                        Image(systemName: "arrow.up.left").font(.caption)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1), in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                TextField("Ask a question…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.12), in: .capsule)
                    .focused($fieldFocused)
                    .submitLabel(.send)
                    .onSubmit { ask(draft) }

                Button { ask(draft) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || store.engine == nil)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("The information pack didn't load")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("knowledge-pack.json and intents.json must be in the app target's Copy Bundle Resources.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
    }

    // MARK: - Actions

    private func ask(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let engine = store.engine else { return }
        let a = engine.answer(q, today: Date(), defaultSchoolId: defaultSchoolId)
        turns.append(Turn(question: q, answer: a))
        draft = ""
        fieldFocused = false
    }
}

// MARK: - Closing banner

struct AlertBanner: View {
    let alert: ClosingAlert

    private var tint: Color {
        switch alert.kind {
        case "closed":          return .red
        case "delayed_opening": return .orange
        default:                return .blue
        }
    }

    private var icon: String {
        switch alert.kind {
        case "closed":          return "xmark.circle.fill"
        case "delayed_opening": return "clock.badge.exclamationmark.fill"
        default:                return "bell.fill"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                Text("\(alert.headline) \(ClosingNotifier.friendlyDay(alert.date))")
                    .font(.headline)
                Spacer()
            }
            Text(alert.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let p = alert.postedDate {
                Text("District announcement, \(p.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.35), lineWidth: 1)
        )
    }
}

// MARK: - Answer card

struct AnswerCard: View {
    let answer: Answer
    @State private var showSources = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(answer.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            // Say so when the match was weak, instead of sounding certain.
            if answer.confidence < 0.5 {
                Label("I'm not confident about this one - please double-check.",
                      systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !answer.sources.isEmpty {
                Button { showSources.toggle() } label: {
                    Label(showSources ? "Hide sources" : "Where this came from",
                          systemImage: showSources ? "chevron.up" : "link")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if showSources {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(answer.sources, id: \.self) { s in
                            if let u = URL(string: s) {
                                Link(destination: u) {
                                    Text(s)
                                        .font(.caption2)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.09), in: .rect(cornerRadius: 14))
    }
}
