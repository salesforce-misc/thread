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

import SwiftUI
import Foundation

/// One search hit, shown as a filtered row in the sidebar.
///
/// Equality is fully synthesized (it includes the snippet) so that when the
/// query changes but the same note keeps matching, `ForEach` still sees the row
/// as changed and re-renders the updated snippet. Comparing only `url` here
/// froze snippets at whatever term first matched a note.
struct SearchResult: Identifiable, Hashable {
    let url: URL
    let title: String
    let folderName: String
    let date: Date
    let snippet: AttributedString?

    var id: URL { url }
}

/// Drives search across every saved note. Holds a lightweight in-memory index
/// (title + Notes + Transcript per file) rebuilt off the main thread whenever
/// the library changes, and filters it live as the user types.
@MainActor
final class SearchController: ObservableObject {

    /// The search pill is open (expanded into a text field).
    @Published var isActive = false
    /// Bumped to ask whichever pill is visible to grab keyboard focus.
    @Published private(set) var focusToken = 0
    @Published private(set) var results: [SearchResult] = []

    @Published var query = "" {
        didSet { recompute() }
    }

    /// Flat, filterable representation of one note.
    private struct Entry: Sendable {
        let url: URL
        let title: String
        let folderName: String
        let date: Date
        let content: String   // Notes + Transcript, speaker/markdown chrome stripped
    }

    private var index: [Entry] = []
    private var rebuildTask: Task<Void, Never>?

    // MARK: Open / close

    func activate() {
        isActive = true
        focusToken += 1
    }

    func toggle() { isActive ? deactivate() : activate() }

    func deactivate() {
        isActive = false
        query = ""
        results = []
    }

    // MARK: Indexing

    /// Reads every note off the main thread and rebuilds the index. Cheap enough
    /// at hobby scale, and the folder watcher keeps it fresh while search is open.
    func rebuild(from files: [(url: URL, folder: String, date: Date)]) {
        rebuildTask?.cancel()
        rebuildTask = Task.detached(priority: .utility) { [weak self] in
            var entries: [Entry] = []
            for file in files {
                if Task.isCancelled { return }
                guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
                entries.append(Entry(url: file.url,
                                     title: file.url.deletingPathExtension().lastPathComponent,
                                     folderName: file.folder,
                                     date: file.date,
                                     content: Self.cleanText(from: text)))
            }
            if Task.isCancelled { return }
            await MainActor.run { [weak self, entries] in
                self?.index = entries
                self?.recompute()
            }
        }
    }

    /// Human-readable body for matching + snippets: the Notes section plus the
    /// transcript text, with speaker/time headers and markdown emphasis removed.
    nonisolated private static func cleanText(from markdown: String) -> String {
        let parts = SessionStore.components(of: markdown)
        var pieces: [String] = []
        if !parts.notes.isEmpty { pieces.append(parts.notes) }
        if !parts.tasks.isEmpty { pieces.append(parts.tasks) }

        let transcript = parts.transcript
            .components(separatedBy: "\n")
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { return false }
                if t.hasPrefix("**You**") || t.hasPrefix("**Meeting**") { return false }
                if t.hasPrefix("<!--") { return false } // segment markers
                if t.hasPrefix("#") { return false }
                if t.hasPrefix("_") && t.hasSuffix("_") { return false }
                return true
            }
            .joined(separator: " ")
        if !transcript.isEmpty { pieces.append(transcript) }

