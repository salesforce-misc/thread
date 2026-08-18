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
import AppKit
import Combine

extension Notification.Name {
    /// Posted (object = file URL) when a session's tasks are changed outside the
    /// open editor — e.g. by the AI — so the view can reload its Tasks strip.
    static let threadTasksDidChange = Notification.Name("threadTasksDidChange")
    /// Posted (object = CorrectionRequest) when the user accepts a glossary
    /// suggestion, so the open note applies the fix in place.
    static let threadApplyCorrection = Notification.Name("threadApplyCorrection")
}

/// A glossary correction to apply in place to a specific note file.
struct CorrectionRequest {
    let url: URL
    let variant: String
    let canonical: String
}

/// A single saved session, backed by a `.md` file on disk.
struct SessionFile: Identifiable, Hashable {
    let url: URL
    let modified: Date

    var id: URL { url }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

/// A library folder and the sessions inside it. Each added folder is its own
/// group in the sidebar.
struct SessionGroup: Identifiable {
    let folderURL: URL
    var files: [SessionFile]

    var id: URL { folderURL }
    var name: String { folderURL.lastPathComponent }
}

/// One parsed line of a saved transcript.
struct ParsedLine: Identifiable {
    let id = UUID()
    let speaker: Speaker
    let text: String
    /// The resolved on-screen speaker name, recovered from the inline "Name: …"
    /// prefix written at serialization. Shown as the styled caption above the
    /// bubble (so the name isn't left baked into the bubble text on reload).
    var speakerName: String? = nil
}

/// A contiguous run of transcript captured in one Start→Stop. A session can hold
/// several (each new recording appended to a previous session adds one). `start`
/// / `end` come from the segment marker; legacy transcripts (no marker) parse as
/// a single segment with nil times.
struct TranscriptSegment: Identifiable {
    let id = UUID()
    let start: Date?
    let end: Date?
    /// A cached one-time AI mini-summary of this segment, stored as hidden
    /// metadata in the file. Filled in once a newer segment exists, so enhance
    /// can reuse it instead of re-reading the whole segment every time.
    var summary: String?
    var lines: [ParsedLine]
}

/// A single actionable task, persisted as a Markdown task-list item
/// (`- [ ]` / `- [x]`) in the session file's `## Tasks` section.
struct TaskItem: Identifiable, Hashable {
    var id = UUID()
    var text: String
    var done: Bool
}

/// Owns the user-chosen library folders and reads/writes each session as a
/// Markdown file. Files are the source of truth; the sidebar mirrors the folders.
@MainActor
final class SessionStore: ObservableObject {

    @Published private(set) var folders: [URL] = []
    @Published private(set) var groups: [SessionGroup] = []

    var needsFolder: Bool { folders.isEmpty }

    private let bookmarksKey = "libraryFolderBookmarks"
    private var watchers: [DispatchSourceFileSystemObject] = []
    /// The file the in-progress session is being autosaved into, reused by the
    /// final save so autosave doesn't leave a duplicate. Published because it's
    /// also the live note's identity: the ask field keys its conversation to it,
    /// and since `finishLive` writes into the same file the thread survives Stop.
    @Published private(set) var liveURL: URL?

    init() {
        restoreBookmarks()
    }

    // MARK: - Folder management

    /// Presents a picker to add one or more library folders.
    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"
        panel.message = "Choose one or more folders for Thread to store sessions."

        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !folders.contains(url) {
            _ = url.startAccessingSecurityScopedResource()
            folders.append(url)
        }
        persistBookmarks()
        rewatch()
        refresh()
    }

    func removeFolder(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
        folders.removeAll { $0 == url }
        persistBookmarks()
        rewatch()
        refresh()
    }

