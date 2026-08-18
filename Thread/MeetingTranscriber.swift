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
import Speech
import QuartzCore

/// Wraps one on-device `SpeechAnalyzer` + `SpeechTranscriber` pipeline for a single
/// audio stream. Feed it PCM buffers from any thread; it converts them to the
/// analyzer's preferred format and streams incremental (volatile) + final results.
final class MeetingTranscriber {

    enum TranscriberError: LocalizedError {
        case localeNotSupported(String)
        case noAudioFormat

        var errorDescription: String? {
            switch self {
            case .localeNotSupported(let id): return "Locale \"\(id)\" is not supported for on-device transcription."
            case .noAudioFormat: return "Could not resolve an audio format for the transcriber."
            }
        }
    }

    /// Called with (text, isFinal). `isFinal == false` means a volatile, still-changing guess.
    var onUpdate: ((String, Bool, TimeInterval) -> Void)?
    var onError: ((Error) -> Void)?

    private let source: TranscriptionSource
    private let locale: Locale
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer

    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var resultsTask: Task<Void, Never>?
    private let feedLock = NSLock()
    private var timelineFramePosition: Int64 = 0

    // Apple can deliver many incremental hypotheses within a few milliseconds.
    // Keep only the newest draft from each burst; final results are never delayed.
    private let updateLock = NSLock()
    private var volatileFlushTask: Task<Void, Never>?
    private var volatileGeneration = 0

    init(source: TranscriptionSource, locale: Locale = .current) {
        self.source = source
        self.locale = locale
        self.transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        self.analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    func start() async throws {
        try await ensureModelInstalled()

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriberError.noAudioFormat
        }
        analyzerFormat = format

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = continuation

        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in self.transcriber.results {
                    let text = String(result.text.characters)
                    let receivedUptime = TranscriptionDiagnostics.shared.recordSTTResult(
                        source: self.source,
                        isFinal: result.isFinal,
                        characters: text.count,
                        audioEnd: Self.seconds(CMTimeRangeGetEnd(result.range)),
                        finalizedThrough: Self.seconds(result.resultsFinalizationTime)
                    )
                    if result.isFinal {
                        self.cancelPendingVolatile()
                        self.onUpdate?(text, true, receivedUptime)
                    } else {
                        self.queueVolatile(text, receivedUptime: receivedUptime)
                    }
                }
            } catch {
                self.onError?(error)
            }
        }

        try await analyzer.start(inputSequence: stream)
    }

    /// Thread-safe: safe to call from a realtime audio tap or SCStream callback.
    func feed(_ buffer: AVAudioPCMBuffer) {
        feedLock.lock()
        defer { feedLock.unlock() }
        guard let inputBuilder, let analyzerFormat else { return }
        let conversionStart = CACurrentMediaTime()
        guard let converted = convert(buffer, to: analyzerFormat) else {
            TranscriptionDiagnostics.shared.recordIngest(
                source: source,
                audioDuration: 0,
                conversionMS: (CACurrentMediaTime() - conversionStart) * 1_000,
                failed: true
            )
            return
        }
        let conversionMS = (CACurrentMediaTime() - conversionStart) * 1_000
        let duration = converted.format.sampleRate > 0
            ? Double(converted.frameLength) / converted.format.sampleRate
            : 0
        TranscriptionDiagnostics.shared.recordIngest(
            source: source,
            audioDuration: duration,
            conversionMS: conversionMS,
            failed: false
        )
        yieldTimedChunks(converted, to: inputBuilder)
    }

    func stop() async {
        cancelPendingVolatile()
        feedLock.lock()
        let builder = inputBuilder
        inputBuilder = nil
        feedLock.unlock()
        builder?.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
    }

    // MARK: - Model assets

    private func ensureModelInstalled() async throws {
        let supported = await SpeechTranscriber.supportedLocales
        let wanted = locale.identifier(.bcp47)
        guard supported.contains(where: { $0.identifier(.bcp47) == wanted }) else {
            throw TranscriberError.localeNotSupported(wanted)
        }
        // Returns nil when the required assets are already installed.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    // MARK: - Format conversion

    /// Sends 20 ms PCM chunks with an explicit, continuous audio timeline. This
    /// gives SpeechAnalyzer smaller scheduling units than the ~100 ms mic buffers
    /// AVAudioEngine commonly supplies on macOS.
    private func yieldTimedChunks(
        _ buffer: AVAudioPCMBuffer,
        to continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        let sampleRate = buffer.format.sampleRate
        guard sampleRate > 0 else { return }
        let chunkFrames = max(1, AVAudioFrameCount(sampleRate * 0.020))
        var offset: AVAudioFrameCount = 0

        while offset < buffer.frameLength {
            let count = min(chunkFrames, buffer.frameLength - offset)
            guard let chunk = Self.copyFrames(from: buffer, offset: offset, count: count) else {
                TranscriptionDiagnostics.shared.recordCaptureFailure(
                    source: source, reason: "chunk_copy_failed")
                return
            }
            let startTime = CMTime(
                value: timelineFramePosition,
                timescale: CMTimeScale(sampleRate.rounded())
            )
            continuation.yield(AnalyzerInput(buffer: chunk, bufferStartTime: startTime))
            timelineFramePosition += Int64(count)
            offset += count
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }

        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if conversionError != nil { return nil }
        return output
    }

    private static func copyFrames(
        from source: AVAudioPCMBuffer,
        offset: AVAudioFrameCount,
        count: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard count > 0,
              offset + count <= source.frameLength,
              let destination = AVAudioPCMBuffer(
                pcmFormat: source.format,
                frameCapacity: count
              )
        else { return nil }

        destination.frameLength = count
        let bytesPerFrame = Int(source.format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        let byteOffset = Int(offset) * bytesPerFrame
        let byteCount = Int(count) * bytesPerFrame
        for index in sourceBuffers.indices {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData,
                  byteOffset + byteCount <= Int(sourceBuffers[index].mDataByteSize)
            else { return nil }
            memcpy(
                destinationData,
                sourceData.advanced(by: byteOffset),
                byteCount
            )
            destinationBuffers[index].mDataByteSize = UInt32(byteCount)
        }
        return destination
    }

    // MARK: - Volatile result coalescing

    private func queueVolatile(_ text: String, receivedUptime: TimeInterval) {
        updateLock.lock()
        volatileGeneration &+= 1
        let generation = volatileGeneration
        volatileFlushTask?.cancel()
        volatileFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
            self?.deliverVolatile(
                text,
                receivedUptime: receivedUptime,
                generation: generation
            )
        }
        updateLock.unlock()
    }

    private func deliverVolatile(
        _ text: String,
        receivedUptime: TimeInterval,
        generation: Int
    ) {
        updateLock.lock()
        guard generation == volatileGeneration else {
            updateLock.unlock()
            return
        }
        volatileFlushTask = nil
        updateLock.unlock()
        onUpdate?(text, false, receivedUptime)
    }

    private func cancelPendingVolatile() {
        updateLock.lock()
        volatileGeneration &+= 1
        volatileFlushTask?.cancel()
        volatileFlushTask = nil
        updateLock.unlock()
    }

    private static func seconds(_ time: CMTime) -> TimeInterval? {
        guard time.isNumeric else { return nil }
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite && seconds >= 0 ? seconds : nil
    }
}
