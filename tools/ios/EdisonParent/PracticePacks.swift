//
//  PracticePacks.swift
//  Schoolo
//
//  New in 1.3: practice sets that are already written.
//
//  Pasting your own notes - which is what 1.2 shipped - only helps somebody
//  who already keeps notes. Plenty of people open a revision app the night
//  before a test with nothing to paste, and an empty screen is where they
//  close it again.
//
//  The content is written for this app, so there is no licence on any of it
//  and nothing to attribute. It lives in one file, content/practice-packs.json,
//  which the build copies to both the iPhone app and the website. One source:
//  two hand-kept copies of the same 168 cards would drift, and the drift
//  would be found by somebody revising.
//
//  Adding a set COPIES it into that person's own deck. From then on it is
//  theirs - their boxes, their progress - and a later version of the app
//  shipping a corrected card does not reset anything they have learned.
//

import Foundation

struct PracticePack: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var subject: String
    var note: String
    var cards: [PackCard]

    struct PackCard: Codable, Hashable {
        var q: String
        var a: String
    }
}

enum PackLibrary {

    private struct File: Codable {
        var version: Int
        var note: String?
        var packs: [PracticePack]
    }

    /// Loaded once. The file ships inside the app, so there is no failure
    /// mode worth surfacing on screen: if it is missing the sets simply are
    /// not offered, and everything else still works.
    static let all: [PracticePack] = load()

    static func load(from bundle: Bundle = .main) -> [PracticePack] {
        guard let url = bundle.url(forResource: "practice-packs", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else {
            return []
        }
        return file.packs.filter { !$0.cards.isEmpty }
    }

    /// A copy, as somebody's own deck.
    static func deck(from pack: PracticePack) -> Deck {
        Deck(name: pack.name,
             cards: pack.cards.map { Card(front: $0.q, back: $0.a) },
             packId: pack.id)
    }
}
