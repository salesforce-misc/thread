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
import OSLog
import QuartzCore

enum TranscriptionSource: String, Sendable {
    case mic
    case system
}

/// Debug-only transcription timing. Release builds keep the call sites but all
/// methods compile to no-ops, so production capture has no measurement overhead.
final class TranscriptionDiagnostics: @unchecked Sendable {
    static let shared = TranscriptionDiagnostics()

    #if DEBUG
    private struct SourceState {
        var firstFeedUptime: TimeInterval?
        var totalFedAudio: TimeInterval = 0

        var captureReportUptime: TimeInterval = CACurrentMediaTime()
        var captureCallbacks = 0
        var captureAudio: TimeInterval = 0
        var captureWorkTotalMS = 0.0
        var captureWorkMaxMS = 0.0

        var ingestReportUptime: TimeInterval = CACurrentMediaTime()
        var ingestBuffers = 0
        var ingestAudio: TimeInterval = 0
        var conversionTotalMS = 0.0
        var conversionMaxMS = 0.0
        var conversionFailures = 0
    }

    private struct PendingRender {
        let source: TranscriptionSource
        let isFinal: Bool
        let committedUptime: TimeInterval
    }

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.thread.app.dev", category: "Transcription")
    private var states: [TranscriptionSource: SourceState] = [:]
    private var pendingRenders: [Int: PendingRender] = [:]
    #endif

    private init() {}

    func beginSession() {
        #if DEBUG
        lock.lock()
        states = [:]
        pendingRenders = [:]
        lock.unlock()
        log("SESSION event=begin")
        #endif
    }

    func endSession() {
        #if DEBUG
        log("SESSION event=end")
        #endif
    }

    func recordCaptureCallback(source: TranscriptionSource,
                               frames: Int,
                               sampleRate: Double,
                               workMS: Double) {
        #if DEBUG
        let now = CACurrentMediaTime()
        let duration = sampleRate > 0 ? Double(frames) / sampleRate : 0
        var report: String?
        lock.lock()
        var state = states[source, default: SourceState()]
        state.captureCallbacks += 1
        state.captureAudio += duration
        state.captureWorkTotalMS += workMS
        state.captureWorkMaxMS = max(state.captureWorkMaxMS, workMS)
        if now - state.captureReportUptime >= 1 {
            let count = max(state.captureCallbacks, 1)
            report = String(
                format: "CAPTURE source=%@ callbacks=%d audio_ms=%.0f avg_work_ms=%.3f max_work_ms=%.3f",
                source.rawValue,
                state.captureCallbacks,
                state.captureAudio * 1_000,
                state.captureWorkTotalMS / Double(count),
                state.captureWorkMaxMS
            )
            state.captureReportUptime = now
            state.captureCallbacks = 0
            state.captureAudio = 0
            state.captureWorkTotalMS = 0
            state.captureWorkMaxMS = 0
        }
        states[source] = state
        lock.unlock()
        if let report { log(report) }
        #endif
    }

    func recordIngest(source: TranscriptionSource,
                      audioDuration: TimeInterval,
                      conversionMS: Double,
                      failed: Bool) {
        #if DEBUG
        let now = CACurrentMediaTime()
        var report: String?
        lock.lock()
        var state = states[source, default: SourceState()]
        if state.firstFeedUptime == nil { state.firstFeedUptime = now }
        if !failed { state.totalFedAudio += audioDuration }
        state.ingestBuffers += 1
        state.ingestAudio += audioDuration
        state.conversionTotalMS += conversionMS
        state.conversionMaxMS = max(state.conversionMaxMS, conversionMS)
        if failed { state.conversionFailures += 1 }
        if now - state.ingestReportUptime >= 1 {
            let count = max(state.ingestBuffers, 1)
            report = String(
                format: "INGEST source=%@ buffers=%d audio_ms=%.0f avg_convert_ms=%.3f max_convert_ms=%.3f failures=%d",
                source.rawValue,
                state.ingestBuffers,
                state.ingestAudio * 1_000,
                state.conversionTotalMS / Double(count),
                state.conversionMaxMS,
                state.conversionFailures
            )
            state.ingestReportUptime = now
            state.ingestBuffers = 0
            state.ingestAudio = 0
            state.conversionTotalMS = 0
            state.conversionMaxMS = 0
            state.conversionFailures = 0
        }
        states[source] = state
        lock.unlock()
        if let report { log(report) }
        #endif
    }

