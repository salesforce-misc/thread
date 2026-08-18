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
import AVFoundation
#if DEBUG
import OSLog
#endif

/// Lock-guarded because meeting detection runs on a utility queue while audio
/// taps read the decision from Core Audio's realtime callback.
final class MicrophoneTranscriptionGate: @unchecked Sendable {
    enum Decision: Equatable {
        case allow
        case hold
        case suppress
    }

    private let lock = NSLock()
    private let feed: @Sendable (AVAudioPCMBuffer) -> Void
    private var decision: Decision = .allow
    private var heldBuffers: [AVAudioPCMBuffer] = []
    private var heldDuration: TimeInterval = 0
    private let maximumHeldDuration: TimeInterval = 1.25

    init(feed: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.feed = feed
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = decision
        if current == .hold,
           heldDuration < maximumHeldDuration,
           let copy = Self.copy(buffer) {
            heldBuffers.append(copy)
            heldDuration += TimeInterval(copy.frameLength)
                / copy.format.sampleRate
        }
        lock.unlock()

        if current == .allow {
            feed(buffer)
        }
    }

    func setDecision(_ value: Decision) {
        lock.lock()
        let shouldRelease = decision == .hold && value == .allow
        if !shouldRelease, value != decision {
            heldBuffers.removeAll(keepingCapacity: true)
            heldDuration = 0
            decision = value
        }
        lock.unlock()

        guard shouldRelease else { return }

        // Keep the gate in `.hold` while draining. Any live buffers arriving
        // during release join the next batch, so they cannot overtake the audio
        // captured just before the decision became known.
        while true {
            lock.lock()
            let batch = heldBuffers
            heldBuffers.removeAll(keepingCapacity: true)
            heldDuration = 0
            if batch.isEmpty {
                decision = .allow
                lock.unlock()
                return
            }
            lock.unlock()
            for buffer in batch {
                feed(buffer)
            }
        }
    }

    func reset() {
        lock.lock()
        decision = .allow
        heldBuffers.removeAll(keepingCapacity: true)
        heldDuration = 0
        lock.unlock()
    }

    private static func copy(
        _ source: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        destination.frameLength = source.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else {
            return nil
        }
        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData else {
                return nil
            }
            let byteCount = min(
                Int(sourceBuffers[index].mDataByteSize),
                Int(destinationBuffers[index].mDataByteSize)
            )
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = UInt32(byteCount)
        }
        return destination
    }
}

/// Follows Google Meet, Zoom Web, Microsoft Teams Web, and the Zoom/Teams apps
/// through macOS Accessibility. It never clicks or modifies another app.
/// Unknown/no meeting always fails open so Thread does not silently lose speech.
final class BrowserMeetingMuteMonitor: @unchecked Sendable {
    private enum Provider {
        case googleMeet
        case zoomWeb
        case teamsWeb
        case zoomDesktop
        case teamsDesktop
    }

    private struct WindowResult {
        var googleMeetTabCount = 0
        var zoomNamedTabCount = 0
        var teamsNamedTabCount = 0
        var microphoneRecordingTabSignatures: Set<String> = []
        var googleMuteStates: Set<Bool> = []
        var zoomMuteStates: Set<Bool> = []
        var teamsMuteStates: Set<Bool> = []
        var foundTeamsMuteControl = false
        var foundTeamsUnmuteControl = false

        var hasMeeting: Bool {
            googleMeetTabCount > 0
                || zoomNamedTabCount > 0
                || teamsNamedTabCount > 0
                || !googleMuteStates.isEmpty
                || !zoomMuteStates.isEmpty
                || !teamsMuteStates.isEmpty
        }
    }

    private struct ZoomDesktopResult {
        var meetingHostCount = 0
        var muteStates: Set<Bool> = []

        var isPresent: Bool {
            meetingHostCount > 0 || !muteStates.isEmpty
        }
    }

    private struct TeamsDesktopResult {
        var meetingWindowCount = 0
        var muteStates: Set<Bool> = []

        var isPresent: Bool {
            meetingWindowCount > 0 || !muteStates.isEmpty
        }
    }

