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
import QuartzCore

enum OpenAISTTError: LocalizedError {
    case missingKey

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Add an OpenAI key in Setup to transcribe with OpenAI."
        }
    }
}

/// `POST /v1/audio/transcriptions`. Sends a WAV clip; returns text. Nothing is logged.
enum OpenAITranscription {
    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    private struct TranscriptBody: Decodable {
        var text: String?
    }

    static func transcribe(
        key: String,
        model: String,
        wav: Data,
        prompt: String,
        language: String?
    ) async throws -> String {
        let boundary = "ThreadSTT\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = multipartBody(
            boundary: boundary,
            wav: wav,
            model: model,
            prompt: prompt,
            language: language
        )

        let (data, response) = try await session.data(for: request)
        if Task.isCancelled { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIChatError.unreachable("")
        }
        #if DEBUG
        NSLog("[stt] HTTP %d bytes=%d", http.statusCode, wav.count)
        #endif
        if !(200..<300).contains(http.statusCode) {
            let detail = errorMessage(in: data)
            switch http.statusCode {
            case 401, 403: throw OpenAIChatError.rejected
            case 429: throw OpenAIChatError.rateLimited
            default: throw OpenAIChatError.unreachable(detail)
            }
        }
        if let parsed = try? JSONDecoder().decode(TranscriptBody.self, from: data),
           let text = parsed.text {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw
    }

