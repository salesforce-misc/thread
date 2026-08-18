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

import AppKit
import ApplicationServices
import OSLog

/// A DEBUG-only investigation tool. It locates Google Meet's web-content area in
/// Chrome and writes a compact dump of that subtree (role, DOM class list, DOM
/// id, and text) to a file, so we can discover how names and the active-speaker
/// "speaking" animation are represented.
///
/// It never clicks or mutates anything; it only reads. Run it from the Debug
/// menu (or ⌘⌃⌥P) while in a live Meet call — ideally trigger it repeatedly
/// while different people talk, so we can diff which class toggles on the
/// speaker's tile.
///
/// Output is appended to ~/thread-meet-dump.txt (also mirrored to the unified
/// log, subsystem "com.thread.app.dev", category "MeetProbe").
final class MeetAccessibilityProbe: @unchecked Sendable {
    static let shared = MeetAccessibilityProbe()

    private let queue = DispatchQueue(label: "com.thread.meet-probe", qos: .utility)
    private let logger = Logger(subsystem: "com.thread.app.dev", category: "MeetProbe")

    /// Output file for the current run; set per-provider at the start of each
    /// entry point (Meet → thread-meet-dump.txt, Teams → thread-teams-dump.txt).
    private var dumpURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("thread-meet-dump.txt")

    /// Speaking-marker classes for the current run (empty for Teams until we
    /// discover them via `watch`); used by locate/collectSpeakingRects.
    private var activeSpeakingClasses: Set<String> = ["kssMZb"]

    /// The provider for the current run; drives name-label parsing (Teams strips
    /// "(Unverified)"/"(EXT)" and allows lowercase handles).
    private var activeProvider: MeetingApp = .googleMeet

    private func configure(for provider: MeetingApp) {
        let name: String
        switch provider {
        case .googleMeet: name = "thread-meet-dump.txt"
        case .microsoftTeams: name = "thread-teams-dump.txt"
        case .zoom: name = "thread-zoom-dump.txt"
        }
        dumpURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(name)
        activeSpeakingClasses = provider.speakingClasses
        activeProvider = provider
    }

