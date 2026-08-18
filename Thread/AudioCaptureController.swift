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
import AVFoundation
import ScreenCaptureKit
import Speech
import Combine
import CoreAudio
import AppKit
import QuartzCore

enum Speaker: String {
    case you = "You"
    case meeting = "Meeting"
}

/// A lock-guarded handle to a transcriber so realtime audio callbacks (mic tap,
/// SCStream) can feed it directly off the main actor. `feed` is already safe to
/// call from any thread; this just makes swapping/clearing the reference safe.
final class TranscriberBox: @unchecked Sendable {
    private let lock = NSLock()
    private var transcriber: MeetingTranscriber?

    func set(_ value: MeetingTranscriber?) {
        lock.lock(); transcriber = value; lock.unlock()
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let t = transcriber; lock.unlock()
        t?.feed(buffer)
    }
}

/// Thread-safe count of mic buffers received, so the watchdog can tell whether
/// the tap is actually delivering audio.
final class MicBufferCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func tick() { lock.lock(); _count += 1; lock.unlock() }
}

struct TranscriptEntry: Identifiable {
    let id = UUID()
    let speaker: Speaker
    var text: String
    var date: Date
    /// Resolved display name for a `.meeting` turn, from on-screen speaker
    /// detection. Nil until (or unless) detection attributes it. Never set for
    /// `.you` (that's always the local user).
    var speakerName: String? = nil
    /// When this turn's audio began, used to query the speaker timeline over the
    /// turn's real span rather than just its finalization instant.
    var startedAt: Date = Date()
}

@MainActor
final class AudioCaptureController: NSObject, ObservableObject {

    @Published var isRunning = false
    @Published var isStarting = false
    @Published var statusMessage = "Idle"

    var isActive: Bool { isRunning || isStarting }
    private var abortStart = false
    @Published var entries: [TranscriptEntry] = []
    @Published var youVolatile = ""
    @Published var meetingVolatile = ""
    /// Live best-guess name for the in-progress meeting draft (inline prefix).
    @Published var meetingVolatileSpeaker: String?
    /// The local user's on-screen name. Teams labels your own tile with it;
    /// on Meet it's learned from whichever tile glowed while *you* talked.
    /// Applied to every "You" turn once known, so your bubbles read your name.
    @Published var localUserName: String?
    @Published private(set) var transcriptRevision = 0
    /// Free-form user notes (Markdown) for the in-progress session.
    @Published var notes = ""

    /// Title for the in-progress session.
    var currentTitle = ""
    /// When the current recording started (for the transcript segment's range).
    private(set) var startedAt: Date?
    /// Set when this recording should be appended into an existing saved session
    /// (rather than creating a new file). Holds the target file and the file's
    /// transcript markdown captured at append-start, so autosave/finish can
    /// rebuild it as `base + new segment`. Cleared when capture finishes.
    var appendTarget: URL?
    var appendBaseTranscript: String?
    /// Called when a session ends with content, so it can be persisted. Fires
    /// before the transcript is cleared. Args: title, entries, notes.
    var onFinish: ((String, [TranscriptEntry], String) -> Void)?
    /// Called periodically while recording so the in-progress transcript can be
    /// autosaved (a crash/quit then loses only the last few seconds).
    var onAutosave: ((String, [TranscriptEntry], String) -> Void)?
    /// Applies learned glossary terms to transcript text as it arrives, so
    /// already-known proper nouns (e.g. "Taksina") self-correct live. Set by the
    /// view; a no-op when nil.
    var correct: (@MainActor (String) -> String)?
    private var autosaveTask: Task<Void, Never>?

    private let micEngine = AVAudioEngine()
    private var micTranscriber: MeetingTranscriber?
    private var systemTranscriber: MeetingTranscriber?
    private var scStream: SCStream?

    // Thread-safe handles the realtime audio callbacks feed WITHOUT hopping to
    // the main actor. Hopping every audio buffer to @MainActor floods the main
    // queue and starves the UI (the Stop button becomes unclickable).
    private let micBox = TranscriberBox()
    private let systemBox = TranscriberBox()
    private lazy var micTranscriptionGate = MicrophoneTranscriptionGate {
        [micBox] buffer in
        micBox.feed(buffer)
    }
    private lazy var meetMuteMonitor = BrowserMeetingMuteMonitor(
        gate: micTranscriptionGate
    )