    /// Reorders `source` to sit where `target` currently is. Used by drag-to-
    /// reorder of the library folders in the sidebar.
    func reorderFolder(_ source: URL, before target: URL) {
        guard source != target,
              let from = folders.firstIndex(of: source) else { return }
        var next = folders
        let moved = next.remove(at: from)
        guard let to = next.firstIndex(of: target) else { return }
        next.insert(moved, at: to)
        guard next != folders else { return }
        folders = next
        persistBookmarks()
        rewatch()
        refresh()
    }

    /// Reorders library folders by offset (drives `List`'s native `.onMove`
    /// drag-to-reorder). `groups` is built in `folders` order, so the ForEach
    /// indices map directly onto `folders`.
    func moveFolders(from source: IndexSet, to destination: Int) {
        var next = folders
        next.move(fromOffsets: source, toOffset: destination)
        guard next != folders else { return }
        folders = next
        persistBookmarks()
        rewatch()
        refresh()
    }

    /// The folder new sessions save into. If the user hasn't added one, fall
    /// back to a "Thread" folder on the Desktop (created on demand) so recording
    /// never requires setup first.
    @discardableResult
    private func ensureSaveFolder() -> URL? {
        if let first = folders.first { return first }
        guard let desktop = FileManager.default.urls(for: .desktopDirectory,
                                                     in: .userDomainMask).first else { return nil }
        let dir = desktop.appendingPathComponent("Thread", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !folders.contains(dir) {
            folders.append(dir)
            persistBookmarks()
            rewatch()
        }
        return dir
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Security-scoped bookmarks

    private func restoreBookmarks() {
        guard let dataList = UserDefaults.standard.array(forKey: bookmarksKey) as? [Data] else { return }
        for data in dataList {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data,
                                     options: [.withSecurityScope],
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &stale) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            folders.append(url)
        }
        if !folders.isEmpty {
            persistBookmarks() // refresh any stale bookmarks
            rewatch()
            refresh()
        }
    }

    private func persistBookmarks() {
        let dataList = folders.compactMap {
            try? $0.bookmarkData(options: [.withSecurityScope],
                                 includingResourceValuesForKeys: nil,
                                 relativeTo: nil)
        }
        UserDefaults.standard.set(dataList, forKey: bookmarksKey)
    }

    // MARK: - Scanning

    func refresh() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]

