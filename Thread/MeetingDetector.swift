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

struct DetectedMeeting: Equatable {
    let source: String   // e.g. "Google Meet"
    let title: String    // human name from the tab, e.g. "My Event"
    let code: String     // meeting code, e.g. "abc-defg-hij"
    let url: String
    let isInCall: Bool   // true once joined; false while on the pre-join/lobby screen
}

struct TabInfo: Sendable {
    let url: String
    let title: String
}

/// Reads Chrome's open tabs via AppleScript. Runs entirely on a private serial
/// queue so the (synchronous, cross-process) Apple Event never blocks the main
/// thread. NSAppleScript is not thread-safe, so all access is confined to that
/// one queue.
final class ChromeTabsReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.thread.detector.applescript", qos: .utility)
    private var script: NSAppleScript?

    private let source = """
    tell application "Google Chrome"
        set out to ""
        repeat with w in windows
            repeat with t in tabs of w
                set out to out & (URL of t) & tab & (title of t) & linefeed
            end repeat
        end repeat
        return out
    end tell
    """

    /// Reads all tabs. Calls back with either the tabs or an AppleScript error code.
    func read(completion: @escaping @Sendable ([TabInfo]?, Int?) -> Void) {
        queue.async {
            if self.script == nil { self.script = NSAppleScript(source: self.source) }
            guard let script = self.script else { completion(nil, nil); return }

            var errorInfo: NSDictionary?
            let result = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let code = errorInfo["NSAppleScriptErrorNumber"] as? Int ?? 0
                completion(nil, code)
                return
            }

            let joined = result.stringValue ?? ""
            let tabs = joined
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { line -> TabInfo in
                    let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                    let url = parts.first.map(String.init) ?? ""
                    let title = parts.count > 1 ? String(parts[1]) : ""
                    return TabInfo(url: url, title: title)
                }
            completion(tabs, nil)
        }
    }
}

/// Detects an active Google Meet call by checking whether Chrome is running and
/// has a tab whose URL is a real Meet room (not the landing page). Polls on a
/// timer and publishes an armed `DetectedMeeting` for the UI to act on.
@MainActor
final class MeetingDetector: ObservableObject {

    @Published private(set) var detected: DetectedMeeting?
    @Published private(set) var permissionHint: String?

    private var pollTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var dismissedURLs: Set<String> = []
    private let reader = ChromeTabsReader()
    private var polling = false

    private let chromeBundleID = "com.google.Chrome"
    private let pollInterval: TimeInterval = 2

    // Matches a real Meet room path like /abc-defg-hij (3-4-3 lowercase letters).
    private let meetRegex = try! NSRegularExpression(
        pattern: #"meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})"#,
        options: [.caseInsensitive]
    )

    // MARK: - Lifecycle

    func start() {
        stop()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // Re-poll immediately when *Chrome specifically* launches or comes to the
        // front, so the meeting name resolves quickly after you join. We filter to
        // Chrome so unrelated app switches don't trigger extra polls.
        let center = NSWorkspace.shared.notificationCenter
        let chromeID = chromeBundleID
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == chromeID else { return }
                Task { @MainActor in self?.poll() }
            }
            workspaceObservers.append(token)
        }

        poll()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    /// Dismiss the current prompt and don't re-arm for the same room.
    func dismiss() {
        if let url = detected?.url { dismissedURLs.insert(url) }
        detected = nil
    }

    // MARK: - Polling

    private func poll() {
        guard !polling else { return }
        guard isRunning(bundleID: chromeBundleID) else {
            clearIfNeeded(reason: "Chrome not running")
            return
        }
        polling = true
        reader.read { [weak self] tabs, code in
            Task { @MainActor in self?.handle(tabs: tabs, permissionCode: code) }
        }
    }

    private func handle(tabs: [TabInfo]?, permissionCode: Int?) {
        polling = false

        if let permissionCode {
            // -1743: user hasn't granted Automation permission for Chrome.
            permissionHint = (permissionCode == -1743)
                ? "Allow Thread to control Chrome in System Settings › Privacy & Security › Automation."
                : nil
            return
        }
        permissionHint = nil

        guard let tabs else { return }
        for tab in tabs {
            guard let code = meetCode(in: tab.url) else { continue }
            if dismissedURLs.contains(tab.url) { return }
            let inCall = isInCall(tabTitle: tab.title)
            let name = displayName(tabTitle: tab.title, code: code)
            let meeting = DetectedMeeting(source: "Google Meet", title: name, code: code, url: tab.url, isInCall: inCall)
            if detected != meeting {
                detected = meeting
                #if DEBUG
                NSLog("[detector] %@: Google Meet \"%@\" (%@) %@",
                      inCall ? "in call" : "lobby", name, code, tab.url)
                #endif
            }
            return
        }
        clearIfNeeded(reason: "no Meet tab")
    }

    /// Google Meet's pre-join/lobby screen keeps the generic "Google Meet" tab
    /// title; once you actually join it switches to "Meet - <name/code>". So a
    /// specific (non-generic) title means we're in the call.
    private func isInCall(tabTitle: String) -> Bool {
        let normalized = tabTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.isEmpty && normalized != "google meet"
    }

    /// Derives a human meeting name from the Meet tab title by stripping the
    /// "Meet" / "Google Meet" decorations and the bare room code.
    private func displayName(tabTitle: String, code: String) -> String {
        let separators = [" - ", " – ", " — ", " | "]
        var working = tabTitle
        for separator in separators {
            working = working.replacingOccurrences(of: separator, with: "\u{1}")
        }
        let parts = working
            .split(separator: "\u{1}")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { part in
                let lower = part.lowercased()
                return !lower.isEmpty && lower != "meet" && lower != "google meet" && part != code
            }
        let name = parts.joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        // Ladder: real event name → bare room code → generic label.
        if !name.isEmpty { return name }
        return code.isEmpty ? "Google Meet" : code
    }

    private func clearIfNeeded(reason: String) {
        if detected != nil {
            #if DEBUG
            NSLog("[detector] cleared: %@", reason)
            #endif
            detected = nil
        }
    }

    private func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    private func meetCode(in url: String) -> String? {
        let range = NSRange(url.startIndex..., in: url)
        guard let match = meetRegex.firstMatch(in: url, range: range),
              let codeRange = Range(match.range(at: 1), in: url) else { return nil }
        return String(url[codeRange])
    }
}