    private let audioSampleQueue = DispatchQueue(label: "com.thread.sck.audio")
    private let screenSampleQueue = DispatchQueue(label: "com.thread.sck.screen")

    // Mic capture health. `usingVoiceProcessing` is true only while Apple's AEC is
    // actually running; the watchdog falls back to a plain mic if AEC delivers no
    // audio (it breaks the mic on some hardware).
    private var micCounter = MicBufferCounter()
    private var usingVoiceProcessing = false
    private var micWatchdog: Task<Void, Never>?
    // Apple's voice-processing (AEC) is too flaky on some Macs (varying channel
    // counts, intermittent -10875 errors, sometimes no audio), so we default to a
    // plain mic + software de-dupe. Flip to true to re-experiment with AEC.
    private let attemptVoiceProcessing = false

    // Software echo suppression, used only when real AEC is NOT active. Recent
    // "Meeting" lines are remembered so a matching "You" line (speaker echo) can
    // be dropped before it's ever shown.
    private struct RecentLine { let tokens: [String]; let date: Date }
    private var recentMeeting: [RecentLine] = []
    private let echoWindow: TimeInterval = 8
    /// Shorter than `echoWindow`, because this one removes a line already on
    /// screen rather than suppressing one before it appears.
    private let retroEchoWindow: TimeInterval = 4
    private let minEchoWords = 2

    // On-screen speaker detection (Google Meet). Fully async: only ever consulted
    // to *label* meeting turns; never blocks transcription.
    private let speakerMonitor = SpeakerVisionMonitor.shared
    /// When the current meeting turn's audio began (for timeline queries).
    private var meetingTurnStart: Date?
    /// When the current "You" turn's audio began (to query who was glowing).
    private var youTurnStart: Date?
    /// Running vote for the local user's name across your turns; the mode wins.
    private var localNameTally: [String: Int] = [:]
    private var lastReconcileAt = Date.distantPast

    // Output-volume compensation for AEC comm-mode ducking. Only applied when AEC
    // is confirmed working; restored on stop / quit.
    private let volumeBoost: Float = 0.12
    private var boostedDevice: AudioDeviceID?
    private var preBoostVolume: Float?