        var out = pieces.joined(separator: " ")
        for marker in ["**", "~~", "`", "•"] {
            out = out.replacingOccurrences(of: marker, with: "")
        }
        out = out.replacingOccurrences(of: "\t", with: " ")
        return out
    }

    // MARK: Query

    private static let matchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private func recompute() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { results = []; return }
        let tokens = trimmed.split(separator: " ").map(String.init)

        var scored: [(SearchResult, Int)] = []
        for entry in index {
            var titleHits = 0
            var matchedAll = true
            for token in tokens {
                let inTitle = entry.title.range(of: token, options: Self.matchOptions) != nil
                let inContent = entry.content.range(of: token, options: Self.matchOptions) != nil
                if !inTitle && !inContent { matchedAll = false; break }
                if inTitle { titleHits += 1 }
            }
            guard matchedAll else { continue }
            let result = SearchResult(url: entry.url,
                                      title: entry.title,
                                      folderName: entry.folderName,
                                      date: entry.date,
                                      snippet: Self.snippet(for: entry, tokens: tokens))
            scored.append((result, titleHits))
        }
        // Title matches first (Apple Notes' "Top Hits" feel), then most recent.
        results = scored.sorted { a, b in
            a.1 != b.1 ? a.1 > b.1 : a.0.date > b.0.date
        }.map(\.0)
    }

    /// A one-line snippet around the first content match, with the query terms
    /// highlighted. Returns nil when the match is title-only / has no body.
    private static func snippet(for entry: Entry, tokens: [String]) -> AttributedString? {
        let content = entry.content
        guard !content.isEmpty else { return nil }

        var earliest: String.Index?
        for token in tokens {
            if let r = content.range(of: token, options: matchOptions) {
                if earliest == nil || r.lowerBound < earliest! { earliest = r.lowerBound }
            }
        }
        guard let matchStart = earliest else { return nil }

        let start = content.index(matchStart, offsetBy: -32, limitedBy: content.startIndex) ?? content.startIndex
        let end = content.index(start, offsetBy: 120, limitedBy: content.endIndex) ?? content.endIndex
        var slice = String(content[start..<end])
        slice = slice.replacingOccurrences(of: "\n", with: " ")
        while slice.contains("  ") { slice = slice.replacingOccurrences(of: "  ", with: " ") }
        slice = slice.trimmingCharacters(in: .whitespaces)
        var attributed = AttributedString(slice)
        for token in tokens {
            var searchStart = attributed.startIndex
            while searchStart < attributed.endIndex,
                  let r = attributed[searchStart...].range(of: token, options: matchOptions) {
                attributed[r].foregroundColor = .orange
                attributed[r].inlinePresentationIntent = .stronglyEmphasized
                searchStart = r.upperBound
            }
        }
        return attributed
    }
}

// MARK: - Search pill

/// The glass magnifying-glass that grows into a text field. Placed in the
/// expanded toolbar (grows right) and in the compact sidebar (grows left,
/// depending on its container's alignment).
struct SearchPill: View {
    @ObservedObject var controller: SearchController
    var expandedWidth: CGFloat = 240
    /// When true the field always fills its container's width (used for the
    /// compact sidebar bar); otherwise it animates between an icon and a fixed
    /// width (used in the toolbar).
    var fillWidth: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button { controller.toggle() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(controller.isActive ? Color.secondary : Color.accentColor)
            }
            .buttonStyle(.plain)
            if controller.isActive {
                TextField("Search", text: $controller.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onExitCommand { controller.deactivate() }
                // Always offer a close/clear affordance while open: clears the
                // text if there's any, otherwise dismisses search entirely.
                Button {
                    if controller.query.isEmpty {
                        controller.deactivate()
                    } else {
                        controller.query = ""
                        focused = true
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, controller.isActive ? 10 : 0)
        .frame(width: fillWidth ? nil : (controller.isActive ? expandedWidth : 26),
               height: fillWidth ? 32 : 26)
        .frame(maxWidth: fillWidth ? .infinity : nil)
        .glassEffect(AppAppearance.glass(interactive: true), in: .capsule)
        .contentShape(.capsule)
        // Tapping the collapsed glass opens it; the glass Button handles closing.
        .onTapGesture { if !controller.isActive { controller.activate() } }
        .onChange(of: controller.isActive) { _, active in focused = active }
        .onChange(of: controller.focusToken) { _, _ in if controller.isActive { focused = true } }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: controller.isActive)
        .help("Search notes")
    }
}

/// A filtered result row: title, highlighted snippet, and folder · date.
struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(result.title)
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let snippet = result.snippet {
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .imageScale(.small)
                Text(result.folderName)
                Text("·")
                Text(result.date.formatted(date: .abbreviated, time: .omitted))
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
