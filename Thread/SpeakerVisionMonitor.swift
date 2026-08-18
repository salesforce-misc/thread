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
import CoreGraphics
import Foundation
import OSLog

/// How a speaking-marker rectangle is resolved to a participant name.
enum SpeakerMatch {
    /// The name label nearest the marker's bottom-left corner.
    case nearestCorner
    /// A name label lying inside the marker, closest to its bottom-left corner
    /// if several do.
    case containment
}

/// A supported browser meeting app and how to recognize it in the accessibility
/// tree. For Meet and Teams the active speaker is marked by a DOM class the web
/// app toggles on that participant's tile; Zoom instead has one permanent
/// active-speaker frame. Both were found by running the Debug "Watch" probe
/// during a call.
enum MeetingApp: CaseIterable {
    case googleMeet
    case microsoftTeams
    case zoom

    /// URL substrings that identify the meeting's web area.
    var urlSubstrings: [String] {
        switch self {
        case .googleMeet: return ["meet.google.com"]
        case .microsoftTeams:
            return ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"]
        case .zoom: return ["zoom.us", "zoom.com"]
        }
    }

    /// Fallback hints matched against the web area's title when the URL is empty
    /// — which is the common case, not the exception. They have to be specific
    /// enough not to poach each other: a bare "meet" also matches a Teams window
    /// titled "Meeting with …", and since Meet is tried first it would claim the
    /// call and then find none of its own markers.
    var titleHints: [String] {
        switch self {
        case .googleMeet: return ["meet.google.com", "meet -", "google meet"]
        case .microsoftTeams: return ["microsoft teams", "teams -"]
        case .zoom: return ["zoom meeting", "zoom workplace", "my meeting"]
        }
    }

    /// DOM class tokens found just below the web area, for providers neither the
    /// URL nor the title can identify. Zoom titles the tab after the meeting
    /// topic ("New"), so the only dependable signal is its own markup.
    var domSignatures: [String] {
        switch self {
        case .googleMeet, .microsoftTeams: return []
        case .zoom: return ["pwa-webclient", "pwa-webclient__iframe"]
        }
    }

    /// Native apps that host only this provider's meetings. Inside one of these
    /// any web area is ours, whatever the window is titled — the desktop shell
    /// exposes no URL and titles the window after the meeting, not the product.
    var nativeBundleIDs: Set<String> {
        switch self {
        case .googleMeet: return []
        case .microsoftTeams: return ["com.microsoft.teams2"]
        case .zoom: return ["us.zoom.xos"]
        }
    }

    /// DOM class tokens the app toggles on the active speaker's tile. Empty means
    /// "not yet discovered" — such a provider is skipped by live detection until
    /// its marker is filled in from a Debug "Watch" probe run.
    var speakingClasses: Set<String> {
        switch self {
        case .googleMeet: return ["kssMZb"]
        case .microsoftTeams:
            // The griffel style atoms Teams swaps onto the active speaker's tile
            // (discovered via the Debug "Watch" probe). Runtime `___`-prefixed
            // tokens are excluded — they change per session. `vdi-frame-occlusion`
            // is included but may also track video rendering; the border atoms are
            // the primary signal.
            return ["frwhdur", "f578s74", "f4mjgsl", "f1xul6tz", "fj20gam",
                    "f3ve9t9", "vdi-frame-occlusion"]
        case .zoom:
            // Zoom is the exception: it toggles nothing per tile, because the
            // gallery is drawn on a canvas. What it does do in speaker view is
            // promote the talker to one big frame, so the marker here is a
            // permanent class and the name inside it is who's speaking. The
            // consequence is that it keeps naming the last talker through
            // silence — harmless, since a meeting-side line only exists while
            // meeting audio is playing, and the timeline votes per line anyway.
            return ["speaker-active-container__video-frame"]
        }
    }

    /// How a marker rectangle is tied to a name label. Meet and Teams put the
    /// marker on (or around) the tile and the name at its bottom-left corner.
    /// Zoom's marker is the whole active frame, so the name it holds is the one
    /// inside it — and its controls overlay the video, which makes proximity
    /// alone pick up "End" and "Participants".
    var speakerMatch: SpeakerMatch {
        switch self {
        case .googleMeet, .microsoftTeams: return .nearestCorner
        case .zoom: return .containment
        }
    }