    override init() {
        super.init()
        meetMuteMonitor.start()
        // Safety net: if the app quits mid-session, put the volume back.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreOutputVolume() }
        }
    }

    /// Stop any running capture and clear the transcript for a fresh session.
    func newSession() {
        if isRunning || isStarting {
            isRunning = false
            isStarting = false
            abortStart = true
            finishCapture(persist: true)
        }
        resetTranscripts()
    }

    // MARK: - Start

    func start(title: String = "") {
        guard !isRunning, !isStarting else { return }
        meetMuteMonitor.requestAccessIfNeeded()
        meetMuteMonitor.beginRecording()
        currentTitle = title
        startedAt = Date()
        // Flip UI state instantly so the button responds on click.
        isStarting = true
        abortStart = false
        statusMessage = "Starting"
        TranscriptionDiagnostics.shared.beginSession()
        Task { @MainActor in
            do {
                guard await requestPermissions() else {
                    statusMessage = "Microphone or speech permission denied."
                    isStarting = false
                    meetMuteMonitor.endRecording()
                    return
                }

                resetTranscripts()
                micTranscriber = try await makeTranscriber(source: .mic, applying: applyMic)
                systemTranscriber = try await makeTranscriber(source: .system, applying: applySystem)
                micBox.set(micTranscriber)
                systemBox.set(systemTranscriber)
                try startMic()
                try await startSystemAudio()

                // User hit Stop while we were still spinning up.
                if abortStart {
                    finishCapture(persist: false)
                    isStarting = false
                    return
                }

                isRunning = true
                isStarting = false
                statusMessage = "Listening"
                startMicWatchdog()
                startAutosave()
                startSpeakerDetection()
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
                isStarting = false
                finishCapture(persist: false)
            }
        }
    }

    /// Autosaves the in-progress transcript every few seconds while recording.
    private func startAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled, self.isRunning else { break }
                if !self.entries.isEmpty {
                    self.onAutosave?(self.currentTitle, self.entries, self.notes)
                }
            }
        }
    }

    /// Starts on-screen speaker detection and wires its samples to an async
    /// backfill of recently committed meeting turns. Nothing here can slow the
    /// transcript: samples arrive off-thread and only trigger a throttled,
    /// main-actor label update.
    private func startSpeakerDetection() {
        // Experimental, opt-in: without it turned on the monitor never starts, so
        // no names are looked up and turns keep their generic "You"/"Meeting"
        // labels. Read once at capture start — the toggle applies next recording.
        guard UserDefaults.standard.bool(forKey: AppSettings.speakerNamesKey) else { return }
        speakerMonitor.timeline.onSample = { [weak self] in
            Task { @MainActor [weak self] in self?.reconcileSpeakerNames() }
        }
        speakerMonitor.start()
    }

    /// Fills in (or corrects) speaker names on recent meeting turns from the
    /// timeline. Throttled and cheap; safe to call often.
    private func reconcileSpeakerNames() {
        let now = Date()
        guard now.timeIntervalSince(lastReconcileAt) >= 0.4 else { return }
        lastReconcileAt = now

        meetingVolatileSpeaker = speakerMonitor.timeline.currentName()
        if let mine = speakerMonitor.localName, mine != localUserName {
            localUserName = mine
            backfillLocalName()
        }

        var changed = false
        // Only the last few meeting turns are still "settling".
        let recent = entries.indices.suffix(6)
        for index in recent where entries[index].speaker == .meeting {
            let resolved = speakerMonitor.timeline.dominantName(
                from: entries[index].startedAt, to: entries[index].date,
                pad: 0.4, minShare: 0.6, minSamples: 1)
            if let resolved, resolved != entries[index].speakerName,
               resolved != localUserName {
                entries[index].speakerName = resolved
                changed = true
            }
        }
        if carryForwardMeetingNames() { changed = true }
        if changed { transcriptRevision &+= 1 }
    }

    /// Fills unlabeled meeting turns by inheriting the previous meeting speaker,
    /// but only when no *different* participant was detected during the turn
    /// (Meet's speaking marker flickers off in pauses, so a continuing speaker's
    /// short turn can land with zero samples). Safe in multi-party calls: anyone
    /// else who actually spoke would have glowed and resolved on their own.
    /// Returns whether anything changed. Walks in spoken (startedAt) order.
    @discardableResult
    private func carryForwardMeetingNames() -> Bool {
        let maxGap: TimeInterval = 12
        let ordered = entries.indices.sorted { entries[$0].startedAt < entries[$1].startedAt }
        var lastName: String?
        var lastEnd: Date?
        var changed = false
        for index in ordered where entries[index].speaker == .meeting {
            if let name = entries[index].speakerName {
                lastName = name
                lastEnd = entries[index].date
                continue
            }
            guard let carry = lastName, let end = lastEnd,
                  entries[index].startedAt.timeIntervalSince(end) < maxGap else { continue }
            let seen = speakerMonitor.timeline.namesInWindow(
                from: entries[index].startedAt, to: entries[index].date)
            guard seen.isSubset(of: [carry]) else { continue } // empty or only `carry`
            entries[index].speakerName = carry
            lastEnd = entries[index].date
            changed = true
        }
        return changed
    }

    /// Vote a name detected during a "You" turn in as the local user's name.
    /// Once a clear winner emerges it's applied to every "You" turn, so all your
    /// bubbles read consistently even for short turns that don't resolve alone.
    private func learnLocalName(_ candidate: String) {
        localNameTally[candidate, default: 0] += 1
        guard let winner = localNameTally.max(by: { $0.value < $1.value })?.key,
              winner != localUserName else { return }
        localUserName = winner
        backfillLocalName()
    }

    /// The Mac account's full name ("James Barker"), used for your own bubbles on
    /// surfaces that never show your name to us. Nil when it's unset or a login
    /// shortname, which reads worse than no label at all.
    private func accountFullName() -> String? {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard full.contains(" "), full != NSUserName() else { return nil }
        return full
    }

    private func backfillLocalName() {
        guard let name = localUserName else { return }
        var changed = false
        for index in entries.indices
        where entries[index].speaker == .you && entries[index].speakerName != name {
            entries[index].speakerName = name
            changed = true
        }
        if changed { transcriptRevision &+= 1 }
    }

    private func makeTranscriber(
        source: TranscriptionSource,
        applying apply: @escaping (String, Bool) -> Void
    ) async throws -> MeetingTranscriber {
        let transcriber = MeetingTranscriber(source: source, locale: .current)
        transcriber.onUpdate = { [weak self] text, isFinal, resultReceivedUptime in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let mainStartedUptime = TranscriptionDiagnostics.shared.recordMainStart(
                    source: source,
                    isFinal: isFinal,
                    resultReceivedUptime: resultReceivedUptime
                )
                apply(text, isFinal)
                self.transcriptRevision &+= 1
                TranscriptionDiagnostics.shared.recordMainCommit(
                    revision: self.transcriptRevision,
                    source: source,
                    isFinal: isFinal,
                    mainStartedUptime: mainStartedUptime
                )
            }
        }
        transcriber.onError = { [weak self] error in
            Task { @MainActor in self?.statusMessage = "Transcription error: \(error.localizedDescription)" }
        }
        try await transcriber.start()
        return transcriber
    }

    // MARK: - Microphone (AVAudioEngine)

    private func startMic() throws {
        let input = micEngine.inputNode
        micCounter = MicBufferCounter()

        // Optionally attempt Apple's voice-processing (AEC) to cancel speaker
        // echo. On some Macs enabling it reconfigures the input to a multichannel
        // format and the tap stops firing unless the engine's render loop is
        // actively pulling — so we also route the mic into a MUTED mixer to keep
        // the graph running, and a watchdog falls back to a plain mic if audio
        // still doesn't flow. Disabled by default (too flaky); see the flag.
        usingVoiceProcessing = false
        if attemptVoiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: false, duckingLevel: .min)
                let mixer = micEngine.mainMixerNode
                micEngine.connect(input, to: mixer, format: input.outputFormat(forBus: 0))
                mixer.outputVolume = 0
                usingVoiceProcessing = true
            } catch {
                usingVoiceProcessing = false
            }
        }

        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) {
            [micCounter, micTranscriptionGate] buffer, _ in
            let started = CACurrentMediaTime()
            micCounter.tick()
            micTranscriptionGate.process(buffer)
            TranscriptionDiagnostics.shared.recordCaptureCallback(
                source: .mic,
                frames: Int(buffer.frameLength),
                sampleRate: buffer.format.sampleRate,
                workMS: (CACurrentMediaTime() - started) * 1_000
            )
        }
        micEngine.prepare()
        try micEngine.start()
    }

    /// If AEC was enabled but delivers no audio shortly after start, tear it down
    /// and restart the mic without voice-processing so "You" always transcribes.
    private func startMicWatchdog() {
        micWatchdog?.cancel()
        guard usingVoiceProcessing else { return }
        micWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled, self.isRunning else { return }
            if self.micCounter.count == 0 {
                self.restartMicWithoutAEC()
            } else {
                self.boostOutputVolume()
            }
        }
    }

    private func restartMicWithoutAEC() {
        let input = micEngine.inputNode
        input.removeTap(onBus: 0)
        if micEngine.isRunning { micEngine.stop() }
        micEngine.disconnectNodeOutput(input)
        try? input.setVoiceProcessingEnabled(false)
        usingVoiceProcessing = false
        micCounter = MicBufferCounter()
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) {
            [micCounter, micTranscriptionGate] buffer, _ in
            let started = CACurrentMediaTime()
            micCounter.tick()
            micTranscriptionGate.process(buffer)
            TranscriptionDiagnostics.shared.recordCaptureCallback(
                source: .mic,
                frames: Int(buffer.frameLength),
                sampleRate: buffer.format.sampleRate,
                workMS: (CACurrentMediaTime() - started) * 1_000
            )
        }
        micEngine.prepare()
        try? micEngine.start()
    }

    // MARK: - System audio (ScreenCaptureKit)

    private func startSystemAudio() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "Thread", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for system audio capture."])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Minimal video: SCStream needs a video consumer, but we only care about audio.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 6)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioSampleQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenSampleQueue)
        try await stream.startCapture()
        scStream = stream
    }

    // MARK: - Stop

    func stop() {
        guard isRunning || isStarting else { return }
        abortStart = true
        isRunning = false
        isStarting = false
        statusMessage = "Idle"
        // Synchronous — do NOT defer to a Task. During a long session the main
        // actor can be busy re-rendering the transcript; a deferred teardown
        // gets starved and capture keeps running ("can't stop"). Doing the
        // critical shutdown inline guarantees the mic/transcribers stop now.
        finishCapture(persist: true)
    }

    /// Immediately and synchronously halts capture, persists, and clears state.
    /// Only the genuinely slow bits (SCStream stop, analyzer finalize) are
    /// deferred to a detached task — they can't hold up the UI or audio stop.
    private func finishCapture(persist: Bool) {
        meetMuteMonitor.endRecording()
        speakerMonitor.timeline.onSample = nil
        speakerMonitor.stop()
        meetingVolatileSpeaker = nil
        meetingTurnStart = nil
        autosaveTask?.cancel()
        autosaveTask = nil
        micWatchdog?.cancel()
        micWatchdog = nil

        // Put the speaker volume back to where the user had it.
        restoreOutputVolume()

        // Stop feeding immediately (before anything slow) so no more audio is
        // transcribed the instant Stop is pressed.
        micBox.set(nil)
        systemBox.set(nil)

        let input = micEngine.inputNode
        input.removeTap(onBus: 0)
        if micEngine.isRunning { micEngine.stop() }
        if usingVoiceProcessing {
            // Undo the AEC graph changes so the next session starts clean.
            micEngine.disconnectNodeOutput(input)
            try? input.setVoiceProcessingEnabled(false)
            usingVoiceProcessing = false
        }

        // Detach transcribers NOW: nulling the references makes any in-flight
        // SCStream buffers no-ops, and clearing callbacks stops trailing
        // results from leaking into the next session.
        let mic = micTranscriber
        let system = systemTranscriber
        mic?.onUpdate = nil
        mic?.onError = nil
        system?.onUpdate = nil
        system?.onError = nil
        micTranscriber = nil
        systemTranscriber = nil

        // Notes are real session content too. Persist them even if the user stops
        // before SpeechAnalyzer commits its first transcript line.
        if persist && (!entries.isEmpty
                       || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            onFinish?(currentTitle, entries, notes)
        }
        resetTranscripts()
        currentTitle = ""
        // Cleared *after* onFinish has read them (append vs new-session decision).
        appendTarget = nil
        appendBaseTranscript = nil
        startedAt = nil
        TranscriptionDiagnostics.shared.endSession()

        let stream = scStream
        scStream = nil
        Task.detached {
            if let stream { try? await stream.stopCapture() }
            await mic?.stop()
            await system?.stop()
        }
    }

    // MARK: - Transcript assembly

    private func resetTranscripts() {
        entries = []
        youVolatile = ""
        meetingVolatile = ""
        meetingVolatileSpeaker = nil
        meetingTurnStart = nil
        localUserName = nil
        localNameTally = [:]
        youTurnStart = nil
        notes = ""
        recentMeeting = []
    }

    private func applyMic(_ text: String, _ isFinal: Bool) {
        commit(text, isFinal: isFinal, speaker: .you)
    }

    private func applySystem(_ text: String, _ isFinal: Bool) {
        commit(text, isFinal: isFinal, speaker: .meeting)
    }

    private func commit(_ text: String, isFinal: Bool, speaker: Speaker) {
        if isFinal {
            var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let correct { trimmed = correct(trimmed) }
            if !trimmed.isEmpty {
                let now = Date()
                if speaker == .meeting {
                    let mtokens = Self.tokens(trimmed)
                    recentMeeting.append(RecentLine(tokens: mtokens, date: now))
                    recentMeeting.removeAll { now.timeIntervalSince($0.date) > echoWindow }
                    // Forward case: an echo transcribed as "You" just BEFORE this
                    // meeting line finalized. Drop that recent "You" bubble.
                    // Deleting a bubble the user has already read is the one
                    // irreversible move here, so it gets the narrowest window and
                    // the extra requirement that the echo be no longer than what
                    // was played — a mic picks up part of the room's audio, not
                    // more of it than came out.
                    if !usingVoiceProcessing,
                       let idx = entries.lastIndex(where: {
                           $0.speaker == .you && now.timeIntervalSince($0.date) <= retroEchoWindow
                       }) {
                        let youTokens = Self.tokens(entries[idx].text)
                        if youTokens.count >= minEchoWords, youTokens.count <= mtokens.count,
                           Self.isEcho(youTokens, of: mtokens) {
                            entries.remove(at: idx)
                        }
                    }
                } else if isMicEcho(trimmed) {
                    // Backward case: this "You" line matches meeting audio already
                    // seen — speaker echo. Drop it, don't commit.
                    youVolatile = ""
                    return
                }
                // Resolve who was on-screen speaking over the turn's span. For a
                // meeting turn that's the remote participant — never you, even if
                // your own tile was the marked one. For a "You" turn we take the
                // name the app puts on your tile, or vote on what glowed.
                let turnStart: Date
                let name: String?
                if speaker == .meeting {
                    turnStart = meetingTurnStart ?? now
                    let resolved = speakerMonitor.timeline.dominantName(
                        from: turnStart, to: now, pad: 0.4, minShare: 0.6, minSamples: 1)
                    name = resolved == localUserName ? nil : resolved
                } else {
                    turnStart = youTurnStart ?? now
                    if let mine = speakerMonitor.localName {
                        if mine != localUserName {
                            localUserName = mine
                            backfillLocalName()
                        }
                    } else if speakerMonitor.provider?.timelineNamesLocalUser == true,
                              let mine = speakerMonitor.timeline.dominantName(
                                from: turnStart, to: now, pad: 0.3, minShare: 0.65, minSamples: 2) {
                        learnLocalName(mine)
                    } else if localUserName == nil {
                        // Nothing on this surface can tell us your display name,
                        // so use the account's rather than leaving your bubbles
                        // bare. A real one found later still wins.
                        localUserName = accountFullName()
                        backfillLocalName()
                    }
                    name = localUserName
                }

                // Merge back-to-back segments from the same speaker into one
                // bubble — but only when the resolved name matches, so two people
                // talking in turn don't collapse into a single attribution.
                if let last = entries.last, last.speaker == speaker,
                   last.speakerName == name {
                    entries[entries.count - 1].text += " " + trimmed
                    entries[entries.count - 1].date = now
                } else {
                    entries.append(TranscriptEntry(speaker: speaker, text: trimmed,
                                                   date: now, speakerName: name,
                                                   startedAt: turnStart))
                }
            }
            switch speaker {
            case .you:
                youVolatile = ""
                youTurnStart = nil
            case .meeting:
                meetingVolatile = ""
                meetingTurnStart = nil
            }
        } else {
            let draft = correct?(text) ?? text
            switch speaker {
            case .you:
                // Suppress the live draft too so an echo never even flashes.
                let cleaned = isMicEcho(text) ? "" : draft
                if youVolatile.isEmpty, !cleaned.isEmpty { youTurnStart = Date() }
                youVolatile = cleaned
            case .meeting:
                if meetingVolatile.isEmpty, !draft.isEmpty { meetingTurnStart = Date() }
                meetingVolatile = draft
                meetingVolatileSpeaker = speakerMonitor.timeline.currentName()
            }
        }
    }

    /// True when a "You" line looks like speaker echo of the meeting audio. Only
    /// used when real AEC isn't active. Compares against recent finalized meeting
    /// lines AND the still-in-progress meeting draft.
    private func isMicEcho(_ text: String) -> Bool {
        guard !usingVoiceProcessing else { return false }
        let candidate = Self.tokens(text)
        guard candidate.count >= minEchoWords else { return false }
        if Self.isEcho(candidate, of: Self.tokens(meetingVolatile)) { return true }
        let now = Date()
        for line in recentMeeting where now.timeIntervalSince(line.date) <= echoWindow {
            if Self.isEcho(candidate, of: line.tokens) { return true }
        }
        return false
    }

    /// Lowercased alphanumeric word tokens.
    private static func tokens(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// True when most of `candidate`'s words appear in `source` (echo overlap).
    /// True when `candidate` looks like a re-transcription of `source` rather than
    /// someone independently saying similar words.
    ///
    /// Echo repeats the same words in the same order, so this matches on ordered
    /// overlap, and then asks for one of two kinds of corroboration: a long
    /// verbatim run, which nothing but a re-transcription produces, or a couple of
    /// distinctive words in common for shorter fragments. The bar is deliberately
    /// high because the cost is asymmetric — a missed echo leaves a duplicate
    /// bubble the user can see and delete, while a false match silently erases
    /// something they really said. Two people both saying "hello hello, this is a
    /// test" must not qualify.
    private static func isEcho(_ candidate: [String], of source: [String]) -> Bool {
        guard !candidate.isEmpty, !source.isEmpty else { return false }
        let ratio = Double(longestCommonRun(candidate, source)) / Double(candidate.count)
        guard ratio >= 0.8 else { return false }
        if ratio >= 0.9, candidate.count >= 8 { return true }
        let sourceDistinctive = Set(source.filter(isDistinctive))
        let shared = Set(candidate.filter(isDistinctive)).intersection(sourceDistinctive)
        return shared.count >= 2
    }

    /// Words common enough that two people saying them proves nothing.
    private static let fillerWords: Set<String> = [
        "hello", "hallo", "yeah", "yes", "okay", "sure", "right", "thanks",
        "sorry", "just", "like", "this", "that", "there", "here", "what",
        "when", "then", "well", "with", "your", "youre", "were", "test",
        "testing", "talking", "hear", "know", "think", "really", "again",
    ]

    private static func isDistinctive(_ token: String) -> Bool {
        token.count >= 4 && !fillerWords.contains(token)
    }

    /// Length of the longest subsequence of `candidate` appearing in `source` in
    /// the same order.
    private static func longestCommonRun(_ candidate: [String], _ source: [String]) -> Int {
        var previous = [Int](repeating: 0, count: source.count + 1)
        var current = previous
        for candidateIndex in 1...candidate.count {
            for sourceIndex in 1...source.count {
                current[sourceIndex] = candidate[candidateIndex - 1] == source[sourceIndex - 1]
                    ? previous[sourceIndex - 1] + 1
                    : max(previous[sourceIndex], current[sourceIndex - 1])
            }
            previous = current
        }
        return previous[source.count]
    }

    // MARK: - Output volume compensation (AEC ducking offset)

    private func boostOutputVolume() {
        guard boostedDevice == nil,
              let device = Self.defaultOutputDevice(),
              let current = Self.outputVolume(of: device) else { return }
        boostedDevice = device
        preBoostVolume = current
        Self.setOutputVolume(min(1.0, current + volumeBoost), on: device)
    }

    private func restoreOutputVolume() {
        if let device = boostedDevice, let volume = preBoostVolume {
            Self.setOutputVolume(volume, on: device)
        }
        boostedDevice = nil
        preBoostVolume = nil
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func outputVolume(of device: AudioDeviceID) -> Float? {
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var volume = Float(0)
        var size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    private static func setOutputVolume(_ volume: Float, on device: AudioDeviceID) {
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return }
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return }
        var value = max(0, min(1, volume))
        let size = UInt32(MemoryLayout<Float>.size)
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }

    // MARK: - Permissions

    private func requestPermissions() async -> Bool {
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return micGranted && speechGranted
    }

}

// MARK: - SCStreamOutput / SCStreamDelegate

extension AudioCaptureController: SCStreamOutput, SCStreamDelegate {

    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard type == .audio else { return }
        let started = CACurrentMediaTime()
        guard sampleBuffer.isValid else {
            TranscriptionDiagnostics.shared.recordCaptureFailure(
                source: .system, reason: "invalid_sample_buffer")
            return
        }
        guard let pcm = sampleBuffer.makePCMBuffer() else {
            TranscriptionDiagnostics.shared.recordCaptureFailure(
                source: .system, reason: "pcm_conversion_failed")
            return
        }
        // Feed off the main actor (see TranscriberBox / micBox note).
        systemBox.feed(pcm)
        TranscriptionDiagnostics.shared.recordCaptureCallback(
            source: .system,
            frames: Int(pcm.frameLength),
            sampleRate: pcm.format.sampleRate,
            workMS: (CACurrentMediaTime() - started) * 1_000
        )
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.statusMessage = "System audio stopped: \(error.localizedDescription)"
            self.isRunning = false
            self.finishCapture(persist: true)
        }
    }
}
