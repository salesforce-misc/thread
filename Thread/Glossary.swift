/*
 * Copyright (c) 2026, Salesforce, Inc.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import Foundation
import Combine

// MARK: - Model

/// One learned vocabulary entry: a canonical spelling plus the mis-heard
/// variants that transcripts should be corrected to.
struct GlossaryTerm: Codable, Identifiable, Hashable {
    var id = UUID()
    var canonical: String
    var variants: [String]
}

/// A proposed correction surfaced after an enhance: the transcript said
/// `variant`, but the user's own notes spell it `canonical`.
struct GlossaryCandidate: Identifiable, Hashable {
    let id = UUID()
    let canonical: String
    let variant: String
    let count: Int
    let contexts: [String]
}

// MARK: - Store

/// Owns the user's learned vocabulary and does the detection + correction work.
/// Persisted globally (per user) as JSON in Application Support so terms carry
/// across every library folder.
@MainActor
final class Glossary: ObservableObject {
    @Published private(set) var terms: [GlossaryTerm] = []

    private let fileURL: URL
    private let dismissalsURL: URL
    private var dismissals: [String: Set<String>] = [:]

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent(AppEnvironment.applicationSupportDirectoryName,
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("glossary.json")
        dismissalsURL = base.appendingPathComponent("glossary-dismissals.json")
        load()
        loadDismissals()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([GlossaryTerm].self, from: data)
        else { return }
        terms = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(terms) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func loadDismissals() {
        guard let data = try? Data(contentsOf: dismissalsURL),
              let decoded = try? JSONDecoder().decode([String: Set<String>].self, from: data)
        else { return }
        dismissals = decoded
    }

    private func persistDismissals() {
        guard let data = try? JSONEncoder().encode(dismissals) else { return }
        try? data.write(to: dismissalsURL, options: .atomic)
    }

    // MARK: Mutations

    /// Accepts a suggested correction: adds the variant to the matching canonical
    /// term (creating it if needed) so future transcripts self-correct.
    func accept(_ candidate: GlossaryCandidate) {
        let canon = candidate.canonical
        let variant = candidate.variant
        if let i = terms.firstIndex(where: { $0.canonical.caseInsensitiveEquals(canon) }) {
            if !terms[i].variants.contains(where: { $0.caseInsensitiveEquals(variant) }) {
                terms[i].variants.append(variant)
            }
        } else {
            terms.append(GlossaryTerm(canonical: canon, variants: [variant]))
        }
        persist()
    }

    func remove(_ term: GlossaryTerm) {
        terms.removeAll { $0.id == term.id }
        persist()
    }

    /// Suppresses one proposed correction for this specific saved note.
    func dismiss(_ candidate: GlossaryCandidate, for noteURL: URL) {
        let note = noteURL.standardizedFileURL.path
        dismissals[note, default: []].insert(Self.dismissalKey(candidate))
        persistDismissals()
    }

    func noteMoved(from oldURL: URL, to newURL: URL) {
        let oldKey = oldURL.standardizedFileURL.path
        guard let values = dismissals.removeValue(forKey: oldKey) else { return }
        let newKey = newURL.standardizedFileURL.path
        dismissals[newKey, default: []].formUnion(values)
        persistDismissals()
    }

    func noteDeleted(_ url: URL) {
        let key = url.standardizedFileURL.path
        guard dismissals.removeValue(forKey: key) != nil else { return }
        persistDismissals()
    }

    // MARK: Correction

    /// Applies every saved term's variants to `text`, rewriting mis-heard
    /// spellings to their canonical form (whole-word, case-insensitive).
    func correct(_ text: String) -> String {
        var out = text
        for term in terms {
            for variant in term.variants {
                out = Glossary.replaceWholeWord(variant, with: term.canonical, in: out)
            }
        }
        return out
    }

    /// Detects *new* candidate corrections by comparing the user's notes
    /// (canonical spellings) against the transcript (mis-hearings), skipping any
    /// already covered by the saved glossary.
    func detectCandidates(notes: String, transcript: String, noteURL: URL? = nil) -> [GlossaryCandidate] {
        let known = Set(terms.flatMap { term in
            ([term.canonical] + term.variants).map { $0.lowercased() }
        })
        let dismissed = noteURL.map {
            dismissals[$0.standardizedFileURL.path] ?? []
        } ?? []
        return Glossary.detect(notes: notes, transcript: transcript)
            .filter { !known.contains($0.variant.lowercased()) }
            .filter { !dismissed.contains(Self.dismissalKey($0)) }
    }

    private nonisolated static func dismissalKey(_ candidate: GlossaryCandidate) -> String {
        candidate.variant.lowercased() + "→" + candidate.canonical.lowercased()
    }
}

// MARK: - Detection (pure, testable)

extension Glossary {

    /// Finds corrections implied by the notes: proper nouns the user typed that
    /// appear mis-spelled (but phonetically alike) in the transcript.
    nonisolated static func detect(notes: String, transcript: String) -> [GlossaryCandidate] {
        let canonicals = properNouns(in: notes)
        guard !canonicals.isEmpty else { return [] }

        let words = Phonetics.words(in: transcript)          // surface tokens
        let lowerWords = words.map { $0.lowercased() }
        var found: [String: (canonical: String, count: Int)] = [:]   // keyed by variant.lowercased

        for canonical in canonicals {
            let parts = Phonetics.significantWords(in: canonical)

            if parts.count == 1 {
                // Single token: any transcript word that sounds alike but differs.
                // Require both sides be real name-ish words to cut false hits.
                let target = parts[0]
                guard target.count >= 4 else { continue }
                for (i, w) in words.enumerated() where lowerWords[i] != target.lowercased() {
                    guard w.count >= 4, Phonetics.isNameLike(w), !Phonetics.isCommonWord(w),
                          Phonetics.matches(w, target) else { continue }
                    accumulate(&found, variant: w, canonical: canonical)
                }
            } else if parts.count == 2 {
                // Connected name (e.g. "Fisher & Paykel"): look for
                // "<w1> [and|&] <w2>" spans where each word sounds alike.
                var i = 0
                while i < words.count {
                    if let end = matchConnectedPair(words, at: i, first: parts[0], second: parts[1]) {
                        let variantSurface = words[i...end].joined(separator: " ")
                        if !variantSurface.caseInsensitiveEquals(canonical) {
                            accumulate(&found, variant: variantSurface, canonical: canonical)
                        }
                        i = end + 1
                    } else {
                        i += 1
                    }
                }
            }
        }

        return found
            .map {
                let variant = $0.key.restoreCase(from: transcript)
                return GlossaryCandidate(
                    canonical: $0.value.canonical,
                    variant: variant,
                    count: $0.value.count,
                    contexts: contextSentences(containing: variant, in: transcript)
                )
            }
            .sorted { $0.count > $1.count }
    }

    /// Returns distinct source sentences for an expandable suggestion preview.
    private nonisolated static func contextSentences(containing variant: String,
                                                     in transcript: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        guard let regex = try? NSRegularExpression(
            pattern: matchingPattern(for: variant),
            options: [.caseInsensitive]
        ) else { return [] }
        for rawLine in transcript.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            line.enumerateSubstrings(
                in: line.startIndex..<line.endIndex,
                options: [.bySentences, .substringNotRequired]
            ) { _, range, _, _ in
                let sentence = String(line[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                let nsRange = NSRange(location: 0, length: (sentence as NSString).length)
                guard regex.firstMatch(in: sentence, range: nsRange) != nil else { return }
                let key = sentence.lowercased()
                if seen.insert(key).inserted { result.append(sentence) }
            }
        }
        return Array(result.prefix(8))
    }

    /// Matches a heard phrase while tolerating punctuation, connectors, and
    /// whitespace between its significant words.
    nonisolated static func matchingPattern(for phrase: String) -> String {
        let regex = try? NSRegularExpression(pattern: "[A-Za-z0-9]+")
        let ns = phrase as NSString
        let words = (regex?.matches(
            in: phrase,
            range: NSRange(location: 0, length: ns.length)
        ).map { ns.substring(with: $0.range) } ?? [])
            .filter { $0.caseInsensitiveCompare("and") != .orderedSame }
        let body = words.isEmpty
            ? NSRegularExpression.escapedPattern(for: phrase)
            : words
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "\\W+(?:and\\W+)?")
        return "(?<![A-Za-z0-9])\(body)(?![A-Za-z0-9])"
    }

    private nonisolated static func accumulate(_ dict: inout [String: (canonical: String, count: Int)],
                                               variant: String, canonical: String) {
        let key = variant.lowercased()
        if let existing = dict[key] {
            dict[key] = (existing.canonical, existing.count + 1)
        } else {
            dict[key] = (canonical, 1)
        }
    }

    /// If `words[i...]` starts a "<a> (and|&) <b>" pattern whose flanking words
    /// phonetically match `first`/`second`, returns the end index.
    private nonisolated static func matchConnectedPair(_ words: [String], at i: Int,
                                                       first: String, second: String) -> Int? {
        // Each flanking word may be exact OR a mis-hearing; the caller rejects
        // spans that match the canonical exactly, so at least one must differ.
        if i + 2 < words.count {
            let connector = words[i + 1].lowercased()
            if (connector == "and" || connector == "&"),
               Phonetics.similar(words[i], first), Phonetics.similar(words[i + 2], second) {
                return i + 2
            }
        }
        if i + 1 < words.count,
           Phonetics.similar(words[i], first), Phonetics.similar(words[i + 1], second) {
            return i + 1
        }
        return nil
    }

    /// Extracts proper-noun-like phrases from the notes: runs of capitalized
    /// words (space/`&`/`and`-joined), then split on the list conjunction "and"
    /// (so "Shark Ninja and Fisher & Paykel" → "Shark Ninja", "Fisher & Paykel")
    /// while keeping `&` names intact.
    nonisolated static func properNouns(in text: String) -> [String] {
        let pattern = "[A-Z][a-zA-Z]+(?:\\s+(?:&\\s+|and\\s+)?[A-Z][a-zA-Z]+)*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var results: [String] = []
        var seen = Set<String>()
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let run = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces)
            for phrase in splitConjunctions(run) {
                let sig = Phonetics.significantWords(in: phrase)
                // Keep two-word names, or single tokens that read like a real
                // proper noun (long enough, not a common word). >2 words are
                // ambiguous, so skip for now.
                let keep: Bool
                switch sig.count {
                case 2: keep = true
                case 1: keep = Phonetics.isNameLike(sig[0]) && !Phonetics.isCommonWord(sig[0])
                default: keep = false
                }
                if keep, !seen.contains(phrase.lowercased()) {
                    seen.insert(phrase.lowercased())
                    results.append(phrase)
                }
            }
        }
        return results
    }

    /// Splits a capitalized run on the list conjunction " and " (keeping "&"
    /// names like "Fisher & Paykel" whole).
    private nonisolated static func splitConjunctions(_ phrase: String) -> [String] {
        phrase
            .replacingOccurrences(of: " And ", with: " and ")
            .components(separatedBy: " and ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Replaces whole-word (case-insensitive) occurrences of `variant` with
    /// `replacement`, preserving surrounding text.
    nonisolated static func replaceWholeWord(_ variant: String, with replacement: String,
                                             in text: String) -> String {
        let pattern = matchingPattern(for: variant)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range,
                                              withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}

// MARK: - Phonetics (pure, testable)

enum Phonetics {

    /// A rough consonant-skeleton key: first letter, then de-voweled and
    /// class-merged consonants. Good enough to cluster mis-heard proper nouns
    /// ("Texina"/"Taksina", "Piko"/"Paykel").
    static func key(_ raw: String) -> String {
        var t = raw.lowercased()
        t = t.replacingOccurrences(of: "x", with: "ks")
        t = t.replacingOccurrences(of: "ph", with: "f")
        t = t.replacingOccurrences(of: "ck", with: "k")
        t = t.replacingOccurrences(of: "sch", with: "sk")
        let chars = Array(t).filter { $0.isLetter && $0.isASCII }
        guard let first = chars.first else { return "" }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        func classMap(_ c: Character) -> Character {
            switch c {
            case "c", "q", "k": return "k"
            case "z", "s": return "s"
            case "v", "f": return "f"
            case "j", "g": return "j"
            default: return c
            }
        }
        var out: [Character] = [classMap(first)]
        for c in chars.dropFirst() {
            if vowels.contains(c) { continue }
            let m = classMap(c)
            if m != out.last { out.append(m) }
        }
        return String(out)
    }

    /// Exact (case-insensitive) or phonetically close — used when matching a
    /// multi-word name where some words are correct and some mis-heard.
    static func similar(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame || matches(a, b)
    }

    /// Two words are phonetically close if their consonant skeletons are equal
    /// (or one is a near-complete prefix of the other, for cut-off endings like
    /// "Piko"/"Paykel"). Deliberately strict — a mis-heard proper noun keeps most
    /// of its sound and length, so we gate on length and require a real skeleton
    /// match rather than a loose edit distance (which let "text"→"Taksina" slip).
    static func matches(_ a: String, _ b: String) -> Bool {
        if a.caseInsensitiveEquals(b) { return false }   // same spelling → nothing to correct
        // Same word mis-heard rarely changes length by more than a couple chars.
        if abs(a.count - b.count) > 2 { return false }
        let ka = key(a), kb = key(b)
        guard ka.count >= 2, kb.count >= 2 else { return false }
        if ka == kb { return true }
        // Prefix only: covers dropped endings ("pk" vs "pkl"), not loose edits.
        let (short, long) = ka.count <= kb.count ? (ka, kb) : (kb, ka)
        return long.hasPrefix(short) && long.count - short.count <= 1
    }

    /// Surface word tokens (letters, digits, `&`) in document order.
    static func words(in text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "&") }.map(String.init)
    }

    /// Words in a phrase minus the connectors ("and"/"&").
    static func significantWords(in phrase: String) -> [String] {
        words(in: phrase).filter { $0 != "&" && $0.lowercased() != "and" }
    }

    /// Looks like a name/proper noun worth correcting: alphabetic and long enough.
    static func isNameLike(_ w: String) -> Bool {
        w.count >= 3 && w.allSatisfy { $0.isLetter }
    }

    static func isCommonWord(_ w: String) -> Bool {
        Self.common.contains(w.lowercased())
    }

    private static let common: Set<String> = [
        "the", "and", "for", "with", "that", "this", "they", "them", "then",
        "there", "here", "what", "when", "where", "which", "who", "will",
        "would", "could", "should", "have", "has", "had", "was", "were",
        "meeting", "team", "notes", "note", "action", "items", "overview",
        "key", "points", "decisions", "questions", "summary", "monday",
        "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
        // Informal / filler words that often start a sentence (capitalized) and
        // shouldn't be mistaken for names.
        "gotta", "gonna", "wanna", "kinda", "gotcha", "yeah", "okay", "alright",
        "maybe", "actually", "really", "basically", "also", "well", "sure",
        "let", "lets", "just", "still", "some", "something", "someone", "make",
        "present", "create", "discuss", "ensure", "inform", "prepare", "provide",
        "coordinate", "emphasize", "review", "outline", "consider", "follow"
    ]

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}

// MARK: - Small helpers

private extension String {
    func caseInsensitiveEquals(_ other: String) -> Bool {
        caseInsensitiveCompare(other) == .orderedSame
    }

    /// Returns the first surface-cased occurrence of the receiver (a lowercased
    /// key) as it appears in `source`, falling back to the key itself.
    func restoreCase(from source: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: Glossary.matchingPattern(for: self),
            options: [.caseInsensitive]
        ) else {
            return self
        }
        let ns = source as NSString
        if let m = regex.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) {
            return ns.substring(with: m.range)
        }
        return self
    }
}
