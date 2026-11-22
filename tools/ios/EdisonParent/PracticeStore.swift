//
//  PracticeStore.swift
//  Schoolo
//
//  Where the decks live.
//
//  On the phone, in a plain JSON file, and nowhere else. No account, no
//  sync, no server - the same promise the rest of the app makes. Somebody's
//  revision notes are their business, and an app that quietly uploaded a
//  student's biology notes to make a feature work would deserve everything
//  it got.
//
//  The cost of that is honest: lose the phone, lose the decks. Said plainly
//  on screen rather than discovered.
//

import Foundation

@MainActor
final class PracticeStore: ObservableObject {

    @Published private(set) var decks: [Deck] = []
    @Published private(set) var loadError: String?

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("practice-decks.json")
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }   // none yet is normal
        do {
            decks = try JSONDecoder().decode([Deck].self, from: data)
        } catch {
            // Keep the file. A decoding bug on our side must not be the
            // reason somebody's notes disappear.
            loadError = "Couldn't read your saved decks: \(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(decks)
            try data.write(to: fileURL, options: .atomic)
            loadError = nil
        } catch {
            loadError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    func add(_ deck: Deck) {
        decks.append(deck)
        save()
    }

    func remove(_ deck: Deck) {
        decks.removeAll { $0.id == deck.id }
        save()
    }

    func rename(_ deck: Deck, to name: String) {
        guard let i = decks.firstIndex(where: { $0.id == deck.id }) else { return }
        decks[i].name = name
        save()
    }

    /// Writes back one card after it has been answered.
    func update(_ card: Card, in deck: Deck) {
        guard let d = decks.firstIndex(where: { $0.id == deck.id }),
              let c = decks[d].cards.firstIndex(where: { $0.id == card.id }) else { return }
        decks[d].cards[c] = card
        save()
    }

    func deck(_ id: UUID) -> Deck? { decks.first { $0.id == id } }

    /// How many cards are waiting across everything, for the home screen.
    func dueCount(on day: Date = Date()) -> Int {
        decks.reduce(0) { $0 + $1.due(on: day).count }
    }
}
