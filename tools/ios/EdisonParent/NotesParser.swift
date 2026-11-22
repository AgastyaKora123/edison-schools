//
//  NotesParser.swift
//  Schoolo
//
//  Turns pasted notes into cards, without asking anyone to learn a format.
//
//  The observation this rests on: most revision notes are already pairs.
//  "Mitochondria - the powerhouse of the cell". "Photosynthesis: how plants
//  make food". A term, a separator, a meaning. Nobody writes them intending
//  to make flashcards, but that is what they are.
//
//  So the app reads what people already write rather than asking them to
//  type it again in a special way. Lines it cannot read are reported, not
//  silently dropped - a parser that quietly ignores half your notes is worse
//  than one that refuses them, because you only find out when the test comes.
//

import Foundation

enum NotesParser {

    struct Result {
        var cards: [Card]
        /// Lines that had no readable pair. Returned so the screen can say
        /// how many, and show them, rather than pretending they weren't there.
        var skipped: [String]
    }

    /// Separators in order of confidence. A tab is almost always deliberate;
    /// a bare hyphen almost never is, which is why it must have spaces round
    /// it to count.
    private static let separators: [String] = ["\t", " — ", " – ", " - ", " = ", ": ", " : "]

    static func parse(_ text: String) -> Result {
        var cards: [Card] = []
        var skipped: [String] = []

        for raw in text.components(separatedBy: .newlines) {
            let line = stripLeading(raw.trimmingCharacters(in: .whitespaces))
            if line.isEmpty { continue }

            guard let (front, back) = split(line) else {
                skipped.append(line)
                continue
            }
            cards.append(Card(front: front, back: back))
        }
        return Result(cards: cards, skipped: skipped)
    }

    /// Removes list decoration people type without thinking: bullets, dashes
    /// at the start, "1.", "2)", "a.".
    ///
    /// Done before looking for a separator, because a line starting "- Osmosis
    /// - water moving" has a leading dash that is decoration and a middle one
    /// that is the separator, and taking the first would give an empty term.
    static func stripLeading(_ s: String) -> String {
        var out = s
        let bullets: Set<Character> = ["•", "·", "‣", "▪", "*", "–", "—", "-"]
        while let f = out.first, bullets.contains(f) {
            out = String(out.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // "1." / "12)" / "a." at the start
        if let r = out.range(of: "^([0-9]{1,3}|[a-zA-Z])[.)]\\s+", options: .regularExpression) {
            out = String(out[r.upperBound...])
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Splits at the first separator that leaves text on both sides.
    static func split(_ line: String) -> (String, String)? {
        for sep in separators {
            var search = line.startIndex..<line.endIndex
            while let r = line.range(of: sep, range: search) {
                let front = String(line[line.startIndex..<r.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let back = String(line[r.upperBound...])
                    .trimmingCharacters(in: .whitespaces)

                // A colon inside a time or a ratio is not a separator:
                // "the test is at 3:30" and "a 2:1 ratio" are sentences.
                if sep.hasPrefix(":") || sep.hasSuffix(": "),
                   let a = front.last, let b = back.first,
                   a.isNumber, b.isNumber {
                    search = r.upperBound..<line.endIndex
                    continue
                }

                if !front.isEmpty && !back.isEmpty && front.count <= 120 {
                    return (front, back)
                }
                search = r.upperBound..<line.endIndex
            }
        }
        return nil
    }
}
