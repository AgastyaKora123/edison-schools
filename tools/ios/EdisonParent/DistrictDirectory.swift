//
//  DistrictDirectory.swift
//  EdisonParent
//
//  The list of districts the app can read, shipped inside the app.
//
//  It has to ship rather than be fetched, and the reason is worth writing
//  down: the calendar service answers the app directly, but district home
//  pages do not, so there is no way to search for a district at the moment a
//  parent asks. The list is built on a desktop by sweeping the service once,
//  and the result travels with the app.
//

import Foundation

/// One district, as ingest/Build-DistrictList.ps1 writes it. The short keys
/// are not an affectation: at a few thousand rows the long ones cost more
/// than the names do.
struct DistrictRef: Codable, Identifiable, Hashable {
    let o: Int                 // organisation number
    let n: String              // name
    let s: String?             // two-letter state, where it could be worked out
    let u: String?             // website, where it could be worked out
    let k: Int?                // how many schools publish a calendar

    var id: Int { o }
    var name: String { n }
    var state: String { s ?? "" }
    var website: String { u ?? "" }
    var schoolCount: Int { k ?? 0 }

    /// "Edison Township Public Schools (NJ)" - the state matters, because six
    /// different districts are called Lincoln.
    var display: String {
        state.isEmpty ? name : "\(name) (\(state))"
    }

    var siteURL: String {
        guard !website.isEmpty else { return "" }
        return website.hasPrefix("http") ? website : "https://" + website
    }
}

enum DistrictDirectory {

    /// Loaded once and kept. Three thousand small rows is nothing to hold,
    /// and re-reading on every keystroke of a search is not free.
    static let all: [DistrictRef] = {
        guard let url = Bundle.main.url(forResource: "districts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([DistrictRef].self, from: data) else {
            return []
        }
        return list.sorted { $0.n.localizedCaseInsensitiveCompare($1.n) == .orderedAscending }
    }()

    /// Matches on every word typed, in any order and anywhere in the name, so
    /// "edison nj" and "nj edison" both find it and neither needs the full
    /// "Edison Township Public Schools".
    static func search(_ query: String, limit: Int = 50) -> [DistrictRef] {
        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }

        var out: [DistrictRef] = []
        for d in all {
            let hay = (d.n + " " + d.state).lowercased()
            if words.allSatisfy({ hay.contains($0) }) {
                out.append(d)
                if out.count >= limit { break }
            }
        }
        // A district that starts with what was typed is almost always the one
        // meant, so lift those above a mid-word match elsewhere.
        let first = words[0]
        return out.sorted { a, b in
            let aStarts = a.n.lowercased().hasPrefix(first)
            let bStarts = b.n.lowercased().hasPrefix(first)
            if aStarts != bStarts { return aStarts }
            return a.n.localizedCaseInsensitiveCompare(b.n) == .orderedAscending
        }
    }
}