    /// Whether a name detected while *you* were talking is your own. On Meet it
    /// is: your tile glows with your name in your own client. On Teams your tile
    /// carries no name label, and on Zoom the active frame holds whoever else is
    /// in the call — so voting there learns a remote participant as your name,
    /// which then also suppresses their real label on meeting lines.
    var timelineNamesLocalUser: Bool {
        switch self {
        case .googleMeet: return true
        case .microsoftTeams, .zoom: return false
        }
    }

    /// A class one of the label's ancestors must carry for it to count as a
    /// participant name, for providers whose chrome sits inside the marker.
    var labelAncestorClass: String? {
        switch self {
        case .googleMeet, .microsoftTeams: return nil
        case .zoom: return "video-avatar"
        }
    }

    var label: String {
        switch self {
        case .googleMeet: return "Google Meet"
        case .microsoftTeams: return "Microsoft Teams"
        case .zoom: return "Zoom"
        }
    }
}

/// Apps that can host a meeting's web content, in the order we try them. Nothing
/// in the search is browser-specific — we walk each app's windows for a web area
/// matching a provider — so a native shell that renders the same web frontend
/// (Teams desktop) belongs here too, and only shows up if it exposes DOM classes.
let meetingHostBundleIDs = [
    "com.google.Chrome",
    "com.google.Chrome.beta",
    "com.google.Chrome.canary",
    "com.microsoft.edgemac",
    "com.brave.Browser",
    "company.thebrowser.Browser", // Arc
    "org.chromium.Chromium",
    "com.microsoft.teams2", // Teams desktop, whose window has no AXURL
    "us.zoom.xos", // Zoom desktop; unknown whether it exposes a web area at all
]

/// One observation of who was on screen as the active speaker at a moment.
struct ActiveSpeakerSample {
    let time: Date
    let name: String
    let confidence: Double
}

/// A thread-safe, time-indexed history of active-speaker observations. The
/// transcript never waits on this; it queries "who was speaking during this
/// line?" after the fact and tolerates a nil answer.
final class SpeakerTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [ActiveSpeakerSample] = []
    private let maxAge: TimeInterval = 600

    /// Fired (on an arbitrary queue) whenever a new sample lands, so the owner
    /// can trigger an async backfill of recently committed lines.
    var onSample: (@Sendable () -> Void)?

    func add(_ sample: ActiveSpeakerSample) {
        lock.lock()
        samples.append(sample)
        let cutoff = Date().addingTimeInterval(-maxAge)
        if samples.first.map({ $0.time < cutoff }) == true {
            samples.removeAll { $0.time < cutoff }
        }
        lock.unlock()
        onSample?()
    }

    func reset() {
        lock.lock(); samples.removeAll(); lock.unlock()
    }

    /// The dominant speaker during `[start, end]`. `pad` extends the window past
    /// `end` (the marker lags the audio slightly); `minShare` is the fraction of
    /// weighted observations the winner must hold; `minSamples` is how many
    /// observations must exist at all. Returns nil unless one name clearly wins.
    ///
    /// The defaults are eager (for the live on-screen guess). Persisted labels
    /// call this with a stricter share, more required samples, and a smaller pad
    /// so a fading neighbor at a turn boundary can't get written to disk.
    func dominantName(from start: Date, to end: Date,
                      pad: TimeInterval = 0.6,
                      minShare: Double = 0.5,
                      minSamples: Int = 1) -> String? {
        let paddedEnd = end.addingTimeInterval(pad)
        lock.lock()
        let window = samples.filter { $0.time >= start && $0.time <= paddedEnd }
        lock.unlock()
        guard window.count >= minSamples else { return nil }

        var weight: [String: Double] = [:]
        var counts: [String: Int] = [:]
        for sample in window {
            weight[sample.name, default: 0] += sample.confidence
            counts[sample.name, default: 0] += 1
        }
        guard let top = weight.max(by: { $0.value < $1.value }) else { return nil }
        let total = weight.values.reduce(0, +)
        guard total > 0, top.value / total >= minShare else { return nil }
        // The winner needs real support, not one stray frame, when strict.
        guard (counts[top.key] ?? 0) >= min(minSamples, 2) else { return nil }
        return top.key
    }

    /// The most recent active speaker within `window` seconds of now.
    func currentName(window: TimeInterval = 2.5) -> String? {
        let now = Date()
        return dominantName(from: now.addingTimeInterval(-window), to: now)
    }

    /// The distinct set of participants observed speaking in `[start, end]`.
    /// Used by carry-forward: an empty set (or a set holding only the previous
    /// speaker) means no *other* participant spoke during an unlabeled turn.
    func namesInWindow(from start: Date, to end: Date, pad: TimeInterval = 0.4) -> Set<String> {
        let paddedEnd = end.addingTimeInterval(pad)
        lock.lock()
        let names = Set(samples.filter { $0.time >= start && $0.time <= paddedEnd }.map(\.name))
        lock.unlock()
        return names
    }
}