    /// Records Apple's result and returns the monotonic receipt time so the
    /// caller can measure its subsequent hop onto the main actor.
    @discardableResult
    func recordSTTResult(source: TranscriptionSource,
                         isFinal: Bool,
                         characters: Int,
                         audioEnd: TimeInterval?,
                         finalizedThrough: TimeInterval?) -> TimeInterval {
        let now = CACurrentMediaTime()
        #if DEBUG
        lock.lock()
        let state = states[source, default: SourceState()]
        let firstFeed = state.firstFeedUptime
        let totalFed = state.totalFedAudio
        lock.unlock()

        let resultLag = (firstFeed != nil && audioEnd != nil)
            ? max(0, now - firstFeed! - audioEnd!)
            : -1
        let audioBacklog = audioEnd.map { max(0, totalFed - $0) } ?? -1
        let finalBacklog = finalizedThrough.map { max(0, totalFed - $0) } ?? -1
        log(String(
            format: "STT source=%@ final=%d chars=%d audio_end_ms=%.0f result_lag_ms=%.1f analyzer_backlog_ms=%.1f finalized_backlog_ms=%.1f",
            source.rawValue,
            isFinal ? 1 : 0,
            characters,
            (audioEnd ?? -0.001) * 1_000,
            resultLag * 1_000,
            audioBacklog * 1_000,
            finalBacklog * 1_000
        ))
        #endif
        return now
    }

    @discardableResult
    func recordMainStart(source: TranscriptionSource,
                         isFinal: Bool,
                         resultReceivedUptime: TimeInterval) -> TimeInterval {
        let now = CACurrentMediaTime()
        #if DEBUG
        log(String(
            format: "MAIN_QUEUE source=%@ final=%d wait_ms=%.1f",
            source.rawValue,
            isFinal ? 1 : 0,
            max(0, now - resultReceivedUptime) * 1_000
        ))
        #endif
        return now
    }

    func recordMainCommit(revision: Int,
                          source: TranscriptionSource,
                          isFinal: Bool,
                          mainStartedUptime: TimeInterval) {
        #if DEBUG
        let now = CACurrentMediaTime()
        lock.lock()
        pendingRenders[revision] = PendingRender(
            source: source,
            isFinal: isFinal,
            committedUptime: now
        )
        // Bound skipped revisions when several hypotheses coalesce into one render.
        pendingRenders = pendingRenders.filter { $0.key >= revision - 50 }
        lock.unlock()
        log(String(
            format: "MAIN_APPLY source=%@ final=%d revision=%d work_ms=%.1f",
            source.rawValue,
            isFinal ? 1 : 0,
            revision,
            max(0, now - mainStartedUptime) * 1_000
        ))
        #endif
    }

    func recordRendered(revision: Int) {
        #if DEBUG
        let now = CACurrentMediaTime()
        lock.lock()
        let pending = pendingRenders[revision]
        pendingRenders = pendingRenders.filter { $0.key > revision }
        lock.unlock()
        guard let pending else { return }
        log(String(
            format: "RENDER source=%@ final=%d revision=%d main_to_render_ms=%.1f",
            pending.source.rawValue,
            pending.isFinal ? 1 : 0,
            revision,
            max(0, now - pending.committedUptime) * 1_000
        ))
        #endif
    }

    func recordCaptureFailure(source: TranscriptionSource, reason: String) {
        #if DEBUG
        log("CAPTURE_FAILURE source=\(source.rawValue) reason=\(reason)")
        #endif
    }

    #if DEBUG
    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }
    #endif
}