    /// Finds the meeting's web area(s) in whichever supported Chromium browser is
    /// running it (Chrome, Edge, Arc, …).
    private func findWebAreas(provider: MeetingApp) -> [(url: String, element: AXUIElement)] {
        for bundleID in meetingHostBundleIDs {
            guard let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).first else { continue }
            let app = AXUIElementCreateApplication(running.processIdentifier)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var windows = elementArray(app, kAXWindowsAttribute as String)
            if windows.isEmpty, let focused = element(app, kAXFocusedWindowAttribute as String) {
                windows = [focused]
            }
            var areas: [(url: String, element: AXUIElement)] = []
            for window in windows {
                collectWebAreas(window, provider: provider, bundleID: bundleID, into: &areas)
            }
            if !areas.isEmpty {
                append("host=\(bundleID) webAreas=\(areas.count)\n")
                return areas
            }
        }
        return []
    }

    /// Substrings that hint at a speaker / state indicator worth flagging.
    private let keywords = [
        "speaking", "presenting", "presentation", "muted", "unmute",
        "microphone", "pinned", "spotlight", "active speaker", "raised",
    ]

    func probeOnce(provider: MeetingApp = .googleMeet) {
        queue.async { [weak self] in self?.run(provider: provider) }
    }

    /// Time-diff mode: scans the meeting web area repeatedly and logs which DOM
    /// class tokens appear/disappear between scans (and the nearest participant
    /// name), so we can see exactly which class the app toggles on the person who
    /// is speaking. Take turns talking during the window and narrate who's on.
    /// This is how a new provider's speaking marker (e.g. Teams') is discovered.
    func watch(seconds: Double = 30, intervalMS: Int = 500, provider: MeetingApp = .googleMeet) {
        queue.async { [weak self] in
            self?.runWatch(seconds: seconds, intervalMS: intervalMS, provider: provider)
        }
    }

    /// Locate mode: each scan, finds every element carrying a known speaking
    /// marker class, resolves the participant name by nearest label, and logs
    /// the result. Only useful once `provider.speakingClasses` is populated.
    func locateSpeaking(seconds: Double = 30, intervalMS: Int = 400, provider: MeetingApp = .googleMeet) {
        queue.async { [weak self] in
            self?.runLocate(seconds: seconds, intervalMS: intervalMS, provider: provider)
        }
    }

    private func runLocate(seconds: Double, intervalMS: Int, provider: MeetingApp) {
        configure(for: provider)
        guard AXIsProcessTrusted() else {
            logger.info("LOCATE: accessibility permission not granted"); return
        }
        append("===== LOCATE start \(Self.timestamp()) [\(provider.label)] classes=\(activeSpeakingClasses.sorted()) =====\n")
        if activeSpeakingClasses.isEmpty {
            append("No speaking classes known for \(provider.label) yet — run Watch to discover them.\n")
        }
        var dumpedChain = false
        let deadline = Date().addingTimeInterval(seconds)
        var scan = 0

        while Date() < deadline {
            scan += 1
            let webAreas = findWebAreas(provider: provider)

            var markers: [CGRect] = []
            for area in webAreas { collectSpeakingRects(area.element, into: &markers) }
            var labels: [(name: String, rect: CGRect)] = []
            for area in webAreas { collectNameLabels(area.element, into: &labels) }

            if !dumpedChain, !markers.isEmpty {
                append("--- geometry dump ---\n")
                append("markers (\(markers.count)): " + markers.map(Self.rectStr).joined(separator: "  ") + "\n")
                append("name labels (\(labels.count)):\n")
                append(labels.map { "  \"\($0.name)\" \(Self.rectStr($0.rect))" }.joined(separator: "\n"))
                append("\n--- end geometry ---\n")
                dumpedChain = true
            }

            var names: [String] = []
            for marker in markers {
                if let (name, dist) = nearestName(to: marker, labels: labels) {
                    let tagged = "\(name)@\(Int(dist))"
                    if !names.contains(tagged) { names.append(tagged) }
                }
            }
            if !markers.isEmpty {
                let rects = markers.map(Self.rectStr).joined(separator: " ")
                append("[\(Self.timestamp())] scan \(scan): markers=\(markers.count) at \(rects) names=[\(names.joined(separator: ", "))]\n")
            }
            Thread.sleep(forTimeInterval: Double(intervalMS) / 1000)
        }
        append("===== LOCATE end \(Self.timestamp()) scans=\(scan) =====\n\n")
        logger.info("LOCATE: done, \(scan, privacy: .public) scans")
    }

    /// Collects the on-screen rectangles of every element carrying a speaking
    /// marker class.
    private func collectSpeakingRects(_ root: AXUIElement, into rects: inout [CGRect]) {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < 8_000 {
            let (element, depth) = queue[index]
            index += 1
            if let classList = string(element, "AXDOMClassList") {
                let tokens = Set(classList.split(separator: " ").map(String.init))
                if !tokens.isDisjoint(with: activeSpeakingClasses), let r = frame(element), r.width > 0 {
                    rects.append(r)
                }
            }
            guard depth < 40 else { continue }
            for child in elementArray(element, kAXChildrenAttribute as String) {
                queue.append((child, depth + 1))
            }
        }
    }

    /// Collects participant name labels (text + on-screen rect) across the tree.
    private func collectNameLabels(_ root: AXUIElement, into labels: inout [(name: String, rect: CGRect)]) {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < 8_000 {
            let (element, depth) = queue[index]
            index += 1
            let text = firstNonEmpty(
                string(element, kAXDescriptionAttribute as String),
                string(element, kAXTitleAttribute as String),
                string(element, kAXValueAttribute as String)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let role = string(element, kAXRoleAttribute as String) ?? ""
            if let name = participantName(text, role: role),
               let r = frame(element), r.width > 0 {
                labels.append((name, r))
            }
            guard depth < 40 else { continue }
            for child in elementArray(element, kAXChildrenAttribute as String) {
                queue.append((child, depth + 1))
            }
        }
    }

    /// The name label nearest the marker's BOTTOM-LEFT corner. Meet anchors the
    /// name at the tile's bottom-left, and the speaking marker shares the tile, so
    /// corner proximity maps the indicator to its person even when the marker is
    /// the whole spotlighted tile (whose center would sit closer to a different
    /// tile's label).
    private func nearestName(to marker: CGRect, labels: [(name: String, rect: CGRect)]) -> (String, CGFloat)? {
        let corner = CGPoint(x: marker.minX, y: marker.maxY) // AX origin is top-left
        var best: (String, CGFloat)?
        for label in labels {
            let lc = CGPoint(x: label.rect.midX, y: label.rect.midY)
            let d = hypot(corner.x - lc.x, corner.y - lc.y)
            if best == nil || d < best!.1 { best = (label.name, d) }
        }
        return best
    }

    private func boolValue(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref as? Bool else { return nil }
        return value
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private static func rectStr(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }

    /// A human display name: 2–3 words, each starting with an uppercase letter,
    /// none of them a lowercase UI/function word. Meet's chrome ("Backgrounds and
    /// effects", "Turn on captions", "Host controls") fails this because it
    /// contains lowercased words, while real names ("Griffin Medwid") pass.
    private func isParticipantName(_ text: String) -> Bool {
        guard isNameLike(text) else { return false }
        let lower = text.lowercased()
        if lower.contains("meet -") || lower.contains("test speaker") { return false }
        if lower.contains("gemini") { return false }
        let tokens = text.split(separator: " ").map(String.init)
        guard (2...3).contains(tokens.count) else { return false }
        for token in tokens {
            guard let first = token.first, first.isUppercase else { return false }
        }
        return true
    }

    /// Provider-aware name normalization for locate, mirroring the live monitor.
    /// Meet uses the strict capitalized-words check; Teams strips a trailing
    /// "(Unverified)"/"(EXT)", accepts lowercase handles, and requires a text
    /// node so app-bar and toolbar labels ("Apps", "Notes") stay out.
    private func participantName(_ text: String, role: String) -> String? {
        switch activeProvider {
        case .googleMeet:
            return isParticipantName(text) ? text : nil
        case .microsoftTeams, .zoom:
            guard role == "AXStaticText" else { return nil }
            var t = text
            if let paren = t.range(of: " (", options: .backwards) {
                t = String(t[t.startIndex..<paren.lowerBound])
            }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return isLikelyPersonName(t) ? t : nil
        }
    }

    private func ancestorChain(_ element: AXUIElement) -> String {
        var lines: [String] = []
        var current: AXUIElement? = element
        var level = 0
        while let node = current, level < 15 {
            let role = string(node, kAXRoleAttribute as String) ?? "?"
            let cls = string(node, "AXDOMClassList") ?? ""
            let domID = string(node, "AXDOMIdentifier") ?? ""
            let desc = firstNonEmpty(
                string(node, kAXDescriptionAttribute as String),
                string(node, kAXTitleAttribute as String),
                string(node, kAXValueAttribute as String)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            var line = "  [\(level)] \(role)"
            if !domID.isEmpty { line += " #\(domID)" }
            if !cls.isEmpty { line += " .[\(cls.prefix(80))]" }
            if !desc.isEmpty { line += " : \"\(desc.prefix(50))\"" }
            lines.append(line)
            current = self.element(node, kAXParentAttribute as String)
            level += 1
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func runWatch(seconds: Double, intervalMS: Int, provider: MeetingApp) {
        configure(for: provider)
        guard AXIsProcessTrusted() else {
            logger.info("WATCH: accessibility permission not granted"); return
        }
        append("===== WATCH start \(Self.timestamp()) [\(provider.label)] (\(seconds)s @ \(intervalMS)ms) =====\n")
        logger.info("WATCH: started for \(seconds, privacy: .public)s [\(provider.label, privacy: .public)]")

        var prevCounts: [String: Int] = [:]
        var prevNames: [String: String] = [:]
        var prevActive = ""
        let deadline = Date().addingTimeInterval(seconds)
        var scan = 0

        while Date() < deadline {
            scan += 1
            // Re-locate the web areas each scan (cheap, and robust to relayout).
            let webAreas = findWebAreas(provider: provider)

            var counts: [String: Int] = [:]
            var tokenName: [String: String] = [:]
            for area in webAreas {
                tallyTokens(area.element, counts: &counts, tokenName: &tokenName)
            }

            // Skip scan 1: every token appears (0->N) against an empty baseline,
            // which is just noise. Only log real deltas, and only for tokens tied
            // to a participant name — this drops the control-bar/tooltip churn
            // ("Unmute mic", "Turn camera off", "Encryption status", …) so the
            // speaker marker stands out.
            if scan > 1 {
                var changes: [String] = []
                var anonymous: [String] = []
                for token in Set(prevCounts.keys).union(counts.keys) {
                    let before = prevCounts[token] ?? 0
                    let after = counts[token] ?? 0
                    guard before != after else { continue }
                    let near = tokenName[token] ?? prevNames[token] ?? ""
                    let sign = after > before ? "+" : "-"
                    if isLikelyPersonName(near) {
                        changes.append("\(sign)[\(token)] \(before)->\(after) ~\(near)")
                    } else {
                        anonymous.append("\(sign)[\(token)] \(before)->\(after)")
                    }
                }
                if !changes.isEmpty {
                    append("[\(Self.timestamp())] scan \(scan): \(changes.joined(separator: "  "))\n")
                }
                // Zoom hangs its names off bare static text nodes with no tile
                // class, so a marker there is never name-adjacent. Log the
                // unattributed churn as well or it stays invisible.
                if !anonymous.isEmpty {
                    append("[\(Self.timestamp())] scan \(scan) anon: \(anonymous.prefix(12).joined(separator: "  "))\n")
                }
            }

            // Zoom may draw its speaking ring on a canvas rather than toggling a
            // class. Its speaker view promotes the talker to one big tile, so
            // test that separately: whose name sits inside the active frame.
            if provider == .zoom {
                let active = webAreas.compactMap { activeTileNames($0.element) }
                    .first(where: { !$0.isEmpty }) ?? ""
                if active != prevActive {
                    append("[\(Self.timestamp())] scan \(scan) active-tile: \"\(active)\"\n")
                    prevActive = active
                }
            }
            prevCounts = counts
            prevNames = tokenName
            Thread.sleep(forTimeInterval: Double(intervalMS) / 1000)
        }
        append("===== WATCH end \(Self.timestamp()) scans=\(scan) =====\n\n")
        logger.info("WATCH: done, \(scan, privacy: .public) scans -> \(self.dumpURL.path, privacy: .public)")
    }

    /// Whether any class list on this element's ancestors contains `substring`.
    private func hasAncestorClass(_ element: AXUIElement, _ substring: String,
                                  levels: Int = 5) -> Bool {
        var current: AXUIElement? = element
        var level = 0
        while let node = current, level < levels {
            if let classList = string(node, "AXDOMClassList"), classList.contains(substring) {
                return true
            }
            current = self.element(node, kAXParentAttribute as String)
            level += 1
        }
        return false
    }

    /// The participant name(s) drawn inside Zoom's active-speaker frame, matched
    /// by geometry: the name nodes sit outside the tile in the tree, so
    /// containment is the only thing that ties a name to a tile.
    private func activeTileNames(_ root: AXUIElement) -> String {
        var activeRects: [CGRect] = []
        var candidates: [(name: String, rect: CGRect)] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < 8_000 {
            let (element, depth) = queue[index]
            index += 1

            if let classList = string(element, "AXDOMClassList") {
                let tokens = Set(classList.split(separator: " ").map(String.init))
                if tokens.contains("speaker-active-container__video-frame"),
                   let rect = frame(element), rect.width > 0 {
                    activeRects.append(rect)
                }
            }
            // Zoom's controls overlay the video, so containment alone drags in
            // footer labels. A real tile name lives under a video-avatar node.
            if string(element, kAXRoleAttribute as String) == "AXStaticText" {
                let text = firstNonEmpty(
                    string(element, kAXValueAttribute as String),
                    string(element, kAXDescriptionAttribute as String),
                    string(element, kAXTitleAttribute as String)
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if isLikelyPersonName(text), hasAncestorClass(element, "video-avatar"),
                   let rect = frame(element), rect.width > 0 {
                    candidates.append((text, rect))
                }
            }

            guard depth < 40 else { continue }
            for child in elementArray(element, kAXChildrenAttribute as String) {
                queue.append((child, depth + 1))
            }
        }
        var names: [String] = []
        for candidate in candidates {
            let center = CGPoint(x: candidate.rect.midX, y: candidate.rect.midY)
            guard activeRects.contains(where: { $0.contains(center) }) else { continue }
            if !names.contains(candidate.name) { names.append(candidate.name) }
        }
        return names.joined(separator: ", ")
    }

    /// Counts every DOM class token under `root`, and records a representative
    /// participant name for each token (the carrying element's own name-like
    /// text, else its parent's) so a toggling "speaking" class can be tied to a
    /// person.
    private func tallyTokens(_ root: AXUIElement, counts: inout [String: Int],
                             tokenName: inout [String: String]) {
        var queue: [(el: AXUIElement, depth: Int, parentName: String)] = [(root, 0, "")]
        var index = 0
        while index < queue.count, index < 8_000 {
            let (element, depth, parentName) = queue[index]
            index += 1

            let ownText = firstNonEmpty(
                string(element, kAXDescriptionAttribute as String),
                string(element, kAXTitleAttribute as String),
                string(element, kAXValueAttribute as String)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let ownName = isNameLike(ownText) ? ownText : ""
            let name = ownName.isEmpty ? parentName : ownName

            if let classList = string(element, "AXDOMClassList"), !classList.isEmpty {
                for token in classList.split(separator: " ").map(String.init) where !token.isEmpty {
                    counts[token, default: 0] += 1
                    if tokenName[token] == nil, !name.isEmpty { tokenName[token] = name }
                }
            }

            guard depth < 40 else { continue }
            for child in elementArray(element, kAXChildrenAttribute as String) {
                queue.append((child, depth + 1, name))
            }
        }
    }

    private func run(provider: MeetingApp) {
        configure(for: provider)
        guard AXIsProcessTrusted() else {
            logger.info("PROBE: accessibility permission not granted")
            return
        }

        let webAreas = findWebAreas(provider: provider)

        var out = "===== PROBE \(Self.timestamp()) [\(provider.label)] =====\n"
        out += "webAreas=\(webAreas.count)\n"

        if webAreas.isEmpty {
            out += "No \(provider.label) web area found. Are you inside a call "
                + "(not the pre-join screen), in a supported browser?\n"
            // Distinguish "nothing to read" from "read it, didn't recognize it":
            // a provider whose URL is hidden and whose window is titled something
            // unexpected looks identical to an app that isn't running at all.
            out += "Web areas visible across all hosts:\n"
            let seen = allWebAreas()
            out += seen.isEmpty
                ? "  (none — no host app is exposing web content)\n"
                : seen.map { "  \($0)\n" }.joined()
        } else {
            for area in webAreas {
                out += "\n----- WEB AREA url=\(area.url) -----\n"
                out += dump(area.element)
            }
        }
        out += "===== END =====\n\n"

        append(out)
        logger.info("PROBE: wrote \(out.count, privacy: .public) bytes to \(self.dumpURL.path, privacy: .public) (webAreas=\(webAreas.count, privacy: .public))")
    }

    /// Dumps every web area any host is exposing, whatever it's titled. For
    /// providers we can't recognize yet: Zoom titles its tab after the meeting
    /// topic ("New"), so there's no product name to match on and the only way in
    /// is to read the tree and find something structural to key off.
    func dumpAllWebAreas() {
        queue.async { [weak self] in self?.runDumpAll() }
    }

    private func runDumpAll() {
        dumpURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("thread-webareas-dump.txt")
        guard AXIsProcessTrusted() else {
            logger.info("DUMP ALL: accessibility permission not granted"); return
        }
        let areas = webAreaElements()
        append("===== DUMP ALL WEB AREAS \(Self.timestamp()) areas=\(areas.count) =====\n")
        for area in areas {
            append("\n----- \(area.bundleID) url=\"\(area.url)\" title=\"\(area.title)\" -----\n")
            append(dump(area.element))
        }
        append("===== END =====\n\n")
        logger.info("DUMP ALL: \(areas.count, privacy: .public) areas -> \(self.dumpURL.path, privacy: .public)")
    }

    /// Dumps a native app's whole window tree, for apps that render their meeting
    /// themselves instead of hosting a web frontend. Zoom desktop is the case in
    /// point: if it exposes no web area, names and speaking state have to come
    /// from ordinary AX elements or not at all.
    func dumpNativeApp(bundleID: String) {
        queue.async { [weak self] in self?.runDumpNative(bundleID: bundleID) }
    }

    private func runDumpNative(bundleID: String) {
        dumpURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("thread-native-dump.txt")
        guard AXIsProcessTrusted() else {
            logger.info("DUMP NATIVE: accessibility permission not granted"); return
        }
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else {
            append("===== DUMP NATIVE \(Self.timestamp()) \(bundleID) NOT RUNNING =====\n\n")
            logger.info("DUMP NATIVE: \(bundleID, privacy: .public) is not running")
            return
        }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var windows = elementArray(app, kAXWindowsAttribute as String)
        if windows.isEmpty, let focused = element(app, kAXFocusedWindowAttribute as String) {
            windows = [focused]
        }
        append("===== DUMP NATIVE \(Self.timestamp()) \(bundleID) windows=\(windows.count) =====\n")
        for (index, window) in windows.enumerated() {
            let title = string(window, kAXTitleAttribute as String) ?? ""
            append("\n----- window \(index) \"\(title)\" -----\n")
            append(dump(window))
        }
        append("===== END =====\n\n")
        logger.info("DUMP NATIVE: \(windows.count, privacy: .public) windows -> \(self.dumpURL.path, privacy: .public)")
    }

    /// Time-diff mode for native apps: logs which on-screen strings appear and
    /// disappear between scans. Class tokens don't exist outside a web frontend,
    /// so text churn ("Paul Grant, speaking", a mute label flipping) is the only
    /// discovery signal available.
    func watchNativeText(seconds: Double = 30, intervalMS: Int = 500, bundleID: String) {
        queue.async { [weak self] in
            self?.runWatchNative(seconds: seconds, intervalMS: intervalMS, bundleID: bundleID)
        }
    }

    private func runWatchNative(seconds: Double, intervalMS: Int, bundleID: String) {
        dumpURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("thread-native-dump.txt")
        guard AXIsProcessTrusted() else {
            logger.info("WATCH NATIVE: accessibility permission not granted"); return
        }
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else {
            append("===== WATCH NATIVE \(Self.timestamp()) \(bundleID) NOT RUNNING =====\n\n")
            return
        }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        append("===== WATCH NATIVE start \(Self.timestamp()) \(bundleID) (\(seconds)s @ \(intervalMS)ms) =====\n")

        var previous: Set<String> = []
        let deadline = Date().addingTimeInterval(seconds)
        var scan = 0
        while Date() < deadline {
            scan += 1
            var windows = elementArray(app, kAXWindowsAttribute as String)
            if windows.isEmpty, let focused = element(app, kAXFocusedWindowAttribute as String) {
                windows = [focused]
            }
            var current: Set<String> = []
            for window in windows { collectNativeText(window, into: &current) }

            if scan == 1 {
                append("baseline (\(current.count)): \(current.sorted().joined(separator: " | "))\n")
            } else {
                let added = current.subtracting(previous).sorted()
                let removed = previous.subtracting(current).sorted()
                if !added.isEmpty || !removed.isEmpty {
                    var line = "[\(Self.timestamp())] scan \(scan):"
                    if !added.isEmpty { line += " +[\(added.joined(separator: " | "))]" }
                    if !removed.isEmpty { line += " -[\(removed.joined(separator: " | "))]" }
                    append(line + "\n")
                }
            }
            previous = current
            Thread.sleep(forTimeInterval: Double(intervalMS) / 1000)
        }
        append("===== WATCH NATIVE end \(Self.timestamp()) scans=\(scan) =====\n\n")
        logger.info("WATCH NATIVE: done, \(scan, privacy: .public) scans -> \(self.dumpURL.path, privacy: .public)")
    }

    /// Sets the flag VoiceOver sets when it attaches. Apps commonly withhold
    /// their richer accessibility detail until they believe a screen reader is
    /// listening, and Zoom ships with it off for us. Reversible, and worth
    /// treating as an experiment: it changes how another app behaves.
    func setEnhancedAccessibility(_ enabled: Bool, bundleID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).first else { return }
            let app = AXUIElementCreateApplication(running.processIdentifier)
            let status = AXUIElementSetAttributeValue(
                app, "AXEnhancedUserInterface" as CFString,
                (enabled ? kCFBooleanTrue : kCFBooleanFalse))
            let readBack = self.boolValue(app, "AXEnhancedUserInterface")
            self.append("===== ENHANCED UI \(Self.timestamp()) \(bundleID) set=\(enabled) status=\(status.rawValue) now=\(readBack.map(String.init) ?? "nil") =====\n")
            self.logger.info("ENHANCED UI: set=\(enabled, privacy: .public) status=\(status.rawValue, privacy: .public)")
        }
    }

    /// Lists every attribute and action a native app's participant tiles actually
    /// expose, rather than the handful we happen to read. Apps publish their own
    /// attributes, so an audio-level or speaking flag could be sitting there
    /// unread. Covers each tile's parent and children too, since the marker may
    /// live on the container instead of the tile.
    func dumpNativeTileAttributes(bundleID: String) {
        queue.async { [weak self] in self?.runDumpTileAttributes(bundleID: bundleID) }
    }

    private func runDumpTileAttributes(bundleID: String) {
        dumpURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("thread-native-attrs.txt")
        guard AXIsProcessTrusted() else {
            logger.info("ATTRS: accessibility permission not granted"); return
        }
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else {
            append("===== ATTRS \(Self.timestamp()) \(bundleID) NOT RUNNING =====\n\n"); return
        }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var windows = elementArray(app, kAXWindowsAttribute as String)
        if windows.isEmpty, let focused = element(app, kAXFocusedWindowAttribute as String) {
            windows = [focused]
        }
        var tiles: [(name: String, state: String, rect: CGRect, flags: String)] = []
        var tileElements: [AXUIElement] = []
        for window in windows { collectTileElements(window, into: &tileElements) }

        append("===== ATTRS \(Self.timestamp()) \(bundleID) tiles=\(tileElements.count) =====\n")
        append("\n--- application element ---\n")
        append(attributeReport(app))
        for (index, tile) in tileElements.enumerated() {
            let description = string(tile, kAXDescriptionAttribute as String) ?? ""
            append("\n--- tile \(index): \"\(description)\" ---\n")
            append(attributeReport(tile))
            if let parent = element(tile, kAXParentAttribute as String) {
                append("  parent:\n")
                append(attributeReport(parent, indent: "    "))
            }
            for (childIndex, child) in elementArray(tile, kAXChildrenAttribute as String)
                .prefix(6).enumerated() {
                append("  child \(childIndex):\n")
                append(attributeReport(child, indent: "    "))
            }
        }
        _ = tiles
        append("===== END =====\n\n")
        logger.info("ATTRS: \(tileElements.count, privacy: .public) tiles -> \(self.dumpURL.path, privacy: .public)")
    }

    private func collectTileElements(_ root: AXUIElement, into result: inout [AXUIElement]) {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < 8_000 {
            let (element, depth) = queue[index]
            index += 1
            if (string(element, kAXDescriptionAttribute as String) ?? "")
                .contains(", Computer audio ") {
                result.append(element)
            }
            guard depth < 40 else { continue }
            for child in elementArray(element, kAXChildrenAttribute as String) {
                queue.append((child, depth + 1))
            }
        }
    }

    /// Every attribute name this element publishes, with its value, plus the
    /// actions it supports.
    private func attributeReport(_ element: AXUIElement, indent: String = "  ") -> String {
        var lines: [String] = []
        var names: CFArray?
        if AXUIElementCopyAttributeNames(element, &names) == .success,
           let names = names as? [String] {
            for name in names {
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                let rendered = status == .success
                    ? describe(value) : "<\(status.rawValue)>"
                lines.append("\(indent)\(name) = \(rendered)")
            }
        } else {
            lines.append("\(indent)<no attribute names>")
        }
        var actions: CFArray?
        if AXUIElementCopyActionNames(element, &actions) == .success,
           let actions = actions as? [String], !actions.isEmpty {
            lines.append("\(indent)ACTIONS = \(actions.joined(separator: ", "))")
        }
        var parameterized: CFArray?
        if AXUIElementCopyParameterizedAttributeNames(element, &parameterized) == .success,
           let parameterized = parameterized as? [String], !parameterized.isEmpty {
            lines.append("\(indent)PARAMETERIZED = \(parameterized.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func describe(_ value: CFTypeRef?) -> String {
        guard let value else { return "nil" }
        if let string = value as? String { return "\"\(string.prefix(120))\"" }
        if let number = value as? NSNumber { return number.stringValue }
        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            let element = value as! AXUIElement
            let role = string(element, kAXRoleAttribute as String) ?? "?"
            let description = string(element, kAXDescriptionAttribute as String) ?? ""
            return "<\(role)\(description.isEmpty ? "" : " \"\(description.prefix(60))\"")>"
        }
        if CFGetTypeID(value) == AXValueGetTypeID() {
            if let rect = frameValue(value as! AXValue) { return Self.rectStr(rect) }
            return "<AXValue>"
        }
        if let array = value as? [AnyObject] {
            let inner = array.prefix(8).map { item -> String in
                if CFGetTypeID(item) == AXUIElementGetTypeID() {
                    return describe(item as CFTypeRef)
                }
                return String(describing: item).prefix(40).description
            }
            return "[\(array.count)] \(inner.joined(separator: " "))"
        }
        return String(describing: value).prefix(80).description
    }

    private func frameValue(_ value: AXValue) -> CGRect? {
        var rect = CGRect.zero
        if AXValueGetValue(value, .cgRect, &rect) { return rect }
        var point = CGPoint.zero
        if AXValueGetValue(value, .cgPoint, &point) {
            return CGRect(origin: point, size: .zero)
        }
        var size = CGSize.zero
        if AXValueGetValue(value, .cgSize, &size) { return CGRect(origin: .zero, size: size) }
        return nil
    }

    /// Time-diff mode over a native app's participant tiles, tracking each one's
    /// name and frame. Zoom desktop annotates mute state but not speech, so the
    /// remaining hope is the same as on Zoom web: in speaker view the talker is
    /// promoted to the largest tile.
    func watchNativeTiles(seconds: Double = 30, intervalMS: Int = 500, bundleID: String) {
        queue.async { [weak self] in
            self?.runWatchTiles(seconds: seconds, intervalMS: intervalMS, bundleID: bundleID)
        }
    }

    private func runWatchTiles(seconds: Double, intervalMS: Int, bundleID: String) {
        dumpURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("thread-native-dump.txt")
        guard AXIsProcessTrusted() else {
            logger.info("WATCH TILES: accessibility permission not granted"); return
        }
        guard let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else {
            append("===== WATCH TILES \(Self.timestamp()) \(bundleID) NOT RUNNING =====\n\n")
            return
        }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        append("===== WATCH TILES start \(Self.timestamp()) \(bundleID) (\(seconds)s @ \(intervalMS)ms) =====\n")

        var previous = ""
        let deadline = Date().addingTimeInterval(seconds)
        var scan = 0
        while Date() < deadline {
            scan += 1
            var windows = elementArray(app, kAXWindowsAttribute as String)
            if windows.isEmpty, let focused = element(app, kAXFocusedWindowAttribute as String) {
                windows = [focused]
            }
            var tiles: [(name: String, state: String, rect: CGRect, flags: String)] = []
            for window in windows { collectNativeTiles(window, into: &tiles) }

            // Order matters as much as size here: Zoom keeps every tile the same
            // size in gallery view, but appears to hand them over in a different
            // order after someone speaks. Mute state is logged alongside so a
            // silent window can't be mistaken for a negative result.
            let summary = "tiles=" + tiles
                .map { "\"\($0.name)\"[\($0.state)]\($0.flags)\(Self.rectStr($0.rect))" }
                .joined(separator: " ")
            if summary != previous {
                append("[\(Self.timestamp())] scan \(scan): \(summary)\n")
                previous = summary
            }
            Thread.sleep(forTimeInterval: Double(intervalMS) / 1000)
        }
        append("===== WATCH TILES end \(Self.timestamp()) scans=\(scan) =====\n\n")
        logger.info("WATCH TILES: done, \(scan, privacy: .public) scans -> \(self.dumpURL.path, privacy: .public)")
    }

    /// Participant tiles in a native meeting window, as (name, frame). Zoom
    /// describes each as "Paul Grant, Computer audio muted, Video off", so the
    /// name is everything before the first comma.
    private func collectNativeTiles(
        _ root: AXUIElement,
        into result: inout [(name: String, state: String, rect: CGRect, flags: String)]
    ) {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < 8_000 {
            let (element, depth) = queue[index]
            index += 1
            let description = string(element, kAXDescriptionAttribute as String) ?? ""
            if description.contains(", Computer audio ") {
                let parts = description.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                let name = parts.first ?? ""
                let state = parts.count > 1 ? parts[1] : ""
                // Either of these could be the marker we haven't found yet.
                var flags = ""
                if boolValue(element, kAXSelectedAttribute as String) == true { flags += "*sel" }
                if boolValue(element, kAXFocusedAttribute as String) == true { flags += "*foc" }
                if let rect = frame(element), rect.width > 0 {
                    result.append((name, state, rect, flags))
                }
            }
            guard depth < 40 else { continue }
            for child in elementArray(element, kAXChildrenAttribute as String) {
                queue.append((child, depth + 1))
            }
        }
    }

    /// Every non-empty label, title and value under `root`, tagged with its role.
    private func collectNativeText(_ root: AXUIElement, into result: inout Set<String>) {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < 8_000 {
            let (element, depth) = queue[index]
            index += 1
            let role = string(element, kAXRoleAttribute as String) ?? "?"
            let text = firstNonEmpty(
                string(element, kAXDescriptionAttribute as String),
                string(element, kAXTitleAttribute as String),
                string(element, kAXValueAttribute as String)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text.count < 80 { result.insert("\(role):\(text)") }
            guard depth < 40 else { continue }
            for child in elementArray(element, kAXChildrenAttribute as String) {
                queue.append((child, depth + 1))
            }
        }
    }

    /// Every web area any host app is exposing, as "bundle url=… title=…", for
    /// working out what a provider should match on.
    private func allWebAreas() -> [String] {
        webAreaElements().map { "\($0.bundleID) url=\"\($0.url)\" title=\"\($0.title)\"" }
    }

    private func webAreaElements()
    -> [(bundleID: String, url: String, title: String, element: AXUIElement)] {
        var found: [(bundleID: String, url: String, title: String, element: AXUIElement)] = []
        for bundleID in meetingHostBundleIDs {
            guard let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).first else { continue }
            let app = AXUIElementCreateApplication(running.processIdentifier)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var windows = elementArray(app, kAXWindowsAttribute as String)
            if windows.isEmpty, let focused = element(app, kAXFocusedWindowAttribute as String) {
                windows = [focused]
            }
            for window in windows {
                var queue: [(AXUIElement, Int)] = [(window, 0)]
                var index = 0
                while index < queue.count, index < 8_000 {
                    let (node, depth) = queue[index]
                    index += 1
                    if string(node, kAXRoleAttribute as String) == "AXWebArea" {
                        found.append((bundleID,
                                      string(node, "AXURL") ?? "",
                                      string(node, kAXTitleAttribute as String) ?? "",
                                      node))
                        continue
                    }
                    guard depth < 30 else { continue }
                    for child in elementArray(node, kAXChildrenAttribute as String) {
                        queue.append((child, depth + 1))
                    }
                }
            }
        }
        return found
    }

    // MARK: - Meeting web area discovery

    /// Whether one of `signatures` appears in a class list near the top of this
    /// web area, for providers the URL and title can't identify.
    private func hasDOMSignature(_ webArea: AXUIElement, _ signatures: [String]) -> Bool {
        guard !signatures.isEmpty else { return false }
        var queue: [(AXUIElement, Int)] = [(webArea, 0)]
        var index = 0
        while index < queue.count, index < 400 {
            let (element, depth) = queue[index]
            index += 1
            if let classList = string(element, "AXDOMClassList") {
                let tokens = classList.split(separator: " ").map(String.init)
                if tokens.contains(where: signatures.contains) { return true }
            }
            guard depth < 6 else { continue }
            for child in elementArray(element, kAXChildrenAttribute as String) {
                queue.append((child, depth + 1))
            }
        }
        return false
    }

    private func collectWebAreas(
        _ root: AXUIElement, provider: MeetingApp, bundleID: String,
        into result: inout [(url: String, element: AXUIElement)]
    ) {
        let isNativeHost = provider.nativeBundleIDs.contains(bundleID)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < 8_000 {
            let (element, depth) = queue[index]
            index += 1

            if string(element, kAXRoleAttribute as String) == "AXWebArea" {
                let url = string(element, "AXURL") ?? ""
                let title = (string(element, kAXTitleAttribute as String) ?? "")
                if isNativeHost
                    || provider.urlSubstrings.contains(where: url.contains)
                    || provider.titleHints.contains(where: title.lowercased().contains)
                    || hasDOMSignature(element, provider.domSignatures) {
                    result.append((url.isEmpty ? title : url, element))
                }
                continue // no need to descend into a web area while searching
            }
            guard depth < 30 else { continue }
            for child in elementArray(element, kAXChildrenAttribute as String) {
                queue.append((child, depth + 1))
            }
        }
    }

    // MARK: - Compact subtree dump

    private func dump(_ root: AXUIElement) -> String {
        let maxNodes = 6_000
        let maxDepth = 40
        var lines: [String] = []
        var keywordHits: [String] = []
        var names = Set<String>()
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0

        while index < queue.count, index < maxNodes {
            let (element, depth) = queue[index]
            index += 1

            let role = string(element, kAXRoleAttribute as String) ?? "?"
            let subrole = string(element, kAXSubroleAttribute as String) ?? ""
            let classList = string(element, "AXDOMClassList") ?? ""
            let domID = string(element, "AXDOMIdentifier") ?? ""
            let text = firstNonEmpty(
                string(element, kAXValueAttribute as String),
                string(element, kAXDescriptionAttribute as String),
                string(element, kAXTitleAttribute as String)
            )

            // Only emit "interesting" nodes to keep the dump readable: anything
            // with text, a DOM class/id, or a non-generic role.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty || !classList.isEmpty || !domID.isEmpty {
                let indent = String(repeating: "  ", count: min(depth, 20))
                var line = "\(indent)\(role)"
                if !subrole.isEmpty { line += "/\(subrole)" }
                if !domID.isEmpty { line += " #\(domID)" }
                if !classList.isEmpty { line += " .[\(classList)]" }
                if !trimmed.isEmpty {
                    let snippet = trimmed.replacingOccurrences(of: "\n", with: " ")
                    line += " : \"\(snippet.prefix(60))\""
                }
                lines.append(line)
            }

            if role == "AXStaticText" || role == "AXImage" {
                if isNameLike(trimmed) { names.insert(trimmed) }
            }

            let haystack = "\(subrole) \(classList) \(domID) \(text)".lowercased()
            if keywords.contains(where: haystack.contains) {
                keywordHits.append("\(role) .[\(classList)] #\(domID) : \(text.prefix(50))")
            }

            guard depth < maxDepth else { continue }
            for child in elementArray(element, kAXChildrenAttribute as String) {
                queue.append((child, depth + 1))
            }
        }

        var out = "nodes=\(index) names=\(names.sorted().joined(separator: " | "))\n"
        out += "keyword hits (\(keywordHits.count)):\n"
        out += keywordHits.prefix(60).map { "  * \($0)" }.joined(separator: "\n")
        out += "\ntree:\n"
        out += lines.joined(separator: "\n")
        out += "\n"
        return out
    }

    private func sweepNames(_ root: AXUIElement, into names: inout Set<String>) {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < 6_000 {
            let (element, depth) = queue[index]
            index += 1
            let role = string(element, kAXRoleAttribute as String) ?? ""
            if role == "AXStaticText" || role == "AXImage" {
                let text = firstNonEmpty(
                    string(element, kAXValueAttribute as String),
                    string(element, kAXDescriptionAttribute as String),
                    string(element, kAXTitleAttribute as String)
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                if isNameLike(text) { names.insert(text) }
            }
            guard depth < 35 else { continue }
            for child in elementArray(element, kAXChildrenAttribute as String) {
                queue.append((child, depth + 1))
            }
        }
    }

    private func isNameLike(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 40, !text.contains("\n") else { return false }
        return text.rangeOfCharacter(from: .letters) != nil
    }

    /// True for text that looks like a participant's display name rather than a
    /// Teams control/tooltip. Strips a trailing "(Unverified)"/"(EXT)"/"(Guest)"
    /// tag, then rejects UI phrases (mic/camera/chat/…) and shortcut glyphs, so
    /// the Watch log only surfaces tile-related token changes. Used for
    /// noise-filtering during discovery, not for final attribution.
    private func isLikelyPersonName(_ raw: String) -> Bool {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let paren = t.range(of: " (", options: .backwards) {
            t = String(t[t.startIndex..<paren.lowerBound])
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, t.count <= 40 else { return false }
        guard t.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        guard t.rangeOfCharacter(from: .letters) != nil else { return false }
        let lower = t.lowercased()
        let controls = [
            "mic", "camera", "encryption", "status", "chat", "people", "raise",
            "react", "view", "more", "leave", "share", "content", "caption",
            "background", "reaction", "hand", "transcription", "recording",
            "mute", "unmute", "tooltip", "toolbar", "menu", "button", "divider",
            "occlusion", "provider", "primitive", "flex", "gallery", "together",
        ]
        if controls.contains(where: lower.contains) { return false }
        if t.contains("⌘") || t.contains("⇧") { return false }
        return true
    }

    // MARK: - Output

    private func append(_ text: String) {
        if let handle = try? FileHandle(forWritingTo: dumpURL) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: dumpURL, atomically: true, encoding: .utf8)
        }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    private func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return ""
    }

    // MARK: - AX helpers

    private func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func elementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    private func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let arr = value as? [String] { return arr.joined(separator: " ") }
        return nil
    }
}
