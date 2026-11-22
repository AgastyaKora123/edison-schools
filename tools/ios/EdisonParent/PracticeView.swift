//
//  PracticeView.swift
//  Schoolo
//
//  The decks, making one, and studying it.
//
//  Three screens, deliberately plain. The work of learning is the recall,
//  not the interface, and anything that makes a card take longer to answer
//  is in the way.
//

import SwiftUI

// MARK: - The list of decks

struct PracticeView: View {

    @EnvironmentObject private var practice: PracticeStore
    @State private var showNew = false

    var body: some View {
        Group {
            if practice.decks.isEmpty {
                empty
            } else {
                list
            }
        }
        .navigationTitle("Practice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New deck")
            }
        }
        .sheet(isPresented: $showNew) { NewDeckView().environmentObject(practice) }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Nothing to practise yet", systemImage: "rectangle.stack")
        } description: {
            Text("Paste your notes and this turns them into questions. It reads the way people already write them - \"Mitochondria - the powerhouse of the cell\".")
        } actions: {
            Button("Add your notes") { showNew = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var list: some View {
        List {
            ForEach(practice.decks) { deck in
                NavigationLink {
                    StudyView(deckId: deck.id).environmentObject(practice)
                } label: {
                    row(deck)
                }
            }
            .onDelete { idx in
                for i in idx { practice.remove(practice.decks[i]) }
            }

            Section {
                Text("Decks are kept on this phone only. Nothing is uploaded, which also means losing the phone loses the decks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ deck: Deck) -> some View {
        let due = deck.due(on: Date()).count
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(deck.name).font(.system(.headline, design: .serif))
                Spacer()
                if due > 0 {
                    Text("\(due)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor))
                        .foregroundStyle(.white)
                }
            }
            Text("\(deck.cards.count) cards · \(deck.learned) learned")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Making one

struct NewDeckView: View {

    @EnvironmentObject private var practice: PracticeStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var notes = ""

    private var parsed: NotesParser.Result { NotesParser.parse(notes) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Biology - cells", text: $name)
                }

                Section {
                    TextEditor(text: $notes)
                        .frame(minHeight: 180)
                        .font(.body)
                } header: {
                    Text("Your notes")
                } footer: {
                    Text("One per line, a term then its meaning. A dash, a colon or an equals sign between them all work.")
                }

                if !notes.isEmpty {
                    Section("Found \(parsed.cards.count) questions") {
                        ForEach(parsed.cards.prefix(6)) { c in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.front).font(.subheadline.weight(.semibold))
                                Text(c.back).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if parsed.cards.count > 6 {
                            Text("and \(parsed.cards.count - 6) more")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    // Said out loud rather than silently dropped: finding out
                    // at the test that half the notes never made it is the
                    // worst possible moment.
                    if !parsed.skipped.isEmpty {
                        Section("Couldn't read \(parsed.skipped.count)") {
                            ForEach(Array(parsed.skipped.prefix(4).enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Text("These had no term and meaning in them - headings and notes-to-self usually. Add a dash or a colon if one should be a question.")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .navigationTitle("New deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let title = name.trimmingCharacters(in: .whitespaces)
                        practice.add(Deck(name: title.isEmpty ? "Untitled" : title,
                                          cards: parsed.cards))
                        dismiss()
                    }
                    .disabled(parsed.cards.isEmpty)
                }
            }
        }
    }
}

// MARK: - Studying

struct StudyView: View {

    @EnvironmentObject private var practice: PracticeStore
    let deckId: UUID

    @State private var queue: [Card] = []
    @State private var showingBack = false
    @State private var done = 0

    private var deck: Deck? { practice.deck(deckId) }

    var body: some View {
        Group {
            if let card = queue.first {
                studying(card)
            } else {
                finished
            }
        }
        .navigationTitle(deck?.name ?? "Practice")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if queue.isEmpty && done == 0 { queue = deck?.due(on: Date()) ?? [] } }
    }

    private func studying(_ card: Card) -> some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 18) {
                Text(card.front)
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if showingBack {
                    Divider()
                    Text(card.back)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(26)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )

            Spacer()

            if showingBack {
                // Two answers only. "Sort of" is the option everybody picks,
                // and it tells the scheduler nothing.
                HStack(spacing: 12) {
                    Button { answer(correct: false) } label: {
                        Label("Not yet", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button { answer(correct: true) } label: {
                        Label("Got it", systemImage: "checkmark")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            } else {
                Button { showingBack = true } label: {
                    Text("Show answer").frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
            }

            Text("\(queue.count) left")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(20)
    }

    private var finished: some View {
        ContentUnavailableView {
            Label(done > 0 ? "Done for now" : "Nothing due", systemImage: "checkmark.circle")
        } description: {
            Text(done > 0
                 ? "\(done) answered. The ones you got wrong come back today; the rest come back later."
                 : "Everything in this deck has been answered recently. Come back tomorrow.")
        }
    }

    private func answer(correct: Bool) {
        guard var card = queue.first, let deck else { return }
        if correct { card.markCorrect(on: Date()) } else { card.markWrong(on: Date()) }
        practice.update(card, in: deck)

        queue.removeFirst()
        // A card got wrong is not finished with: back to the end of today's
        // queue, so the session ends when you actually know them.
        if !correct { queue.append(card) }
        done += 1
        showingBack = false
    }
}