        groups = folders.map { folder in
            let contents = (try? fm.contentsOfDirectory(at: folder,
                                                        includingPropertiesForKeys: keys,
                                                        options: [.skipsHiddenFiles])) ?? []
            let files = contents
                .filter { $0.pathExtension.lowercased() == "md" }
                .map { url -> SessionFile in
                    let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return SessionFile(url: url, modified: mod)
                }
                .sorted { $0.modified > $1.modified }
            return SessionGroup(folderURL: folder, files: files)
        }
    }

    // MARK: - Write / rename / delete

    /// Autosaves the in-progress session into a stable file, creating it the
    /// first time. Called periodically while recording and on the first keystroke
    /// of a notes-only session. Returns the (stable) file URL, or nil if there's
    /// nothing to save yet or no save folder.
    @discardableResult
    func autosaveLive(title: String, entries: [TranscriptEntry], notes: String,
                      start: Date? = nil, end: Date? = nil) -> URL? {
        // Save once there's *any* content — a transcript or typed notes.
        let hasNotes = !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !entries.isEmpty || hasNotes, let folder = ensureSaveFolder() else { return nil }
        if liveURL == nil {
            liveURL = uniqueURL(
                base: sanitize(title.isEmpty ? defaultTitle(for: start ?? Date()) : title),
                in: folder
            )
        }
        guard let url = liveURL else { return nil }
        writeMarkdown(to: url, entries: entries, notes: notes, start: start, end: end)
        return url
    }

    /// Final save when a session ends: writes into the autosave file (or a fresh
    /// one if nothing was autosaved) and clears the live pointer.
    @discardableResult
    func finishLive(title: String, entries: [TranscriptEntry], notes: String,
                    start: Date? = nil, end: Date? = nil) -> URL? {
        defer { liveURL = nil }
        // Keep the session if it has a transcript OR typed notes; discard a truly
        // empty one (e.g. New tapped, nothing entered).
        let hasNotes = !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !entries.isEmpty || hasNotes else {
            if let url = liveURL { try? FileManager.default.removeItem(at: url); refresh() }
            return nil
        }
        guard let folder = ensureSaveFolder() else { return nil }
        let url = liveURL ?? uniqueURL(
            base: sanitize(title.isEmpty ? defaultTitle(for: start ?? Date()) : title),
            in: folder
        )
        writeMarkdown(to: url, entries: entries, notes: notes, start: start, end: end)
        return url
    }

    /// The raw transcript markdown (with any segment markers) of a saved file.
    /// Captured when an append recording starts so autosave/finish can rebuild the
    /// file as `existing + new segment` without double-appending.
    func rawTranscript(of url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return Self.components(of: text).transcript
    }

    /// Appends a new recording segment to an existing session: rewrites the
    /// transcript as `base` (the file's transcript when the append started) plus a
    /// freshly-marked segment for `entries`. A legacy `base` with no marker is
    /// wrapped as its own segment (using the file's creation date) so dividers can
    /// distinguish it from the new run. Notes and tasks are preserved.
    func appendSegment(to url: URL, base: String, entries: [TranscriptEntry],
                       start: Date, end: Date?) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parts = Self.components(of: text)
        var prefix = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefix.isEmpty && !Self.hasSegmentMarker(prefix) {
            prefix = Self.segmentMarkerLine(start: createdAt(of: url), end: nil) + "\n\n" + prefix
        }
        let newSeg = Self.segmentMarkerLine(start: start, end: end) + "\n\n"
            + Self.transcriptBody(entries: entries)
        let combined = (prefix.isEmpty ? "" : prefix + "\n\n") + newSeg + "\n"
        writeSections(to: url, header: parts.header, notes: parts.notes,
                      tasks: parts.tasks, transcript: combined)
    }

    /// Reads the transcript as ordered segments (for the divider-aware view).
    func loadSegments(_ url: URL) -> [TranscriptSegment] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Self.parseSegments(of: text)
    }

    @discardableResult
    private func writeMarkdown(to url: URL, entries: [TranscriptEntry], notes: String,
                               start: Date? = nil, end: Date? = nil) -> URL? {
        let markdown = Self.markdown(title: url.deletingPathExtension().lastPathComponent,
                                     createdAt: start ?? Date(),
                                     entries: entries,
                                     notes: notes,
                                     start: start,
                                     end: end)
        do {
            try markdown.data(using: .utf8)?.write(to: url, options: .atomic)
            refresh()
            return url
        } catch {
            NSLog("[store] write failed: %@", error.localizedDescription)
            return nil
        }
    }

    /// Rewrites only the Notes section of a saved file, preserving the tasks and
    /// transcript (and its per-line timestamps) verbatim. Migrates old files that
    /// predate the section headers.
    func saveNotes(_ url: URL, notes: String) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parts = Self.components(of: text)
        writeSections(to: url, header: parts.header, notes: notes,
                      tasks: parts.tasks, transcript: parts.transcript)
    }

    /// Rewrites notes + tasks together (used after an AI enhance), preserving the
    /// transcript.
    func saveNotesAndTasks(_ url: URL, notes: String, tasks: [TaskItem]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parts = Self.components(of: text)
        writeSections(to: url, header: parts.header, notes: notes,
                      tasks: Self.tasksMarkdown(tasks), transcript: parts.transcript)
    }

    /// Applies a text transform (e.g. glossary correction) across a saved file's
    /// notes, tasks, and transcript, rewriting it in place. The transcript's raw
    /// Markdown (and its per-line timestamps) is preserved except for the
    /// transformed words. Returns true if anything changed.
    @discardableResult
    func applyTextTransform(_ transform: (String) -> String, to url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let parts = Self.components(of: text)
        let newNotes = transform(parts.notes)
        let newTasks = transform(parts.tasks)
        let newTranscript = transform(parts.transcript)
        guard newNotes != parts.notes || newTasks != parts.tasks
                || newTranscript != parts.transcript else { return false }
        writeSections(to: url, header: parts.header, notes: newNotes,
                      tasks: newTasks, transcript: newTranscript)
        return true
    }

    /// Applies a single whole-word correction across a saved file (notes, tasks,
    /// transcript), preserving transcript timestamps.
    @discardableResult
    func applyCorrection(to url: URL, variant: String, canonical: String) -> Bool {
        applyTextTransform({ Glossary.replaceWholeWord(variant, with: canonical, in: $0) }, to: url)
    }

    /// Rewrites only the Tasks section, preserving notes + transcript.
    func saveTasks(_ url: URL, tasks: [TaskItem]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parts = Self.components(of: text)
        writeSections(to: url, header: parts.header, notes: parts.notes,
                      tasks: Self.tasksMarkdown(tasks), transcript: parts.transcript)
    }

    /// Serializes the four sections in a stable order (Notes → Tasks →
    /// Transcript), omitting empty Notes/Tasks blocks. Pure/nonisolated so both
    /// the store and off-actor task writes can use it.
    nonisolated static func composeSections(header: String, notes: String,
                                            tasks: String, transcript: String) -> String {
        var out = header
        if !out.hasSuffix("\n\n") { out += out.hasSuffix("\n") ? "\n" : "\n\n" }
        out += "## Notes\n\n"
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty { out += trimmedNotes + "\n\n" }
        let trimmedTasks = tasks.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTasks.isEmpty { out += "## Tasks\n\n" + trimmedTasks + "\n\n" }
        out += "## Transcript\n\n"
        out += transcript
        return out
    }

    private func writeSections(to url: URL, header: String, notes: String,
                               tasks: String, transcript: String) {
        let out = Self.composeSections(header: header, notes: notes,
                                       tasks: tasks, transcript: transcript)
        do {
            try out.data(using: .utf8)?.write(to: url, options: .atomic)
            refresh()
        } catch {
            NSLog("[store] section write failed: %@", error.localizedDescription)
        }
    }

    /// Reads a file's tasks directly (used by AI tools, off the main actor).
    nonisolated static func tasksInFile(at url: URL) -> [TaskItem] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseTasks(components(of: text).tasks)
    }

    /// Writes a file's tasks directly, preserving notes + transcript (used by AI
    /// tools). The folder watcher picks up the change to refresh the sidebar.
    nonisolated static func writeTasks(_ tasks: [TaskItem], toFileAt url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parts = components(of: text)
        let out = composeSections(header: parts.header, notes: parts.notes,
                                  tasks: tasksMarkdown(tasks), transcript: parts.transcript)
        try? out.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Reads the Notes section (Markdown) from a saved file, or "" if none.
    func loadNotes(_ url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return Self.components(of: text).notes
    }

    /// Reads the checkbox tasks from a saved file's `## Tasks` section.
    func loadTasks(_ url: URL) -> [TaskItem] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Self.parseTasks(Self.components(of: text).tasks)
    }

    @discardableResult
    func rename(_ file: SessionFile, to newTitle: String) -> URL? {
        rename(file.url, to: newTitle)
    }

    /// Renames a session file to `newTitle` (sanitized, de-duplicated). Returns
    /// the new URL, or nil if the title is empty, unchanged, or the move fails.
    @discardableResult
    func rename(_ url: URL, to newTitle: String) -> URL? {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let dir = url.deletingLastPathComponent()
        // No-op if the sanitized title matches the current filename.
        if sanitize(trimmed) == url.deletingPathExtension().lastPathComponent { return nil }
        let dest = uniqueURL(base: sanitize(trimmed), in: dir)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            refresh()
            return dest
        } catch {
            NSLog("[store] rename failed: %@", error.localizedDescription)
            return nil
        }
    }

    func delete(_ file: SessionFile) {
        try? FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
        refresh()
    }

    /// Moves a session `.md` file into `folder`. Returns the new URL, or nil if
    /// the file already lives there or the move fails.
    @discardableResult
    func move(_ fileURL: URL, to folder: URL) -> URL? {
        guard fileURL.pathExtension.lowercased() == "md" else { return nil }
        guard fileURL.deletingLastPathComponent() != folder else { return nil }
        let base = fileURL.deletingPathExtension().lastPathComponent
        let dest = uniqueURL(base: base, in: folder)
        do {
            try FileManager.default.moveItem(at: fileURL, to: dest)
            refresh()
            return dest
        } catch {
            NSLog("[store] move failed: %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - Read / parse

    func load(_ url: URL) -> [ParsedLine] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Self.parse(text)
    }

    func createdAt(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    // MARK: - Folder watching

    private func rewatch() {
        watchers.forEach { $0.cancel() }
        watchers = []
        for folder in folders {
            let fd = open(folder.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.refresh() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    // MARK: - Helpers

    private func defaultTitle(for date: Date) -> String {
        let template = UserDefaults.standard.string(
            forKey: AppSettings.sessionNamingTemplateKey
        ) ?? AppSettings.defaultSessionNamingTemplate
        return Self.resolveSessionName(template: template, date: date)
    }

    static func sessionNamePreview(template: String, date: Date = Date()) -> String {
        resolveSessionName(template: template, date: date)
    }

    private static func resolveSessionName(template: String, date: Date) -> String {
        let chosen = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = chosen.isEmpty ? AppSettings.defaultSessionNamingTemplate : chosen
        return pattern
            .replacingOccurrences(
                of: "{date}",
                with: date.formatted(date: .abbreviated, time: .omitted)
            )
            .replacingOccurrences(
                of: "{time}",
                with: date.formatted(date: .omitted, time: .shortened)
            )
    }

    private func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.prefix(120))
        return trimmed.isEmpty ? "Session" : trimmed
    }

    private func uniqueURL(base: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(base).appendingPathExtension("md")
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension("md")
            n += 1
        }
        return candidate
    }

    // MARK: - Markdown (de)serialization

    static func markdown(title: String, createdAt: Date, entries: [TranscriptEntry],
                         notes: String, start: Date? = nil, end: Date? = nil) -> String {
        var out = "# \(title)\n\n"
        out += "_\(createdAt.formatted(date: .abbreviated, time: .shortened))_\n\n"
        out += "## Notes\n\n"
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty { out += trimmedNotes + "\n\n" }
        out += "## Transcript\n\n"
        if !entries.isEmpty {
            // Every recording writes a segment marker (even the first) so a later
            // append knows this run's time range. A lone segment renders without a
            // divider; dividers only appear once a session has 2+ segments.
            if start != nil { out += segmentMarkerLine(start: start, end: end) + "\n\n" }
            out += transcriptBody(entries: entries) + "\n"
        }
        return out
    }

    /// The speaker/time blocks for a run of entries (no segment marker).
    nonisolated static func transcriptBody(entries: [TranscriptEntry]) -> String {
        var out = ""
        // Persist in spoken order (startedAt), not finalize order — the two
        // recognizers can finalize out of sequence relative to when audio began.
        for entry in entries.sorted(by: { $0.startedAt < $1.startedAt }) {
            let time = entry.date.formatted(date: .omitted, time: .shortened)
            out += "**\(entry.speaker.rawValue)** · \(time)\n\n"
            // A resolved on-screen speaker (yours or a meeting participant's) is
            // written as an inline "Name: …" prefix on the text. The prefix is
            // added only here, at serialization — `entry.text` stays clean in
            // memory so repeated autosaves never stack prefixes.
            if let name = entry.speakerName,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out += "\(name): \(entry.text)\n\n"
            } else {
                out += entry.text + "\n\n"
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Segment markers

    /// Marker written into the transcript before each recording's blocks, e.g.
    /// `<!-- thread:segment 2026-07-11T21:03:00Z 2026-07-11T21:20:00Z -->`.
    /// End is omitted while a recording is still in progress or unknown (legacy).
    private static let segTag = "<!-- thread:segment"

    nonisolated static func segmentMarkerLine(start: Date?, end: Date?) -> String {
        let f = ISO8601DateFormatter()
        var s = segTag
        if let start { s += " " + f.string(from: start) }
        if let end { s += " " + f.string(from: end) }
        return s + " -->"
    }

    nonisolated static func isSegmentMarker(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(segTag)
    }

    nonisolated static func hasSegmentMarker(_ text: String) -> Bool {
        text.components(separatedBy: "\n").contains { isSegmentMarker($0) }
    }

    private nonisolated static func parseSegmentMarker(_ line: String) -> (start: Date?, end: Date?) {
        let f = ISO8601DateFormatter()
        let inner = line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: segTag, with: "")
            .replacingOccurrences(of: "-->", with: "")
            .trimmingCharacters(in: .whitespaces)
        let toks = inner.split(separator: " ").map(String.init)
        return (toks.indices.contains(0) ? f.date(from: toks[0]) : nil,
                toks.indices.contains(1) ? f.date(from: toks[1]) : nil)
    }

    // MARK: - Cached segment summaries

    /// Hidden one-line comment holding an AI mini-summary of the preceding
    /// segment, written on a single line (newlines flattened) so it never
    /// disrupts transcript parsing or rendering.
    private static let segSummaryTag = "<!-- thread:segsummary"

    nonisolated static func segSummaryLine(_ text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "-->", with: "->")
            .trimmingCharacters(in: .whitespaces)
        return segSummaryTag + " " + flat + " -->"
    }

    nonisolated static func isSegmentSummaryMarker(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(segSummaryTag)
    }

    private nonisolated static func parseSegmentSummary(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: segSummaryTag, with: "")
            .replacingOccurrences(of: "-->", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Persists AI mini-summaries for older segments by inserting a hidden
    /// `thread:segsummary` comment immediately after each segment's marker,
    /// leaving transcript bodies (and their timestamps) untouched.
    func cacheSegmentSummaries(to url: URL, _ summaries: [Int: String]) {
        guard !summaries.isEmpty else { return }
        _ = url.startAccessingSecurityScopedResource()
        defer { url.stopAccessingSecurityScopedResource() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parts = Self.components(of: text)
        var transcript = parts.transcript
        for (idx, summary) in summaries.sorted(by: { $0.key < $1.key }) {
            transcript = Self.insertingSummary(summary, forSegmentIndex: idx, into: transcript)
        }
        writeSections(to: url, header: parts.header, notes: parts.notes,
                      tasks: parts.tasks, transcript: transcript)
    }

    nonisolated static func insertingSummary(_ summary: String, forSegmentIndex idx: Int, into transcript: String) -> String {
        var lines = transcript.components(separatedBy: "\n")
        var markerCount = -1
        var i = 0
        while i < lines.count {
            if isSegmentMarker(lines[i]) {
                markerCount += 1
                if markerCount == idx {
                    let newLine = segSummaryLine(summary)
                    var j = i + 1
                    while j < lines.count && lines[j].trimmingCharacters(in: .whitespaces).isEmpty { j += 1 }
                    if j < lines.count && isSegmentSummaryMarker(lines[j]) {
                        lines[j] = newLine
                    } else {
                        lines.insert(newLine, at: i + 1)
                    }
                    break
                }
            }
            i += 1
        }
        return lines.joined(separator: "\n")
    }

    /// Splits a session file into its header (title/date), Notes markdown, and
    /// transcript body. Backward compatible: files without `## Notes` /
    /// `## Transcript` headers are treated as header + transcript, no notes.
    nonisolated static func components(of text: String) -> (header: String, notes: String, tasks: String, transcript: String) {
        let lines = text.components(separatedBy: "\n")
        var header: [String] = []
        var notes: [String] = []
        var tasks: [String] = []
        var transcript: [String] = []
        // 0 = header, 1 = notes, 2 = tasks, 3 = transcript
        var section = 0
        var sawSectionHeader = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "## Notes" { section = 1; sawSectionHeader = true; continue }
            if trimmed == "## Tasks" { section = 2; sawSectionHeader = true; continue }
            if trimmed == "## Transcript" { section = 3; sawSectionHeader = true; continue }
            switch section {
            case 1: notes.append(line)
            case 2: tasks.append(line)
            case 3: transcript.append(line)
            default:
                // No section header seen yet. In an old-format file the transcript
                // begins at the first speaker block; everything before is header.
                if !sawSectionHeader,
                   trimmed.hasPrefix("**You**") || trimmed.hasPrefix("**Meeting**") {
                    section = 3
                    transcript.append(line)
                } else {
                    header.append(line)
                }
            }
        }

        func joinedTrimmed(_ arr: [String]) -> String {
            arr.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let headerText = joinedTrimmed(header)
        return (header: headerText.isEmpty ? headerText : headerText + "\n",
                notes: joinedTrimmed(notes),
                tasks: joinedTrimmed(tasks),
                transcript: joinedTrimmed(transcript) + "\n")
    }

    // MARK: - Tasks

    /// Parses `- [ ]` / `- [x]` task-list lines from a `## Tasks` section body.
    nonisolated static func parseTasks(_ section: String) -> [TaskItem] {
        let regex = try? NSRegularExpression(pattern: "^[-*•]?\\s*\\[( |x|X)\\]\\s*(.+)$")
        var out: [TaskItem] = []
        for raw in section.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            guard let m = regex?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges == 3 else { continue }
            let mark = ns.substring(with: m.range(at: 1)).lowercased()
            let body = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if !body.isEmpty { out.append(TaskItem(text: body, done: mark == "x")) }
        }
        return out
    }

    nonisolated static func tasksMarkdown(_ tasks: [TaskItem]) -> String {
        tasks.map { "- [\($0.done ? "x" : " ")] \($0.text)" }.joined(separator: "\n")
    }

    /// Splits an enhanced-notes Markdown blob into the prose (everything except
    /// the Action Items section) and the action-item task texts, so tasks can
    /// live in their own strip instead of the note body.
    nonisolated static func splitActionItems(from markdown: String) -> (notes: String, tasks: [String]) {
        var notes: [String] = []
        var tasks: [String] = []
        var inActionItems = false
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Defensive cleanup for models that echo the task context despite
            // being told tasks are handled separately.
            if trimmed.caseInsensitiveCompare("Current tasks:") == .orderedSame {
                continue
            }
            if trimmed.hasPrefix("## ") {
                inActionItems = trimmed.lowercased().contains("action item")
                if inActionItems { continue } // drop the heading — tasks move out
                notes.append(line)
                continue
            }
            if inActionItems {
                if let t = taskText(from: trimmed) { tasks.append(t) }
            } else if isCheckboxTask(trimmed), let t = taskText(from: trimmed) {
                // Checkbox lines never belong in the rich notes body.
                tasks.append(t)
            } else {
                notes.append(line)
            }
        }
        return (notes.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), tasks)
    }

    /// Strips a leading bullet and any `[ ]`/`[x]` marker from a line, returning
    /// the bare task text (or nil if the line isn't a bullet).
    private nonisolated static func taskText(from line: String) -> String? {
        guard let first = line.first, "-*•".contains(first) else { return nil }
        var s = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[ ]") || s.lowercased().hasPrefix("[x]") { s = String(s.dropFirst(3)) }
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private nonisolated static func isCheckboxTask(_ line: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "^[-*•]\\s*\\[( |x|X)\\]\\s*.+$") else {
            return false
        }
        let range = NSRange(line.startIndex..., in: line)
        return regex.firstMatch(in: line, range: range) != nil
    }

    /// Rebuilds the task list from freshly generated texts, carrying over the
    /// done-state of matching tasks and preserving existing/manual tasks.
    nonisolated static func mergeTasks(new texts: [String], existing: [TaskItem]) -> [TaskItem] {
        func norm(_ s: String) -> String {
            s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var result = existing
        var seen = Set(existing.map { norm($0.text) })
        for raw in texts {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let key = norm(text)
            guard seen.insert(key).inserted else { continue }
            result.append(TaskItem(text: text, done: false))
        }
        return result
    }

    /// Tolerant parser: blocks begin with a `**Speaker** · time` header line;
    /// following non-empty lines are that block's text until the next header.
    /// Segment markers are skipped. Only the transcript section is parsed.
    nonisolated static func parse(_ text: String) -> [ParsedLine] {
        parseSegments(of: text).flatMap { $0.lines }
    }

    /// Parses the transcript into ordered segments split on segment markers.
    /// Content before the first marker (or a whole legacy file) becomes one
    /// segment with nil times.
    nonisolated static func parseSegments(of text: String) -> [TranscriptSegment] {
        let transcript = components(of: text).transcript
        var segments: [TranscriptSegment] = []
        var curStart: Date?
        var curEnd: Date?
        var curSummary: String?
        var curLines: [ParsedLine] = []
        var currentSpeaker: Speaker?
        var buffer: [String] = []

        func flushLine() {
            guard let speaker = currentSpeaker else { return }
            let joined = buffer.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty else { buffer = []; return }
            let (name, text) = Self.splitSpeakerPrefix(joined)
            curLines.append(ParsedLine(speaker: speaker, text: text, speakerName: name))
            buffer = []
        }
        func flushSegment() {
            flushLine()
            if !curLines.isEmpty {
                segments.append(TranscriptSegment(start: curStart, end: curEnd,
                                                  summary: curSummary, lines: curLines))
            }
            curLines = []; currentSpeaker = nil; curStart = nil; curEnd = nil; curSummary = nil
        }

        for raw in transcript.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if isSegmentMarker(line) {
                flushSegment()
                let m = parseSegmentMarker(line)
                curStart = m.start; curEnd = m.end
            } else if isSegmentSummaryMarker(line) {
                curSummary = parseSegmentSummary(line)
            } else if line.hasPrefix("**You**") {
                flushLine(); currentSpeaker = .you
            } else if line.hasPrefix("**Meeting**") {
                flushLine(); currentSpeaker = .meeting
            } else if line.hasPrefix("#") || (line.hasPrefix("_") && line.hasSuffix("_")) {
                continue // title / date metadata
            } else if currentSpeaker != nil {
                buffer.append(raw)
            }
        }
        flushSegment()
        return segments
    }

    /// Recovers an inline "Name: text" speaker prefix (written at serialization
    /// for resolved speakers) into a separate name. Only strips when the part
    /// before the first ": " is a plausible display name (2–3 capitalized words),
    /// so ordinary speech that happens to contain a colon is left untouched.
    nonisolated private static func splitSpeakerPrefix(_ text: String) -> (name: String?, text: String) {
        guard let range = text.range(of: ": ") else { return (nil, text) }
        let name = String(text[text.startIndex..<range.lowerBound])
        let rest = String(text[range.upperBound...])
        guard !rest.isEmpty, isDisplayName(name) else { return (nil, text) }
        return (name, rest)
    }

    nonisolated private static func isDisplayName(_ text: String) -> Bool {
        guard text.count >= 2, text.count <= 40 else { return false }
        let tokens = text.split(separator: " ").map(String.init)
        guard (2...3).contains(tokens.count) else { return false }
        for token in tokens {
            guard let first = token.first, first.isUppercase else { return false }
            if token.contains(where: { !($0.isLetter || $0 == "-" || $0 == "." || $0 == "'") }) {
                return false
            }
        }
        return true
    }
}