/// Figures out who is talking in a browser meeting (Google Meet, Microsoft
/// Teams) entirely on device, by reading the browser's accessibility tree — no
/// pixels, no models, no network.
///
/// The web app marks the speaking participant's tile in the DOM with a class
/// (Meet's `kssMZb`, discovered by diffing the tree during speech; see
/// `MeetingApp`). We find every element carrying that class, read its on-screen
/// rectangle, and match it to the participant whose name label sits at that
/// tile's bottom-left corner. This is invariant to tile color, camera on/off,
/// and gallery vs spotlight layout — all the cases the earlier pixel-glow
/// approach couldn't handle.
///
/// It runs on its own utility queue and only ever *writes* observations into a
/// `SpeakerTimeline`; it is never on the transcript's critical path.
final class SpeakerVisionMonitor: @unchecked Sendable {
    static let shared = SpeakerVisionMonitor()

    let timeline = SpeakerTimeline()

    /// Your own display name, when the meeting app labels your tile with it
    /// (Teams does; Meet doesn't). Authoritative: no voting needed.
    var localName: String? {
        localNameLock.withLock { detectedLocalName }
    }

    /// The provider whose call we last found, so callers can tell what the
    /// timeline's names do and don't mean on this surface.
    var provider: MeetingApp? {
        localNameLock.withLock { detectedProvider }
    }

    private let localNameLock = NSLock()
    private var detectedLocalName: String?
    private var detectedProvider: MeetingApp?