    private let gate: MicrophoneTranscriptionGate
    private let queue = DispatchQueue(
        label: "com.thread.google-meet-mute",
        qos: .utility
    )
    private var timer: DispatchSourceTimer?
    private var nextScan = DispatchTime.now()
    private var meetingPresent = false
    private var activeProvider: Provider?
    private var zoomTabSignature: String?
    private var teamsTabSignature: String?
    private var lastKnownMuted: Bool?
    private var recordingActive = false
    private var currentDecision: MicrophoneTranscriptionGate.Decision = .allow
    private var lastScanAt: DispatchTime?
    private var holdGeneration = 0
    private var holdTimedOut = false

    #if DEBUG
    private let logger = Logger(
        subsystem: "com.thread.app.dev",
        category: "MeetMute"
    )
    #endif

    init(gate: MicrophoneTranscriptionGate) {
        self.gate = gate
    }

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func beginRecording() {
        queue.async { [weak self] in
            guard let self else { return }
            recordingActive = true
            holdTimedOut = false

            if let lastScanAt,
               DispatchTime.now().uptimeNanoseconds
                - lastScanAt.uptimeNanoseconds
                <= 4_000_000_000 {
                applyDecision(currentDecision)
                if currentDecision == .hold {
                    scheduleHoldTimeout()
                }
                return
            }

            currentDecision = .hold
            gate.setDecision(.hold)
            scheduleHoldTimeout()
            scanChrome()
        }
    }

    func endRecording() {
        queue.async { [weak self] in
            guard let self else { return }
            recordingActive = false
            holdGeneration += 1
            holdTimedOut = false
            gate.reset()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            timer?.cancel()
            timer = nil
            recordingActive = false
            holdGeneration += 1
            gate.reset()
            clearMeeting()
        }
    }