    private static func multipartBody(
        boundary: String,
        wav: Data,
        model: String,
        prompt: String,
        language: String?
    ) -> Data {
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        field("model", model)
        field("response_format", "json")
        if !prompt.isEmpty { field("prompt", prompt) }
        if let language, !language.isEmpty { field("language", language) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private static func errorMessage(in data: Data) -> String {
        struct APIErrorBody: Decodable {
            var error: Payload?
            struct Payload: Decodable { var message: String? }
        }
        guard let body = try? JSONDecoder().decode(APIErrorBody.self, from: data),
              let message = body.error?.message
        else { return "" }
        return message
    }
}

/// Chunked OpenAI STT for one capture stream (mic or meeting). `feed` is safe
/// from a realtime tap; conversion and uploads run off that thread.
final class OpenAIMeetingTranscriber: LiveTranscriber {
    var onUpdate: ((String, Bool, TimeInterval) -> Void)?
    var onError: ((Error) -> Void)?

    private let source: TranscriptionSource
    private let ingestQueue = DispatchQueue(label: "thread.openai.stt.ingest")
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!
    private let chunkFrames = 16_000 * 2
    private let minFlushFrames = Int(16_000 * 0.35)

    private var converter: AVAudioConverter?
    private var pcm = Data()
    private var started = false
    private var stopped = false
    private var haltUploads = false
    private var previousText = ""
    private var pendingWAVs: [Data] = []
    private var uploading = false
    private var reportedError = false
    private let stateLock = NSLock()

    init(source: TranscriptionSource) {
        self.source = source
    }

    func start() async throws {
        if STTRouting.apiKey.isEmpty { throw OpenAISTTError.missingKey }
        ingestQueue.sync {
            started = true
            stopped = false
            haltUploads = false
            pcm.removeAll(keepingCapacity: true)
            pendingWAVs.removeAll()
            previousText = ""
            reportedError = false
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.clone(buffer) else { return }
        ingestQueue.async { [weak self] in
            self?.ingest(copy)
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ingestQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.stopped = true
                self.flush(force: true)
                self.waitForUploadsThen(continuation.resume)
            }
        }
    }

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard started, !stopped, !haltUploads else { return }
        let conversionStart = CACurrentMediaTime()
        guard let converted = convert(buffer) else {
            TranscriptionDiagnostics.shared.recordIngest(
                source: source, audioDuration: 0,
                conversionMS: (CACurrentMediaTime() - conversionStart) * 1_000,
                failed: true
            )
            return
        }
        let duration = converted.format.sampleRate > 0
            ? Double(converted.frameLength) / converted.format.sampleRate
            : 0
        TranscriptionDiagnostics.shared.recordIngest(
            source: source,
            audioDuration: duration,
            conversionMS: (CACurrentMediaTime() - conversionStart) * 1_000,
            failed: false
        )
        pcm.append(Self.int16Data(from: converted))
        flush(force: false)
    }

    private func flush(force: Bool) {
        let needed = force ? minFlushFrames : chunkFrames
        while pcm.count / 2 >= needed {
            let frames = min(pcm.count / 2, chunkFrames)
            let byteCount = frames * 2
            let slice = pcm.prefix(byteCount)
            pcm.removeFirst(byteCount)
            guard !Self.isSilent(slice) else { continue }
            enqueue(Self.wav(pcm16: Data(slice), sampleRate: 16_000))
        }
        if force { pcm.removeAll(keepingCapacity: true) }
    }

    private func enqueue(_ wav: Data) {
        stateLock.lock()
        if pendingWAVs.count >= 8 {
            pendingWAVs.removeFirst()
        }
        pendingWAVs.append(wav)
        let startDrain = !uploading
        if startDrain { uploading = true }
        stateLock.unlock()
        if startDrain {
            Task { await self.drain() }
        }
    }

    private func drain() async {
        while true {
            stateLock.lock()
            if haltUploads {
                pendingWAVs.removeAll()
                uploading = false
                stateLock.unlock()
                return
            }
            guard let wav = pendingWAVs.first else {
                uploading = false
                stateLock.unlock()
                return
            }
            pendingWAVs.removeFirst()
            let prompt = previousText
            stateLock.unlock()

            let key = STTRouting.apiKey
            let model = STTRouting.model
            do {
                let text = try await OpenAITranscription.transcribe(
                    key: key,
                    model: model,
                    wav: wav,
                    prompt: prompt,
                    language: Locale.current.language.languageCode?.identifier
                )
                stateLock.lock()
                reportedError = false
                if !text.isEmpty {
                    previousText = String(text.suffix(300))
                }
                stateLock.unlock()
                if !text.isEmpty {
                    let receivedUptime = TranscriptionDiagnostics.shared.recordSTTResult(
                        source: source,
                        isFinal: true,
                        characters: text.count,
                        audioEnd: nil,
                        finalizedThrough: nil
                    )
                    onUpdate?(text, true, receivedUptime)
                }
            } catch is CancellationError {
                return
            } catch OpenAIChatError.rejected {
                stateLock.lock()
                haltUploads = true
                pendingWAVs.removeAll()
                uploading = false
                stateLock.unlock()
                onError?(OpenAIChatError.rejected)
                return
            } catch {
                let shouldReport: Bool
                stateLock.lock()
                shouldReport = !reportedError
                reportedError = true
                stateLock.unlock()
                if shouldReport { onError?(error) }
                if case OpenAIChatError.rateLimited = error {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func waitForUploadsThen(_ done: @escaping () -> Void) {
        func poll() {
            stateLock.lock()
            let busy = uploading || !pendingWAVs.isEmpty
            stateLock.unlock()
            if busy {
                ingestQueue.asyncAfter(deadline: .now() + 0.05, execute: poll)
            } else {
                done()
            }
        }
        poll()
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == targetFormat { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
        }
        guard let converter else { return nil }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return nil }
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

    private static func clone(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else { return nil }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard src.count == dst.count else { return nil }
        for index in src.indices {
            guard let sourceData = src[index].mData, let destData = dst[index].mData else {
                return nil
            }
            memcpy(destData, sourceData, Int(src[index].mDataByteSize))
            dst[index].mDataByteSize = src[index].mDataByteSize
        }
        return copy
    }

    private static func int16Data(from buffer: AVAudioPCMBuffer) -> Data {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return Data() }
        if let list = buffer.audioBufferList.pointee.mBuffers.mData {
            return Data(bytes: list, count: frames * MemoryLayout<Int16>.size)
        }
        return Data()
    }

    private static func isSilent(_ pcm16: Data) -> Bool {
        let count = pcm16.count / 2
        guard count > 0 else { return true }
        var peak: Int16 = 0
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples {
                let magnitude = sample == Int16.min ? Int16.max : abs(sample)
                if magnitude > peak { peak = magnitude }
            }
        }
        return peak < 400
    }

    private static func wav(pcm16: Data, sampleRate: Int) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(Data(string.utf8)) }
        func appendU16(_ value: UInt16) {
            var le = value.littleEndian
            data.append(Data(bytes: &le, count: 2))
        }
        func appendU32(_ value: UInt32) {
            var le = value.littleEndian
            data.append(Data(bytes: &le, count: 4))
        }
        let dataSize = UInt32(pcm16.count)
        append("RIFF")
        appendU32(36 + dataSize)
        append("WAVE")
        append("fmt ")
        appendU32(16)
        appendU16(1)
        appendU16(1)
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(sampleRate * 2))
        appendU16(2)
        appendU16(16)
        append("data")
        appendU32(dataSize)
        data.append(pcm16)
        return data
    }
}