    private let queue = DispatchQueue(label: "com.thread.speaker-vision", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var running = false
    private let intervalMS = 300

    /// Max distance (px) from a marker's bottom-left corner to its name label to
    /// accept the match; rejects cross-tile matches when a name is pruned.
    private let maxCornerDistance: CGFloat = 300

    #if DEBUG
    private let logger = Logger(subsystem: "com.thread.app.dev", category: "SpeakerVision")
    #endif

    // MARK: - Lifecycle

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            timer?.cancel()
            timer = nil
            running = false
            timeline.reset()
            localNameLock.withLock {
                self.detectedLocalName = nil
                self.detectedProvider = nil
            }
        }
    }

    /// One-shot manual scan (Debug menu), independent of recording.
    func analyzeOnce() {
        queue.async { [weak self] in self?.scan(manual: true) }
    }

    private func startOnQueue() {
        guard timer == nil else { return }
        running = true
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(300),
                        repeating: .milliseconds(intervalMS),
                        leeway: .milliseconds(80))
        source.setEventHandler { [weak self] in self?.scan(manual: false) }
        timer = source
        source.resume()
    }

    // MARK: - Scan

    private func scan(manual: Bool) {
        guard running || manual else { return }
        guard AXIsProcessTrusted() else {
            #if DEBUG
            if manual { logger.info("SV(ax): accessibility permission not granted") }
            #endif
            return
        }

        // Only providers whose speaking marker we've discovered can be detected.
        let providers = MeetingApp.allCases.filter { !$0.speakingClasses.isEmpty }

        var markers: [CGRect] = []
        var labels: [(name: String, rect: CGRect)] = []
        var matched: MeetingApp?
        var localName: String?

        hostLoop: for bundleID in meetingHostBundleIDs {
            guard let running = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleID).first else { continue }
            let app = AXUIElementCreateApplication(running.processIdentifier)
            // Native web hosts hand out their DOM tree only once asked; harmless
            // on browsers, which already expose it.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            var windows = Self.axElements(app, kAXWindowsAttribute as String)
            if windows.isEmpty, let focused = Self.axElement(app, kAXFocusedWindowAttribute as String) {
                windows = [focused]
            }
            for provider in providers {
                var areas: [AXUIElement] = []
                for window in windows {
                    Self.collectWebAreas(window, provider: provider,
                                         bundleID: bundleID, into: &areas)
                }
                guard !areas.isEmpty else { continue }
                matched = provider
                for area in areas {
                    Self.collectMarkersAndLabels(area, provider: provider,
                                                 markers: &markers, labels: &labels,
                                                 localName: &localName)
                }
                break hostLoop
            }
        }
        guard let provider = matched else {
            // Zoom desktop is native, so there's no web area to find and no
            // speaking marker anywhere in its tree. Fall back to elimination.
            if let name = zoomDesktopCandidate() {
                localNameLock.withLock { detectedProvider = .zoom }
                timeline.add(ActiveSpeakerSample(time: Date(), name: name,
                                                 confidence: Self.inferredConfidence))
                #if DEBUG
                logger.info("SV(ax): [Zoom desktop] inferred=\(name, privacy: .public)")
                #endif
                return
            }
            #if DEBUG
            if manual { logger.info("SV(ax): no supported meeting web area found") }
            #endif
            return
        }
        localNameLock.withLock {
            detectedProvider = provider
            if let localName { detectedLocalName = localName }
        }

        var names: [String] = []
        for marker in markers {
            let name: String?
            switch provider.speakerMatch {
            case .nearestCorner:
                let nearest = Self.nearestName(to: marker, labels: labels)
                name = (nearest?.distance ?? .greatestFiniteMagnitude) <= maxCornerDistance
                    ? nearest?.name : nil
            case .containment:
                let inside = labels.filter {
                    marker.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY))
                }
                name = Self.nearestName(to: marker, labels: inside)?.name
            }
            guard let name, !names.contains(name) else { continue }
            names.append(name)
        }

        // Multiple simultaneous speakers split confidence, so overlapping talk
        // stays ambiguous (and the strict gate leaves it unlabeled).
        let now = Date()
        let confidence = 1.0 / Double(max(1, names.count))
        for name in names {
            timeline.add(ActiveSpeakerSample(time: now, name: name, confidence: confidence))
        }

        #if DEBUG
        if manual || !names.isEmpty {
            logger.info("SV(ax): [\(matched?.label ?? "?", privacy: .public)] speakers=[\(names.joined(separator: ", "), privacy: .public)] markers=\(markers.count, privacy: .public) labels=\(labels.count, privacy: .public)")
        }
        #endif
    }

    // MARK: - Zoom desktop (no marker, so infer by elimination)

    /// Weight for a name we reasoned our way to rather than saw marked. Real
    /// marker evidence outvotes it wherever both exist.
    private static let inferredConfidence = 0.5

    private static let zoomDesktopBundleID = "us.zoom.xos"

    /// The only remote participant who could be producing the meeting audio right
    /// now, or nil when that's ambiguous.
    ///
    /// Zoom desktop names everyone in the call and reports each one's mute state,
    /// but never says who is speaking — verified against tile descriptions,
    /// geometry, ordering, and the full attribute list, with and without the
    /// screen-reader flag set. Two things can still be said for certain: a muted
    /// participant isn't the voice we're hearing, and in a two-person call there's
    /// only one person it can be. When those leave exactly one candidate, that's
    /// an answer; otherwise we stay quiet, as before.
    private func zoomDesktopCandidate() -> String? {
        zoomDesktopSnapshot()?.candidate
    }

    private func zoomDesktopSnapshot()
    -> (tiles: [String: Bool], mine: String, candidate: String?)? {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.zoomDesktopBundleID).first else {
            return nil
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // Zoom hands out its tile tree only to clients that announce themselves,
        // so ask here rather than relying on another scan having done it.
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var windows = Self.axElements(element, kAXWindowsAttribute as String)
        if windows.isEmpty,
           let focused = Self.axElement(element, kAXFocusedWindowAttribute as String) {
            windows = [focused]
        }

        var tiles: [String: Bool] = [:] // name -> unmuted anywhere
        for window in windows where Self.isZoomMeetingWindow(window) {
            Self.collectZoomTiles(window, into: &tiles)
        }
        guard !tiles.isEmpty else { return nil }

        // Your own tile carries your name like anyone else's, so it has to be
        // excluded by name. Failing that the call just looks ambiguous, which
        // costs a label rather than inventing a wrong one.
        let mine = localName ?? NSFullUserName()
        let remotes = tiles.filter { $0.key != mine }
        let candidate: String?
        if remotes.isEmpty {
            candidate = nil
        } else if remotes.count == 1 {
            candidate = remotes.first?.key
        } else {
            let unmuted = remotes.filter { $0.value }
            candidate = unmuted.count == 1 ? unmuted.first?.key : nil
        }
        return (tiles, mine, candidate)
    }

    #if DEBUG
    /// Writes what the Zoom desktop fallback currently concludes, and the tiles it
    /// based that on, to a file. Exercises the same code the live scan uses.
    func debugDumpZoomDesktop() {
        queue.async { [weak self] in
            guard let self else { return }
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("thread-zoom-desktop.txt")
            let stamp = ISO8601DateFormatter().string(from: Date())
            var text = "===== ZOOM DESKTOP \(stamp) =====\n"
            if let app = NSRunningApplication
                .runningApplications(withBundleIdentifier: Self.zoomDesktopBundleID).first {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                let windows = Self.axElements(element, kAXWindowsAttribute as String)
                text += "windows=\(windows.count)\n"
                for window in windows {
                    var found: [String: Bool] = [:]
                    Self.collectZoomTiles(window, into: &found)
                    let title = Self.axString(window, kAXTitleAttribute as String) ?? ""
                    let identifier = Self.axString(window, "AXIdentifier") ?? "<none>"
                    text += "  window \"\(title)\" id=\(identifier)"
                    text += " meetingWindow=\(Self.isZoomMeetingWindow(window)) tiles=\(found.count)\n"
                }
            } else {
                text += "zoom.us not running\n"
            }
            if let snapshot = self.zoomDesktopSnapshot() {
                text += "mine=\"\(snapshot.mine)\"\n"
                for (name, unmuted) in snapshot.tiles.sorted(by: { $0.key < $1.key }) {
                    text += "  tile \"\(name)\" \(unmuted ? "unmuted" : "muted")\n"
                }
                text += "candidate=\(snapshot.candidate.map { "\"\($0)\"" } ?? "none")\n"
            } else {
                text += "no Zoom desktop meeting window with participant tiles\n"
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            } else {
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
    #endif

    private static func isZoomMeetingWindow(_ window: AXUIElement) -> Bool {
        if let identifier = axString(window, "AXIdentifier") {
            return identifier == "zm.meeting.window.main"
        }
        return axString(window, kAXTitleAttribute as String) == "Zoom Meeting"
    }

    /// Zoom describes each participant tile as "Paul Grant, Computer audio muted,
    /// Video off", so the name and the audio state come from one string.
    private static func collectZoomTiles(_ root: AXUIElement, into result: inout [String: Bool]) {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < 4_000 {
            let (element, depth) = queue[index]
            index += 1
            let description = axString(element, kAXDescriptionAttribute as String) ?? ""
            if description.contains(", Computer audio ") {
                let parts = description.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if let name = parts.first, !name.isEmpty {
                    let unmuted = description.contains("Computer audio unmuted")
                    result[name] = (result[name] ?? false) || unmuted
                }
            }
            guard depth < 40 else { continue }
            for child in axElements(element, kAXChildrenAttribute as String) {
                queue.append((child, depth + 1))
            }
        }
    }

    // MARK: - Meeting DOM traversal

    /// Whether one of `signatures` appears in a class list near the top of this
    /// web area. Kept shallow so testing an unrelated page costs almost nothing.
    private static func hasDOMSignature(_ webArea: AXUIElement, _ signatures: [String]) -> Bool {
        guard !signatures.isEmpty else { return false }
        var queue: [(AXUIElement, Int)] = [(webArea, 0)]
        var index = 0
        while index < queue.count, index < 400 {
            let (element, depth) = queue[index]
            index += 1
            if let classList = axString(element, "AXDOMClassList") {
                let tokens = classList.split(separator: " ").map(String.init)
                if tokens.contains(where: signatures.contains) { return true }
            }
            guard depth < 6 else { continue }
            for child in axElements(element, kAXChildrenAttribute as String) {
                queue.append((child, depth + 1))
            }
        }
        return false
    }

    private static func collectWebAreas(_ root: AXUIElement, provider: MeetingApp,
                                        bundleID: String,
                                        into result: inout [AXUIElement]) {
        let isNativeHost = provider.nativeBundleIDs.contains(bundleID)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < 8_000 {
            let (element, depth) = queue[index]
            index += 1
            if axString(element, kAXRoleAttribute as String) == "AXWebArea" {
                let url = axString(element, "AXURL") ?? ""
                let title = (axString(element, kAXTitleAttribute as String) ?? "").lowercased()
                if isNativeHost
                    || provider.urlSubstrings.contains(where: url.contains)
                    || provider.titleHints.contains(where: title.contains)
                    || hasDOMSignature(element, provider.domSignatures) {
                    result.append(element)
                }
                continue // don't descend into a web area while searching for it
            }
            guard depth < 30 else { continue }
            for child in axElements(element, kAXChildrenAttribute as String) {
                queue.append((child, depth + 1))
            }
        }
    }

    /// A single pass over a meeting web area collecting speaking-marker
    /// rectangles and participant name-label rectangles.
    private static func collectMarkersAndLabels(
        _ root: AXUIElement, provider: MeetingApp,
        markers: inout [CGRect], labels: inout [(name: String, rect: CGRect)],
        localName: inout String?
    ) {
        let speaking = provider.speakingClasses
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        while index < queue.count, index < 8_000 {
            let (element, depth) = queue[index]
            index += 1

            if let classList = axString(element, "AXDOMClassList") {
                let tokens = Set(classList.split(separator: " ").map(String.init))
                if !tokens.isDisjoint(with: speaking), let rect = frame(element), rect.width > 0 {
                    markers.append(rect)
                }
            }

            let role = axString(element, kAXRoleAttribute as String) ?? ""
            let text = firstNonEmpty(
                axString(element, kAXDescriptionAttribute as String),
                axString(element, kAXTitleAttribute as String),
                axString(element, kAXValueAttribute as String)
            )
            if let name = participantName(text, provider: provider, role: role),
               let rect = frame(element), rect.width > 0,
               provider.labelAncestorClass.map({ hasAncestorClass(element, $0) }) ?? true {
                labels.append((name, rect))
            }
            if provider == .microsoftTeams, let mine = Self.selfTileName(text) {
                localName = mine
            }

            guard depth < 40 else { continue }
            for child in axElements(element, kAXChildrenAttribute as String) {
                queue.append((child, depth + 1))
            }
        }
    }

    /// Whether any class list on this element's ancestors contains `substring`.
    private static func hasAncestorClass(_ element: AXUIElement, _ substring: String,
                                        levels: Int = 5) -> Bool {
        var current: AXUIElement? = element
        var level = 0
        while let node = current, level < levels {
            if let classList = axString(node, "AXDOMClassList"), classList.contains(substring) {
                return true
            }
            current = axElement(node, kAXParentAttribute as String)
            level += 1
        }
        return false
    }

    /// The name label nearest the marker's BOTTOM-LEFT corner. Meet anchors the
    /// name at the tile's bottom-left, and the marker shares the tile, so corner
    /// proximity maps the indicator to its person even when the marker is the
    /// whole spotlighted tile (whose center would sit closer to another tile).
    private static func nearestName(
        to marker: CGRect, labels: [(name: String, rect: CGRect)]
    ) -> (name: String, distance: CGFloat)? {
        let corner = CGPoint(x: marker.minX, y: marker.maxY) // AX origin is top-left
        var best: (name: String, distance: CGFloat)?
        for label in labels {
            let center = CGPoint(x: label.rect.midX, y: label.rect.midY)
            let distance = hypot(corner.x - center.x, corner.y - center.y)
            if best == nil || distance < best!.distance { best = (label.name, distance) }
        }
        return best
    }

    /// Your own display name as Teams writes it on your tile: "Myself video,
    /// James Barker, Unmuted, Has context menu". Knowing it outright beats voting
    /// on whichever name glowed while you talked — and on Teams that vote is
    /// actively wrong, since your tile carries no name label of its own, so a
    /// marker on it resolves to whoever's label sits nearest.
    private static func selfTileName(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("myself") else { return nil }
        let fields = text.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard fields.count >= 2 else { return nil }
        let name = fields[1]
        guard name.count >= 2, name.count <= 40,
              (1...4).contains(name.split(separator: " ").count),
              name.rangeOfCharacter(from: .decimalDigits) == nil,
              name.rangeOfCharacter(from: .letters) != nil else { return nil }
        return name
    }

    /// Normalizes an element's text into a participant display name, or nil if it
    /// isn't one. Meet names are 2–3 capitalized words (its chrome — "Turn on
    /// captions" — has lowercased words). Teams appends "(Unverified)"/"(EXT)"
    /// and allows lowercase handles ("itai"), so we strip a trailing parenthetical
    /// and require a text node: its app bar and meeting toolbar are full of
    /// name-shaped button labels ("Apps", "Notes", "Calendar") that would
    /// otherwise compete with real participants for the nearest-label match.
    private static func participantName(_ raw: String, provider: MeetingApp,
                                        role: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n") else { return nil }
        if provider == .microsoftTeams, role != "AXStaticText" { return nil }

        if provider == .microsoftTeams, let paren = text.range(of: " (", options: .backwards) {
            text = String(text[text.startIndex..<paren.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard text.count >= 2, text.count <= 40 else { return nil }
        guard text.rangeOfCharacter(from: .letters) != nil else { return nil }
        let lower = text.lowercased()
        if lower.contains("meet -") || lower.contains("gemini") { return nil }
        let tokens = text.split(separator: " ").map(String.init)

        switch provider {
        case .googleMeet:
            guard (2...3).contains(tokens.count) else { return nil }
            for token in tokens {
                guard let first = token.first, first.isUppercase else { return nil }
            }
        case .zoom:
            // Starting point only: same shape as Teams (text nodes, short names,
            // no digits), to be tightened once a probe shows what Zoom exposes.
            guard role == "AXStaticText" else { return nil }
            guard (1...4).contains(tokens.count) else { return nil }
            guard text.rangeOfCharacter(from: .decimalDigits) == nil else { return nil }
        case .microsoftTeams:
            guard (1...4).contains(tokens.count) else { return nil }
            guard text.rangeOfCharacter(from: .decimalDigits) == nil else { return nil }
            let controls: Set<String> = [
                "mic", "camera", "chat", "people", "raise", "react", "view", "more",
                "leave", "share", "mute", "unmute", "encryption", "status",
                "recording", "transcription", "content", "reactions", "hand",
                "background", "captions", "shared",
            ]
            if tokens.contains(where: { controls.contains($0.lowercased()) }) { return nil }
        }
        return text
    }

    // MARK: - AX helpers

    private static func frame(_ element: AXUIElement) -> CGRect? {
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

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func axElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let a = value as? [String] { return a.joined(separator: " ") }
        return nil
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for value in values {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return ""
    }
}