    private func startOnQueue() {
        guard timer == nil else { return }
        nextScan = .now()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now(),
            repeating: .milliseconds(500),
            leeway: .milliseconds(100)
        )
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = source
        source.resume()
    }

    /// Accessibility is the one unavoidable user-facing requirement. Explain it
    /// once before asking macOS; declining leaves existing transcription intact.
    @MainActor
    func requestAccessIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let key = AppSettings.browserMuteAccessibilityPromptedKey
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Follow meeting mute"
        alert.informativeText =
            "Allow Accessibility so Thread can automatically stop transcribing "
            + "your microphone when you mute yourself in Google Meet, Zoom "
            + "Web, Microsoft Teams Web, or the Zoom and Microsoft Teams apps. "
            + "Thread only reads meeting controls and never clicks them."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func tick() {
        let now = DispatchTime.now()
        guard now >= nextScan else { return }

        let frontmostBundleID =
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let trackedAppIsFrontmost =
            frontmostBundleID == "com.google.Chrome"
            || frontmostBundleID == "us.zoom.xos"
            || frontmostBundleID == "com.microsoft.teams2"
        let delay: DispatchTimeInterval
        if trackedAppIsFrontmost {
            delay = .milliseconds(500)
        } else if meetingPresent {
            delay = .seconds(1)
        } else {
            delay = .seconds(3)
        }
        nextScan = now + delay
        scanChrome()
    }

    private func scanChrome() {
        defer { lastScanAt = .now() }
        guard AXIsProcessTrusted() else {
            clearMeeting()
            return
        }

        var results: [WindowResult] = []
        if let chrome = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.google.Chrome"
        ).first {
            let app = AXUIElementCreateApplication(chrome.processIdentifier)
            let allWindows = elementArrayAttribute(
                app,
                kAXWindowsAttribute as String
            )
            let focused = elementAttribute(
                app,
                kAXFocusedWindowAttribute as String
            )
            let windows: [AXUIElement]
            if !meetingPresent, let focused {
                // Before a meeting is known, Chrome's focused window is enough
                // to discover one and avoids walking every idle browser window.
                windows = [focused]
            } else if !allWindows.isEmpty {
                windows = allWindows
            } else if let focused {
                windows = [focused]
            } else {
                windows = []
            }
            results = windows.map(scanWindow)
        }

        let zoomDesktop = scanZoomDesktop()
        let teamsDesktop = scanTeamsDesktop()
        let googleTabs = results.reduce(0) { $0 + $1.googleMeetTabCount }
        let zoomTabs = results.reduce(0) { $0 + $1.zoomNamedTabCount }
        let teamsTabs = results.reduce(0) { $0 + $1.teamsNamedTabCount }
        let microphoneTabSignatures = results.reduce(into: Set<String>()) {
            $0.formUnion($1.microphoneRecordingTabSignatures)
        }
        let microphoneTabs = microphoneTabSignatures.count
        let meetingWindows = results.filter(\.hasMeeting).count
        let googleStates = results.reduce(into: Set<Bool>()) {
            $0.formUnion($1.googleMuteStates)
        }
        let zoomStates = results.reduce(into: Set<Bool>()) {
            $0.formUnion($1.zoomMuteStates)
        }
        let teamsStates = results.reduce(into: Set<Bool>()) {
            $0.formUnion($1.teamsMuteStates)
        }

        // Multiple live meetings/tabs are intentionally unsupported. An
        // invisible automatic feature must never guess which meeting to follow.
        let matchingZoomWebTab =
            zoomTabSignature.map(microphoneTabSignatures.contains) ?? false
        let normalizedTeamsSignatures = Set(
            microphoneTabSignatures.map(normalizedTeamsTabSignature)
        )
        let matchingTeamsWebTab =
            teamsTabSignature.map(normalizedTeamsSignatures.contains) ?? false
        let googlePresent = googleTabs > 0 || !googleStates.isEmpty
        let zoomWebPresent =
            zoomTabs > 0
            || !zoomStates.isEmpty
            || (activeProvider == .zoomWeb && matchingZoomWebTab)
        let teamsWebPresent =
            teamsTabs > 0
            || !teamsStates.isEmpty
            || (activeProvider == .teamsWeb && matchingTeamsWebTab)
        let zoomDesktopPresent = zoomDesktop.isPresent
        let teamsDesktopPresent = teamsDesktop.isPresent
        let providerCount = [
            googlePresent,
            zoomWebPresent,
            teamsWebPresent,
            zoomDesktopPresent,
            teamsDesktopPresent
        ].filter { $0 }.count
        guard googleTabs <= 1,
              zoomTabs <= 1,
              teamsTabs <= 1,
              microphoneTabs <= 1,
              meetingWindows <= 1,
              googleStates.count <= 1,
              zoomStates.count <= 1,
              teamsStates.count <= 1,
              zoomDesktop.meetingHostCount <= 1,
              zoomDesktop.muteStates.count <= 1,
              teamsDesktop.meetingWindowCount <= 1,
              teamsDesktop.muteStates.count <= 1,
              providerCount <= 1 else {
            markAmbiguous()
            return
        }

        if let muted = googleStates.first {
            updateKnownState(.googleMeet, muted: muted)
        } else if let muted = zoomStates.first {
            updateKnownState(
                .zoomWeb,
                muted: muted,
                browserSignature: microphoneTabs == 1
                    ? microphoneTabSignatures.first
                    : nil
            )
        } else if let muted = teamsStates.first {
            updateKnownState(
                .teamsWeb,
                muted: muted,
                browserSignature: microphoneTabs == 1
                    ? microphoneTabSignatures.first
                    : nil
            )
        } else if let muted = zoomDesktop.muteStates.first {
            updateKnownState(.zoomDesktop, muted: muted)
        } else if let muted = teamsDesktop.muteStates.first {
            updateKnownState(.teamsDesktop, muted: muted)
        } else if activeProvider == .googleMeet,
                  googleTabs == 1,
                  googlePresent {
            // Web controls disappear when another tab is selected. Keep the
            // last state only while Chrome still exposes the live meeting tab.
            meetingPresent = true
            applyDecision(
                lastKnownMuted == true ? .suppress : .allow,
                state: "google-background"
            )
        } else if activeProvider == .zoomWeb,
                  zoomWebPresent,
                  matchingZoomWebTab {
            meetingPresent = true
            applyDecision(
                lastKnownMuted == true ? .suppress : .allow,
                state: "zoom-background"
            )
        } else if activeProvider == .teamsWeb,
                  teamsWebPresent,
                  matchingTeamsWebTab {
            meetingPresent = true
            applyDecision(
                lastKnownMuted == true ? .suppress : .allow,
                state: "teams-background"
            )
        } else if activeProvider == .zoomDesktop,
                  zoomDesktopPresent {
            // Zoom removes its mute control when the toolbar hides. CptHost
            // remains alive for the call and disappears when the call ends.
            meetingPresent = true
            applyDecision(
                lastKnownMuted == true ? .suppress : .allow,
                state: "zoom-desktop-background"
            )
        } else if activeProvider == .teamsDesktop,
                  teamsDesktopPresent {
            // Teams can temporarily hide its meeting controls while the call
            // window remains present. Preserve the last definitive state.
            meetingPresent = true
            applyDecision(
                lastKnownMuted == true ? .suppress : .allow,
                state: "teams-desktop-background"
            )
        } else if googlePresent
                    || zoomWebPresent
                    || teamsWebPresent
                    || zoomDesktopPresent
                    || teamsDesktopPresent {
            markUnknown()
        } else {
            clearMeeting()
        }

    }

    private func updateKnownState(
        _ provider: Provider,
        muted: Bool,
        browserSignature: String? = nil
    ) {
        activeProvider = provider
        zoomTabSignature =
            provider == .zoomWeb ? browserSignature : nil
        teamsTabSignature =
            provider == .teamsWeb
                ? browserSignature.map(normalizedTeamsTabSignature)
                : nil
        meetingPresent = true
        lastKnownMuted = muted
        let prefix: String
        switch provider {
        case .googleMeet:
            prefix = "google"
        case .zoomWeb:
            prefix = "zoom-web"
        case .teamsWeb:
            prefix = "teams-web"
        case .zoomDesktop:
            prefix = "zoom-desktop"
        case .teamsDesktop:
            prefix = "teams-desktop"
        }
        applyDecision(
            muted ? .suppress : .allow,
            state: "\(prefix)-\(muted ? "muted" : "unmuted")"
        )
    }

    private func markAmbiguous() {
        meetingPresent = true
        activeProvider = nil
        zoomTabSignature = nil
        teamsTabSignature = nil
        lastKnownMuted = nil
        applyDecision(.allow, state: "ambiguous")
    }

    private func markUnknown() {
        meetingPresent = true
        activeProvider = nil
        zoomTabSignature = nil
        teamsTabSignature = nil
        lastKnownMuted = nil
        applyDecision(.hold, state: "unknown")
    }

    private func scanWindow(_ root: AXUIElement) -> WindowResult {
        let maximumNodes = 2_500
        var result = WindowResult()
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var seen: [CFHashCode: [AXUIElement]] = [:]

        while index < queue.count, index < maximumNodes {
            let (element, depth) = queue[index]
            index += 1

            let identity = CFHash(element)
            if seen[identity, default: []].contains(where: { CFEqual($0, element) }) {
                continue
            }
            seen[identity, default: []].append(element)

            let role = stringAttribute(element, kAXRoleAttribute as String)
            let description = stringAttribute(
                element,
                kAXDescriptionAttribute as String
            )
            let title = stringAttribute(element, kAXTitleAttribute as String)

            if role == "AXButton" {
                let normalizedDescription = description?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                switch normalizedDescription {
                case "turn on microphone":
                    result.googleMuteStates.insert(true)
                case "turn off microphone":
                    result.googleMuteStates.insert(false)
                case "unmute my microphone", "join audio":
                    result.zoomMuteStates.insert(true)
                case "mute my microphone":
                    result.zoomMuteStates.insert(false)
                default:
                    break
                }

                // Teams' self-mute control exposes the action that clicking it
                // would perform. "Unmute" is definitive; "Mute" is used only
                // when no Unmute control exists because participant controls
                // can also expose Mute actions.
                if isTeamsSelfMuteAction(
                    normalizedDescription,
                    action: "unmute"
                ) {
                    result.foundTeamsUnmuteControl = true
                } else if isTeamsSelfMuteAction(
                    normalizedDescription,
                    action: "mute"
                ) {
                    result.foundTeamsMuteControl = true
                }
            }

            if role == "AXRadioButton" {
                let tabText = [title, description]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .lowercased()
                if tabText.contains("microphone recording") {
                    result.microphoneRecordingTabSignatures.insert(
                        microphoneTabSignature(tabText)
                    )
                }
                if (tabText.contains("meet -")
                    || tabText.contains("meet.google.com"))
                    && tabText.contains("microphone recording") {
                    result.googleMeetTabCount += 1
                }
                if (tabText.contains("zoom") || tabText.contains("zoom.us"))
                    && tabText.contains("microphone recording") {
                    result.zoomNamedTabCount += 1
                }
                if (tabText.contains("microsoft teams")
                    || tabText.contains("teams.microsoft")
                    || tabText.contains("teams.live"))
                    && tabText.contains("microphone recording") {
                    result.teamsNamedTabCount += 1
                }
            }

            // Breadth-first traversal sees Chrome's shallow tab strip before
            // deeper web controls. Once both signals are found, the remaining
            // meeting DOM cannot change this window's answer.
            let foundGoogle =
                result.googleMeetTabCount == 1
                && result.googleMuteStates.count == 1
            let foundZoom =
                result.microphoneRecordingTabSignatures.count == 1
                && result.zoomMuteStates.count == 1
            let foundTeams =
                result.teamsNamedTabCount == 1
                && (
                    result.foundTeamsUnmuteControl
                        || result.foundTeamsMuteControl
                )
            if foundGoogle
                || foundZoom
                || foundTeams
                || result.googleMeetTabCount > 1
                || result.zoomNamedTabCount > 1
                || result.microphoneRecordingTabSignatures.count > 1
                || result.googleMuteStates.count > 1
                || result.zoomMuteStates.count > 1 {
                break
            }

            guard depth < 28 else { continue }
            for child in elementArrayAttribute(
                element,
                kAXChildrenAttribute as String
            ) {
                queue.append((child, depth + 1))
            }
        }

        if result.teamsNamedTabCount == 1 {
            if result.foundTeamsUnmuteControl {
                result.teamsMuteStates.insert(true)
            } else if result.foundTeamsMuteControl {
                result.teamsMuteStates.insert(false)
            }
        }
        return result
    }

    private func isTeamsSelfMuteAction(
        _ description: String?,
        action: String
    ) -> Bool {
        guard let description else { return false }
        if description == action { return true }
        return [
            "\(action) (",
            "\(action) microphone",
            "\(action) your microphone",
            "\(action) mic"
        ].contains(where: description.hasPrefix)
    }

    private func normalizedTeamsTabSignature(_ signature: String) -> String {
        let trimmed = signature.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.first == "(",
              let close = trimmed.firstIndex(of: ")") else {
            return trimmed
        }
        let countStart = trimmed.index(after: trimmed.startIndex)
        let count = trimmed[countStart..<close]
        guard !count.isEmpty, count.allSatisfy(\.isNumber) else {
            return trimmed
        }
        return trimmed[trimmed.index(after: close)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func microphoneTabSignature(_ tabText: String) -> String {
        guard let marker = tabText.range(of: "microphone recording") else {
            return tabText
        }
        return tabText[..<marker.lowerBound]
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—"))
    }

    private func scanTeamsDesktop() -> TeamsDesktopResult {
        var result = TeamsDesktopResult()
        let apps = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.microsoft.teams2"
        )
        for runningApp in apps {
            let app = AXUIElementCreateApplication(
                runningApp.processIdentifier
            )
            let windows = elementArrayAttribute(
                app,
                kAXWindowsAttribute as String
            )
            guard windows.count > 1
                    || activeProvider == .teamsDesktop else {
                continue
            }
            if activeProvider == .teamsDesktop, windows.count > 1 {
                result.meetingWindowCount = 1
            }
            for window in windows {
                let windowResult = scanTeamsDesktopWindow(in: window)
                if windowResult.isMeetingWindow {
                    // A Teams call can expose the same call controls in more
                    // than one auxiliary window. Treat that as one provider,
                    // not multiple simultaneous meetings.
                    result.meetingWindowCount = 1
                }
                result.muteStates.formUnion(windowResult.muteStates)
            }
        }
        return result
    }

    private func scanTeamsDesktopWindow(
        in root: AXUIElement
    ) -> (isMeetingWindow: Bool, muteStates: Set<Bool>) {
        let maximumNodes = 3_000
        var foundLeaveControl = false
        var foundMuteControl = false
        var foundUnmuteControl = false
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var seen: [CFHashCode: [AXUIElement]] = [:]

        while index < queue.count, index < maximumNodes {
            let (element, depth) = queue[index]
            index += 1
            let identity = CFHash(element)
            if seen[identity, default: []].contains(where: {
                CFEqual($0, element)
            }) {
                continue
            }
            seen[identity, default: []].append(element)

            if stringAttribute(
                element,
                kAXRoleAttribute as String
            ) == "AXButton" {
                let description = stringAttribute(
                    element,
                    kAXDescriptionAttribute as String
                )?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if isTeamsSelfMuteAction(
                    description,
                    action: "unmute"
                ) {
                    foundUnmuteControl = true
                } else if isTeamsSelfMuteAction(
                    description,
                    action: "mute"
                ) {
                    foundMuteControl = true
                }
                if description == "leave"
                    || description?.hasPrefix("leave (") == true
                    || description == "hang up"
                    || description == "end call" {
                    foundLeaveControl = true
                }
            }

            if foundLeaveControl
                && (foundUnmuteControl || foundMuteControl) {
                break
            }
            guard depth < 28 else { continue }
            for child in elementArrayAttribute(
                element,
                kAXChildrenAttribute as String
            ) {
                queue.append((child, depth + 1))
            }
        }
        let isMeetingWindow =
            foundLeaveControl
            && (foundUnmuteControl || foundMuteControl)
        var states: Set<Bool> = []
        if isMeetingWindow {
            if foundUnmuteControl {
                states.insert(true)
            } else if foundMuteControl {
                states.insert(false)
            }
        }
        return (isMeetingWindow, states)
    }

    private func scanZoomDesktop() -> ZoomDesktopResult {
        var result = ZoomDesktopResult()
        let apps = NSWorkspace.shared.runningApplications
        result.meetingHostCount = apps.filter {
            $0.bundleIdentifier == "us.zoom.CptHost"
        }.count

        for app in apps where app.bundleIdentifier == "us.zoom.xos" {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            var windows = elementArrayAttribute(
                root,
                kAXWindowsAttribute as String
            )
            if windows.isEmpty,
               let focused = elementAttribute(
                   root,
                   kAXFocusedWindowAttribute as String
               ) {
                windows = [focused]
            }
            for window in windows {
                result.muteStates.formUnion(
                    scanZoomDesktopWindow(window)
                )
            }
        }
        return result
    }

    private func scanZoomDesktopWindow(
        _ root: AXUIElement
    ) -> Set<Bool> {
        var states: Set<Bool> = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var seen: [CFHashCode: [AXUIElement]] = [:]

        while index < queue.count, index < 2_500 {
            let (element, depth) = queue[index]
            index += 1
            let identity = CFHash(element)
            if seen[identity, default: []].contains(
                where: { CFEqual($0, element) }
            ) {
                continue
            }
            seen[identity, default: []].append(element)

            if stringAttribute(
                element,
                kAXRoleAttribute as String
            ) == "AXButton" {
                switch stringAttribute(
                    element,
                    kAXDescriptionAttribute as String
                )?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() {
                case "unmute my audio":
                    states.insert(true)
                case "mute my audio":
                    states.insert(false)
                default:
                    break
                }
            }

            if states.count > 1 {
                break
            }

            guard depth < 28 else { continue }
            for child in elementArrayAttribute(
                element,
                kAXChildrenAttribute as String
            ) {
                queue.append((child, depth + 1))
            }
        }
        return states
    }

    private func clearMeeting() {
        meetingPresent = false
        activeProvider = nil
        zoomTabSignature = nil
        teamsTabSignature = nil
        lastKnownMuted = nil
        applyDecision(.allow, state: "none")
    }

    private func applyDecision(
        _ decision: MicrophoneTranscriptionGate.Decision,
        state: String? = nil
    ) {
        let changed = decision != currentDecision
        if changed {
            currentDecision = decision
            holdTimedOut = false
            holdGeneration += 1
        }

        if recordingActive {
            switch decision {
            case .allow, .suppress:
                gate.setDecision(decision)
            case .hold:
                gate.setDecision(holdTimedOut ? .allow : .hold)
                if changed {
                    scheduleHoldTimeout()
                }
            }
        }

        #if DEBUG
        if changed, let state {
            logger.info(
                "STATE value=\(state, privacy: .public) decision=\(String(describing: decision), privacy: .public)"
            )
        }
        #endif
    }

    private func scheduleHoldTimeout() {
        holdGeneration += 1
        let generation = holdGeneration
        queue.asyncAfter(deadline: .now() + .seconds(1)) { [weak self] in
            guard let self,
                  recordingActive,
                  currentDecision == .hold,
                  generation == holdGeneration else { return }
            holdTimedOut = true
            gate.setDecision(.allow)
        }
    }

    private func elementAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return value as! AXUIElement
    }

    private func elementArrayAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let array = value as? [AXUIElement] else { return [] }
        return array
    }

    private func stringAttribute(
        _ element: AXUIElement,
        _ attribute: String
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
              let value else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
