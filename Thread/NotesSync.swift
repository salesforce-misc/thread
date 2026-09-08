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

private func notesSyncLog(_ message: String) {
    NSLog("[notes] %@", message)
}

/// Destination account in Apple Notes. Names match what Notes.app reports in English.
enum NotesAccount: String, CaseIterable, Identifiable {
    case iCloud = "iCloud"
    case onMyMac = "On My Mac"

    var id: String { rawValue }
    var label: String { rawValue }
}

enum NotesSyncError: LocalizedError {
    case permissionDenied
    case accountMissing(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Allow Thread to control Notes in System Settings › Privacy & Security › Automation."
        case .accountMissing(let name):
            return "No “\(name)” account in Notes. Pick the other destination, or turn on Notes in iCloud."
        case .failed(let message):
            return message
        }
    }
}

/// One-way Thread → Apple Notes. NSAppleScript is not thread-safe, so every
/// Apple Event runs on a private serial queue (same pattern as Chrome tab reads).
final class NotesAppleScript: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.thread.notes.applescript", qos: .userInitiated)

    func run(_ source: String, completion: @escaping @Sendable (Result<String, NotesSyncError>) -> Void) {
        queue.async {
            guard let script = NSAppleScript(source: source) else {
                completion(.failure(.failed("Could not build the Notes script.")))
                return
            }
            var errorInfo: NSDictionary?
            let result = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let code = errorInfo["NSAppleScriptErrorNumber"] as? Int ?? 0
                let message = (errorInfo["NSAppleScriptErrorMessage"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                notesSyncLog("AppleScript error \(code): \(message)")
                if code == -1743 {
                    completion(.failure(.permissionDenied))
                } else {
                    completion(.failure(.failed(message.isEmpty
                                                ? "Notes returned an error (\(code))."
                                                : message)))
                }
                return
            }
            completion(.success(result.stringValue ?? ""))
        }
    }

    func runAsync(_ source: String) async -> Result<String, NotesSyncError> {
        await withCheckedContinuation { continuation in
            run(source) { continuation.resume(returning: $0) }
        }
    }
}

/// Copies saved sessions into a Thread folder in Apple Notes. Notes is a view,
/// not a second editor: we only push. Live recording does not send; a real
/// save (Stop, summary, tasks) upserts. Opening Thread or creating the Notes
/// folder copies every saved session; a Note missing from the Thread folder
/// is created again.
@MainActor
final class NotesSyncController: ObservableObject {
    @Published private(set) var folderReady: Bool
    @Published private(set) var isBusy = false
    @Published private(set) var justSynced = false
    @Published var lastError: String?
    @Published private(set) var syncingURL: URL?

    static let folderName = "Thread"
    static let uploadSymbol = "icloud.and.arrow.up"

    private let runner = NotesAppleScript()
    private var syncedReset: Task<Void, Never>?
    private var syncWatchdog: Task<Void, Never>?
    private var persistDebounce: Task<Void, Never>?
    private var launchRefresh: Task<Void, Never>?
    private var pendingQueue: [URL] = []
    private weak var queuedStore: SessionStore?
    private var queuedAccount: String?
    private var syncGeneration = 0
    private var keepNotesVisible = false

    init() {
        folderReady = UserDefaults.standard.bool(forKey: AppSettings.notesSyncFolderReadyKey)
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: AppSettings.notesSyncEnabledKey)
    }

    /// Changing iCloud ↔ On My Mac means a different folder. They create it again.
    func accountChanged() {
        folderReady = false
        persistFolderReady()
        lastError = nil
    }

    func ensureFolder(account: String, store: SessionStore, isRecording: Bool) {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        keepNotesVisible = Self.notesIsVisible()
        let source = Self.ensureFolderScript(account: account)
        runner.run(source) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.hideNotesUnlessOpen()
                self.scheduleHideNotes()
                self.isBusy = false
                switch result {
                case .success:
                    self.folderReady = true
                    self.persistFolderReady()
                    self.lastError = nil
                    self.copyAllSavedSessions(store: store, account: account,
                                              isRecording: isRecording, reason: "folder create")
                case .failure(let error):
                    self.folderReady = false
                    self.persistFolderReady()
                    self.lastError = Self.message(for: error, account: account)
                }
            }
        }
    }

    /// Manual retry: push this session now.
    func syncSession(at url: URL, store: SessionStore, account: String) {
        persistDebounce?.cancel()
        pendingQueue.removeAll { $0 == url }
        enqueue([url], store: store, account: account, quiet: false, front: true)
    }

    /// Debounced upsert after a real save. No-op while recording ticks; those
    /// never post `threadSessionDidPersist`.
    func scheduleUpsert(at url: URL, store: SessionStore, account: String) {
        guard isEnabled, folderReady else { return }
        persistDebounce?.cancel()
        persistDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self.enqueue([url], store: store, account: account, quiet: true)
        }
    }

    /// When Thread opens, copy every saved session into the Thread folder in
    /// Notes. Already-sent notes are updated; missing ones are created.
    /// Sessions never saved stay out. Skipped while recording.
    func refreshLinkedOnOpen(store: SessionStore, account: String, isRecording: Bool) {
        copyAllSavedSessions(store: store, account: account, isRecording: isRecording,
                             reason: "launch", delayNs: 600_000_000)
    }

    /// Copy every saved session. Used on launch and after Create Folder.
    private func copyAllSavedSessions(store: SessionStore, account: String,
                                      isRecording: Bool, reason: String,
                                      delayNs: UInt64 = 0) {
        guard isEnabled, folderReady, !isRecording else { return }
        let urls = store.allSessionURLs()
        guard !urls.isEmpty else {
            notesSyncLog("\(reason): no saved sessions")
            return
        }
        notesSyncLog("\(reason) \(urls.count) saved session(s)")
        persistDebounce?.cancel()
        launchRefresh?.cancel()
        if delayNs == 0 {
            enqueue(urls, store: store, account: account, quiet: true)
            return
        }
        launchRefresh = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled, self.isEnabled, self.folderReady else { return }
            self.enqueue(urls, store: store, account: account, quiet: true)
        }
    }

    private func enqueue(_ urls: [URL], store: SessionStore, account: String,
                         quiet: Bool, front: Bool = false) {
        guard isEnabled, folderReady else { return }
        queuedStore = store
        queuedAccount = account
        for url in urls {
            pendingQueue.removeAll { $0 == url }
            if front {
                pendingQueue.insert(url, at: 0)
            } else {
                pendingQueue.append(url)
            }
        }
        drainQueue(quiet: quiet)
    }

    private func drainQueue(quiet: Bool) {
        guard !isBusy else { return }
        guard let url = pendingQueue.first,
              let store = queuedStore,
              let account = queuedAccount else { return }
        pendingQueue.removeFirst()
        startUpsert(at: url, store: store, account: account, quiet: quiet)
    }

    private func startUpsert(at url: URL, store: SessionStore, account: String, quiet: Bool) {
        guard isEnabled, folderReady else { return }
        guard !isBusy else {
            enqueue([url], store: store, account: account, quiet: quiet)
            return
        }
        isBusy = true
        lastError = nil
        justSynced = false
        syncingURL = url
        keepNotesVisible = Self.notesIsVisible()
        armWatchdog()
        let generation = syncGeneration

        NotificationCenter.default.post(name: .threadFlushNotes, object: url)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard generation == self.syncGeneration else { return }
            guard await self.ensureNotesReady() else {
                self.fail("Couldn’t start Notes. Open Notes once, then try again.",
                          quiet: quiet, stopQueue: true)
                return
            }
            switch await self.pushSession(at: url, store: store, account: account) {
            case .success:
                self.completeSync()
                self.drainQueue(quiet: true)
            case .failure(let error):
                var resetFolder = false
                if case .permissionDenied = error { resetFolder = true }
                self.fail(Self.message(for: error, account: account),
                          resetFolder: resetFolder, quiet: quiet)
            }
        }
    }

    @discardableResult
    private func pushSession(at url: URL, store: SessionStore,
                             account: String) async -> Result<String, NotesSyncError> {
        let title = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        let notes = store.loadNotes(url)
        let tasks = store.loadTasks(url)
        let transcript = store.rawTranscript(of: url)
        let fullHTML = NotesHTML.body(title: title, notes: notes, tasks: tasks, transcript: transcript)
        notesSyncLog("push “\(title)” html \(fullHTML.utf8.count) bytes, \(tasks.count) tasks, account \(account)")
        let titleURL: URL
        let bodyURL: URL
        do {
            titleURL = try Self.writeTextFile(title)
            bodyURL = try Self.writeBodyFile(fullHTML)
        } catch {
            return .failure(.failed("Could not write the Notes payload: \(error.localizedDescription)"))
        }
        defer {
            try? FileManager.default.removeItem(at: titleURL)
            try? FileManager.default.removeItem(at: bodyURL)
        }
        let existingID = store.appleNotesID(of: url)
        let source: String
        if let existingID, !existingID.isEmpty {
            notesSyncLog("push update \(title) \(Self.shortNoteID(existingID))")
            source = Self.updateNoteScript(account: account, id: existingID,
                                           titlePath: titleURL.path, bodyPath: bodyURL.path)
        } else {
            notesSyncLog("push create")
            source = Self.createNoteScript(account: account, titlePath: titleURL.path,
                                           bodyPath: bodyURL.path)
        }
        var result = await runner.runAsync(source)
        hideNotesUnlessOpen()
        if case .success(let raw) = result,
           raw.trimmingCharacters(in: .whitespacesAndNewlines) == "MISSING" {
            notesSyncLog("old Notes copy gone; creating a new one")
            result = await runner.runAsync(
                Self.createNoteScript(account: account, titlePath: titleURL.path,
                                      bodyPath: bodyURL.path)
            )
            hideNotesUnlessOpen()
        }
        switch result {
        case .success(let raw):
            let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, token != "MISSING" else {
                return .failure(.failed("Notes did not return a note id."))
            }
            store.setAppleNotesID(token, on: url)
            folderReady = true
            persistFolderReady()
            notesSyncLog("OK \(title) \(Self.shortNoteID(token))")
            return .success(token)
        case .failure(let error):
            return .failure(error)
        }
    }

    private func completeSync() {
        hideNotesUnlessOpen()
        scheduleHideNotes()
        syncWatchdog?.cancel()
        isBusy = false
        syncingURL = nil
        lastError = nil
        flashSynced()
    }

    private func fail(_ message: String, resetFolder: Bool = false, quiet: Bool = false,
                      stopQueue: Bool = false) {
        syncGeneration += 1
        syncWatchdog?.cancel()
        hideNotesUnlessOpen()
        scheduleHideNotes()
        isBusy = false
        syncingURL = nil
        lastError = message
        UserDefaults.standard.set(message, forKey: "notesSync.lastError")
        if resetFolder {
            folderReady = false
            persistFolderReady()
        }
        if resetFolder || stopQueue {
            pendingQueue.removeAll()
        }
        notesSyncLog("FAIL \(message)")
        if !quiet {
            let alert = NSAlert()
            alert.messageText = "Couldn’t copy to Notes"
            alert.informativeText = message
            alert.runModal()
        }
        if !resetFolder && !stopQueue {
            drainQueue(quiet: true)
        }
    }

    private func armWatchdog() {
        syncGeneration += 1
        let generation = syncGeneration
        syncWatchdog?.cancel()
        syncWatchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 130_000_000_000)
            guard !Task.isCancelled, generation == syncGeneration, isBusy else { return }
            fail("Notes didn’t respond. Open System Settings › Privacy & Security › Automation, allow Thread Dev to control Notes, then try Create Folder again.",
                 resetFolder: true)
        }
    }

    private func flashSynced() {
        syncedReset?.cancel()
        justSynced = true
        syncedReset = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            justSynced = false
        }
    }

    private func persistFolderReady() {
        UserDefaults.standard.set(folderReady, forKey: AppSettings.notesSyncFolderReadyKey)
    }

    private static let notesBundleID = "com.apple.Notes"

    private static func notesIsVisible() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: notesBundleID)
            .contains { !$0.isHidden }
    }

    private func hideNotesUnlessOpen() {
        guard !keepNotesVisible else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.notesBundleID)
            .first?.hide()
    }

    private func scheduleHideNotes() {
        guard !keepNotesVisible else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            self.hideNotesUnlessOpen()
        }
    }

    private func ensureNotesReady() async -> Bool {
        if NSRunningApplication.runningApplications(withBundleIdentifier: Self.notesBundleID).isEmpty {
            notesSyncLog("Notes not running; launching")
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.notesBundleID) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                config.addsToRecentItems = false
                do {
                    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: config)
                } catch {
                    notesSyncLog("launch Notes failed: \(error.localizedDescription)")
                }
            }
        }
        let probe = """
        tell application "Notes"
            launch
            return (count of accounts) as text
        end tell
        """
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            hideNotesUnlessOpen()
            if case .success = await runner.runAsync(probe) {
                hideNotesUnlessOpen()
                notesSyncLog("Notes ready")
                return true
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        hideNotesUnlessOpen()
        notesSyncLog("Notes never became scriptable")
        return false
    }

    private static func message(for error: NotesSyncError, account: String) -> String {
        switch error {
        case .permissionDenied:
            return error.localizedDescription
        case .failed(let message)
            where message.localizedCaseInsensitiveContains("can't get account")
                || message.localizedCaseInsensitiveContains("can’t get account"):
            return NotesSyncError.accountMissing(account).localizedDescription
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Scripts

    private static func ensureFolderScript(account: String) -> String {
        """
        tell application "Notes"
            launch
            tell account "\(escape(account))"
                if not (exists folder "\(escape(folderName))") then
                    make new folder with properties {name:"\(escape(folderName))"}
                end if
                return id of folder "\(escape(folderName))" as string
            end tell
        end tell
        """
    }

    private static func writeBodyFile(_ html: String) throws -> URL {
        try writeTextFile(html, ext: "html")
    }

    private static func writeTextFile(_ text: String, ext: String = "txt") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thread-notes-\(UUID().uuidString).\(ext)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func createNoteScript(account: String, titlePath: String, bodyPath: String) -> String {
        """
        set noteTitle to \(readUTF8(titlePath))
        set bodyHTML to \(readUTF8(bodyPath))
        with timeout of 120 seconds
            tell application "Notes"
                launch
                tell account "\(escape(account))"
                    if not (exists folder "\(escape(folderName))") then
                        make new folder with properties {name:"\(escape(folderName))"}
                    end if
                    set dest to folder "\(escape(folderName))"
                    set newNote to make new note at dest with properties {name:noteTitle}
                    set body of newNote to bodyHTML
                    return (id of newNote) as text
                end tell
            end tell
        end timeout
        """
    }

    /// Updates only if that id is among `notes of folder Thread`. `exists note
    /// id` is account-wide, so Recently Deleted copies would otherwise look live
    /// and we would never create a replacement in the folder.
    private static func updateNoteScript(account: String, id: String, titlePath: String, bodyPath: String) -> String {
        """
        set noteTitle to \(readUTF8(titlePath))
        set bodyHTML to \(readUTF8(bodyPath))
        set targetID to "\(escape(id))"
        with timeout of 120 seconds
            tell application "Notes"
                launch
                tell account "\(escape(account))"
                    if not (exists folder "\(escape(folderName))") then return "MISSING"
                    tell folder "\(escape(folderName))"
                        set noteList to notes
                        repeat with i from 1 to (count of noteList)
                            set n to item i of noteList
                            if (id of n as text) is targetID then
                                set name of n to noteTitle
                                set body of n to bodyHTML
                                return (id of n as text)
                            end if
                        end repeat
                    end tell
                    return "MISSING"
                end tell
            end tell
        end timeout
        """
    }

    private static func shortNoteID(_ token: String) -> String {
        token.split(separator: "/").suffix(2).joined(separator: "/")
    }

    private static func readUTF8(_ path: String) -> String {
        "read (POSIX file \"\(escape(path))\") as «class utf8»"
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Markdown → Notes HTML

/// Small HTML subset Notes.app accepts via AppleScript `body`. The session
/// name is the first line so Notes' title matches; then Summary, Tasks,
/// Transcript. Task checkboxes are unicode; Notes does not create native
/// checklists from HTML.
enum NotesHTML {
    static func body(title: String, notes: String, tasks: [TaskItem], transcript: String = "") -> String {
        var parts: [String] = []
        parts.append("<div><h1>\(inlineHTML(title))</h1></div>")
        parts.append("<div><h2>Summary</h2></div>")
        let notesHTML = markdownToHTML(notes)
        parts.append(notesHTML.isEmpty ? "<div><br></div>" : notesHTML)

        parts.append("<div><h2>Tasks</h2></div>")
        if tasks.isEmpty {
            parts.append("<div><br></div>")
        } else {
            parts.append("<ul>")
            for task in tasks {
                let mark = task.done ? "☑︎ " : "☐ "
                parts.append("<li>\(inlineHTML(mark + task.text))</li>")
            }
            parts.append("</ul>")
        }

        parts.append("<div><h2>Transcript</h2></div>")
        let transcriptHTML = markdownToHTML(transcript)
        parts.append(transcriptHTML.isEmpty ? "<div><br></div>" : transcriptHTML)
        return "<html><head></head><body>\(parts.joined())</body></html>"
    }

    static func markdownToHTML(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var html: [String] = []
        var inUL = false
        var inOL = false

        func closeLists() {
            if inUL { html.append("</ul>"); inUL = false }
            if inOL { html.append("</ol>"); inOL = false }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                closeLists()
                continue
            }
            if trimmed.hasPrefix("<!--") { continue }
            if let heading = heading(trimmed) {
                closeLists()
                html.append("<div><h\(heading.level)>\(inlineHTML(heading.text))</h\(heading.level)></div>")
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                if inOL { html.append("</ol>"); inOL = false }
                if !inUL { html.append("<ul>"); inUL = true }
                let item = listItemText(String(trimmed.dropFirst(2)))
                html.append("<li>\(inlineHTML(item))</li>")
                continue
            }
            if let item = numberedItem(trimmed) {
                if inUL { html.append("</ul>"); inUL = false }
                if !inOL { html.append("<ol>"); inOL = true }
                html.append("<li>\(inlineHTML(item))</li>")
                continue
            }
            closeLists()
            html.append("<div>\(inlineHTML(trimmed))</div>")
        }
        closeLists()
        return html.joined()
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...3).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.hasPrefix(" ") || rest.isEmpty else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func numberedItem(_ line: String) -> String? {
        guard let dot = line.firstIndex(of: "."), dot > line.startIndex else { return nil }
        let n = line[line.startIndex..<dot]
        guard n.allSatisfy(\.isNumber) else { return nil }
        var rest = line[line.index(after: dot)...]
        guard rest.hasPrefix(" ") else { return nil }
        rest = rest.dropFirst()
        return String(rest)
    }

    private static func listItemText(_ raw: String) -> String {
        if raw.hasPrefix("[ ]") {
            return "☐ " + raw.dropFirst(3).trimmingCharacters(in: .whitespaces)
        }
        let lower = raw.lowercased()
        if lower.hasPrefix("[x]") {
            return "☑︎ " + raw.dropFirst(3).trimmingCharacters(in: .whitespaces)
        }
        return raw
    }

    private static func inlineHTML(_ text: String) -> String {
        var s = escape(text)
        s = replace(s, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#, template: #"<a href="$2">$1</a>"#)
        s = replace(s, pattern: #"\*\*(.+?)\*\*"#, template: #"<b>$1</b>"#)
        s = replace(s, pattern: #"\*(.+?)\*"#, template: #"<i>$1</i>"#)
        s = replace(s, pattern: #"`([^`]+)`"#, template: #"<code>$1</code>"#)
        return s
    }

    private static func replace(_ string: String, pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return string }
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: template)
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
