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
import Combine
import NaturalLanguage
import FoundationModels

struct EnhanceTemplate: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var instructions: String
}

struct EnhanceResult {
    let notesMarkdown: String
    /// Nil means extraction failed; an empty array means extraction succeeded
    /// and found no action items.
    let actionItems: [String]?
}

@Generable
private struct ExtractedActionItem {
    @Guide(description: "The concrete task or follow-up, without checkbox syntax. Preserve the exact existing task wording when it matches.")
    var task: String
    @Guide(description: "The owner's name, but only if it appears verbatim in the notes or transcript (or matches the note-taker's aliases). Use an empty string if no name is explicitly present — never guess or invent one.")
    var owner: String
}

@Generable
private struct ExtractedActionItems {
    @Guide(description: "New concrete action items supported by the meeting evidence that are not already represented in the existing tasks.")
    var items: [ExtractedActionItem]
}

/// User-created Enhance templates. The built-in Default is intentionally not
/// persisted here, so app updates can continue improving it for everyone.
@MainActor
final class EnhanceTemplateStore: ObservableObject {
    @Published var templates: [EnhanceTemplate] {
        didSet { persist() }
    }

    private static let storageKey = "enhanceTemplates"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([EnhanceTemplate].self, from: data) {
            templates = decoded
        } else {
            templates = []
        }
    }

    @discardableResult
    func add() -> UUID {
        let template = EnhanceTemplate(
            name: "",
            instructions: "Focus on the most important context, decisions, and action items."
        )
        templates.append(template)
        return template.id
    }

    func remove(_ template: EnhanceTemplate) {
        templates.removeAll { $0.id == template.id }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// What the current Ask query is grounded in.
enum AskScope: Equatable {
    case allNotes
    case currentNote(URL)
}

/// A note that contributed to an answer (shown as a citation).
struct AskSource: Identifiable, Hashable {
    let url: URL
    let title: String
    var id: URL { url }
}

/// Streamed updates for a single Ask.
enum AskEvent {
    case sources([AskSource])
    case answer(String)      // cumulative answer text so far
    case failed(String)      // user-facing error / unavailable reason
}

/// One embedded slice of a note. Value type → safe to hand to tools running
/// off the main actor.
fileprivate struct Chunk: Sendable {
    let id: String
    let url: URL
    let title: String
    let text: String
    let vector: [Float]
}

/// A loaded Apple embedding model shared by indexing and query retrieval.
/// Contextual embeddings are preferred; the sentence model remains a fallback
/// when contextual assets are unavailable.
fileprivate final class SearchEmbeddingModel: @unchecked Sendable {
    enum Kind: Equatable, Sendable {
        case contextual
        case sentence
    }

    let kind: Kind
    private let contextual: NLContextualEmbedding?
    private let sentence: NLEmbedding?
    private let lock = NSLock()

    private init(
        kind: Kind,
        contextual: NLContextualEmbedding? = nil,
        sentence: NLEmbedding? = nil
    ) {
        self.kind = kind
        self.contextual = contextual
        self.sentence = sentence
    }

    static func preferred() async -> SearchEmbeddingModel? {
        if let contextual = NLContextualEmbedding(language: .english) {
            do {
                if !contextual.hasAvailableAssets {
                    let result = try await contextual.requestAssets()
                    guard result == .available else {
                        throw SearchEmbeddingError.assetsUnavailable
                    }
                }
                try contextual.load()
                let model = SearchEmbeddingModel(
                    kind: .contextual,
                    contextual: contextual
                )
                _ = model.vector(for: "Thread embedding warmup")
                return model
            } catch {
                // Fall through to the built-in sentence model.
            }
        }
        guard let sentence = NLEmbedding.sentenceEmbedding(for: .english) else {
            return nil
        }
        return SearchEmbeddingModel(kind: .sentence, sentence: sentence)
    }

    func vector(for text: String) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }

        switch kind {
        case .sentence:
            guard let sentence else { return nil }
            return sentence.vector(for: text)?.map(Float.init)
        case .contextual:
            break
        }
        guard let contextual,
              let result = try? contextual.embeddingResult(
                  for: text,
                  language: .english
              )
        else { return nil }

        var sum = [Double](repeating: 0, count: contextual.dimension)
        var tokenCount = 0
        result.enumerateTokenVectors(
            in: result.string.startIndex..<result.string.endIndex
        ) { vector, _ in
            guard vector.count == sum.count else { return true }
            for index in sum.indices {
                sum[index] += vector[index]
            }
            tokenCount += 1
            return true
        }
        guard tokenCount > 0 else { return nil }
        let divisor = Double(tokenCount)
        return sum.map { Float($0 / divisor) }
    }

    private enum SearchEmbeddingError: Error {
        case assetsUnavailable
    }
}

fileprivate struct NoteRef: Hashable, Sendable {
    let url: URL
    let title: String
}

/// Thread-safe collector for the notes a run's tool calls actually used, so we
/// can surface them as citation chips.
fileprivate final class SourceSink: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [AskSource] = []
    private var seen = Set<URL>()

    func add(_ sources: [AskSource]) {
        lock.lock(); defer { lock.unlock() }
        for source in sources where !seen.contains(source.url) {
            seen.insert(source.url)
            items.append(source)
        }
    }

    func snapshot() -> [AskSource] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

/// The "Ask" brain: keeps a small in-memory embedding index of every saved note
/// and answers questions with Apple's on-device model. The model drives its own
/// retrieval via tools (search / read / summarize) rather than a fixed
/// retrieve-then-read pipeline. Fully local, offline.
@MainActor
final class AskEngine: ObservableObject {

    @Published private(set) var isAvailable = false
    @Published private(set) var unavailableReason: String?

    private var chunks: [Chunk] = []
    /// url -> modified date used when it was last indexed (skip unchanged files).
    private var indexed: [URL: Date] = [:]
    private var searchModel: SearchEmbeddingModel?
    private var embeddingKind: SearchEmbeddingModel.Kind?
    private var searchModelTask: Task<SearchEmbeddingModel?, Never>?
    private var rebuildTask: Task<Void, Never>?
    private var rebuildGeneration = UUID()
    /// Held so the on-device model stays resident after prewarming.
    private var prewarmSession: LanguageModelSession?

    init() { refreshAvailability() }

    /// Warms the on-device model so the first enhance/ask isn't a cold start
    /// (which otherwise loads several GB of weights and can take many seconds).
    func prewarm() {
        guard isAvailable else { return }
        if prewarmSession == nil {
            prewarmSession = LanguageModelSession(instructions: Self.enhanceInstructions)
        }
        prewarmSession?.prewarm()
    }

    // MARK: - Availability

    func refreshAvailability() {
        switch SystemLanguageModel.default.availability {
        case .available:
            isAvailable = true
            unavailableReason = nil
        case .unavailable(let reason):
            isAvailable = false
            unavailableReason = Self.describe(reason)
        }
    }

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac doesn't support Apple Intelligence, so Ask isn't available."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in System Settings to use Ask."
        case .modelNotReady:
            return "The on-device model is still downloading. Try again in a bit."
        @unknown default:
            return "On-device AI is currently unavailable."
        }
    }

    // MARK: - Indexing

    /// Rebuilds the embedding index off the main thread, reusing vectors for
    /// files whose modified date hasn't changed since the last pass.
    func rebuild(from files: [(url: URL, folder: String, date: Date)]) {
        let existing = chunks
        let previouslyIndexed = indexed
        let previousKind = embeddingKind
        let modelTask: Task<SearchEmbeddingModel?, Never>
        if let searchModel {
            modelTask = Task.detached { searchModel }
        } else if let searchModelTask {
            modelTask = searchModelTask
        } else {
            modelTask = Task.detached(priority: .utility) {
                await SearchEmbeddingModel.preferred()
            }
            searchModelTask = modelTask
        }
        rebuildTask?.cancel()
        rebuildGeneration = UUID()
        let generation = rebuildGeneration
        rebuildTask = Task.detached(priority: .utility) {
            guard let model = await modelTask.value else {
                await MainActor.run { [weak self] in
                    guard self?.rebuildGeneration == generation else { return }
                    self?.searchModelTask = nil
                }
                return
            }
            guard !Task.isCancelled else { return }
            let wanted = Set(files.map(\.url))
            let dates = Dictionary(files.map { ($0.url, $0.date) }, uniquingKeysWith: { a, _ in a })

            var kept = previousKind == model.kind
                ? existing.filter { chunk in
                    wanted.contains(chunk.url)
                        && previouslyIndexed[chunk.url] == dates[chunk.url]
                }
                : []
            var newlyIndexed: [URL: Date] = [:]
            for chunk in kept { newlyIndexed[chunk.url] = previouslyIndexed[chunk.url] }

            for file in files {
                if Task.isCancelled { return }
                if newlyIndexed[file.url] == file.date { continue }
                guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
                let title = file.url.deletingPathExtension().lastPathComponent
                for (offset, piece) in Self.chunkText(
                    Self.cleanText(from: text)
                ).enumerated() {
                    if Task.isCancelled { return }
                    guard let vector = model.vector(for: piece) else { continue }
                    kept.append(
                        Chunk(
                            id: "\(file.url.path)#\(offset)",
                            url: file.url,
                            title: title,
                            text: piece,
                            vector: vector
                        )
                    )
                }
                newlyIndexed[file.url] = file.date
            }

            if Task.isCancelled { return }
            let finalChunks = kept
            let finalIndexed = newlyIndexed
            await MainActor.run { [weak self] in
                guard self?.rebuildGeneration == generation else { return }
                self?.chunks = finalChunks
                self?.indexed = finalIndexed
                self?.searchModel = model
                self?.embeddingKind = model.kind
                self?.searchModelTask = nil
            }
        }
    }

    // MARK: - Ask (tool-driven)

    func ask(_ query: String, scope: AskScope) -> AsyncStream<AskEvent> {
        let available = isAvailable
        let reason = unavailableReason
        let retrievalModel = searchModel

        // Snapshot index state on the main actor before handing to the stream.
        let scopedChunks: [Chunk]
        switch scope {
        case .allNotes: scopedChunks = chunks
        case .currentNote(let url): scopedChunks = chunks.filter { $0.url == url }
        }
        var seenRefs = Set<NoteRef>()
        var refs: [NoteRef] = []
        for chunk in chunks {
            let ref = NoteRef(url: chunk.url, title: chunk.title)
            if seenRefs.insert(ref).inserted { refs.append(ref) }
        }
        let currentTitle: String? = {
            if case .currentNote(let url) = scope { return chunks.first { $0.url == url }?.title }
            return nil
        }()
        let currentRef: NoteRef? = {
            guard case .currentNote(let url) = scope else { return nil }
            let title = chunks.first { $0.url == url }?.title ?? url.deletingPathExtension().lastPathComponent
            return NoteRef(url: url, title: title)
        }()

        return AsyncStream { continuation in
            let task = Task {
                guard available else {
                    continuation.yield(.failed(reason ?? "Ask is unavailable."))
                    continuation.finish()
                    return
                }
                let sink = SourceSink()
                let tools: [any Tool] = [
                    SearchNotesTool(
                        chunks: scopedChunks,
                        model: retrievalModel,
                        sink: sink
                    ),
                    SummarizeTopicTool(
                        chunks: scopedChunks,
                        model: retrievalModel,
                        sink: sink
                    ),
                    ReadNoteTool(refs: refs, sink: sink),
                    SummarizeNoteTool(refs: refs, sink: sink),
                    ListTasksTool(refs: refs, current: currentRef, sink: sink),
                    SetTaskDoneTool(refs: refs, current: currentRef, sink: sink),
                ]
                let session = LanguageModelSession(tools: tools,
                                                   instructions: Self.instructions(currentTitle: currentTitle))
                var lastSourceCount = 0
                do {
                    let stream = session.streamResponse(to: query)
                    for try await snapshot in stream {
                        if Task.isCancelled { break }
                        continuation.yield(.answer(snapshot.content))
                        let current = sink.snapshot()
                        if current.count != lastSourceCount {
                            lastSourceCount = current.count
                            continuation.yield(.sources(current))
                        }
                    }
                    let finalSources = sink.snapshot()
                    if finalSources.count != lastSourceCount {
                        continuation.yield(.sources(finalSources))
                    }
                } catch {
                    #if DEBUG
                    NSLog("[ask] generation failed: %@", error.localizedDescription)
                    #endif
                    continuation.yield(
                        .failed(
                            "Couldn't complete that request. Try asking about "
                                + "the topic again or select a specific note."
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Ask (one note, multi-turn)

    /// Grounding for a note conversation, assembled by the view rather than read
    /// from the embedding index. The index only holds what a rebuild has embedded,
    /// so it misses notes it hasn't reached — and during a recording the newest
    /// lines aren't on disk to embed in the first place.
    struct NoteEvidence: Sendable {
        var title: String
        /// What the user has typed into the note.
        var notes: String = ""
        /// The transcript so far: cached summaries for older recordings, latest raw.
        var transcript: String = ""
        /// The sentence still being spoken, which the recognizer may yet revise.
        var pending: String = ""
        /// A recording is feeding this note right now.
        var isRecording: Bool = false
    }

    /// A note's running conversation. The session keeps its own record of earlier
    /// turns — that's what makes "why?" answerable — and the sent copies are what
    /// the next turn is diffed against, so a meeting in progress is handed over as
    /// the lines that have landed since rather than in full every time.
    private struct NoteConversation {
        let session: LanguageModelSession
        var sentNotes: String?
        var sentTranscript: String?
    }

    private var noteConversations: [URL: NoteConversation] = [:]

    /// Answers a question about one note, holding a session per note so follow-ups
    /// land in context. Nothing here touches the embedding index: the caller passes
    /// the evidence, including whatever a live recording has produced.
    func askNote(_ query: String, note: URL,
                 evidence: NoteEvidence) -> AsyncStream<AskEvent> {
        let reason = unavailableReason
        guard isAvailable else {
            return AsyncStream { continuation in
                continuation.yield(.failed(reason ?? "Ask is unavailable."))
                continuation.finish()
            }
        }
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                // Two passes at most: if the first fails — a long meeting filling the
                // context window is the likely cause — the note starts a fresh
                // conversation and asks again with the whole note as evidence.
                for attempt in 0...1 {
                    if Task.isCancelled { break }
                    let convo = conversation(for: note)
                    let prompt = await Self.notePrompt(query: query, evidence: evidence,
                                                       sentNotes: convo.sentNotes,
                                                       sentTranscript: convo.sentTranscript)
                    markSent(evidence, for: note)
                    // A session answers one question at a time, and the previous
                    // stream may still be winding down from a cancel. Give it a beat
                    // rather than throwing this question away.
                    var waited = 0
                    while convo.session.isResponding, waited < 40, !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(50))
                        waited += 1
                    }
                    do {
                        for try await snapshot in convo.session.streamResponse(to: prompt) {
                            if Task.isCancelled { break }
                            continuation.yield(.answer(snapshot.content))
                        }
                        break
                    } catch {
                        #if DEBUG
                        NSLog("[askNote] attempt %d failed: %@", attempt,
                              error.localizedDescription)
                        #endif
                        noteConversations[note] = nil
                        if attempt == 1 && !Task.isCancelled {
                            continuation.yield(
                                .failed("Couldn't answer that one. Try asking again.")
                            )
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Renames move the file, and the conversation belongs to the note, not the path.
    func noteConversationMoved(from old: URL, to new: URL) {
        guard let convo = noteConversations.removeValue(forKey: old) else { return }
        noteConversations[new] = convo
    }

    /// Forgets a note's conversation — a deleted note, or a thread the user cleared.
    func forgetNoteConversation(_ url: URL) {
        noteConversations[url] = nil
    }

    private func conversation(for note: URL) -> NoteConversation {
        if let existing = noteConversations[note] { return existing }
        let ref = NoteRef(url: note, title: note.deletingPathExtension().lastPathComponent)
        // No retrieval tools: the note's text is handed over directly, so search
        // would only offer a staler copy of what the model already has. The task
        // tools stay because they act on the file rather than describe it.
        let sink = SourceSink()
        let convo = NoteConversation(
            session: LanguageModelSession(
                tools: [
                    ListTasksTool(refs: [ref], current: ref, sink: sink),
                    SetTaskDoneTool(refs: [ref], current: ref, sink: sink),
                ],
                instructions: Self.noteInstructions
            )
        )
        noteConversations[note] = convo
        return convo
    }

    private func markSent(_ evidence: NoteEvidence, for note: URL) {
        guard var convo = noteConversations[note] else { return }
        convo.sentNotes = evidence.notes
        convo.sentTranscript = evidence.transcript
        noteConversations[note] = convo
    }

    /// The opening turn carries the note in full; later turns carry only what has
    /// changed since the last answer, which for a running meeting is the handful of
    /// lines that have landed since. Nil sent copies mean "this is the first turn".
    private static func notePrompt(query: String, evidence: NoteEvidence,
                                  sentNotes: String?,
                                  sentTranscript: String?) async -> String {
        var parts = ["Note: \"\(evidence.title)\""]

        if sentNotes != evidence.notes {
            let notes = evidence.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if notes.isEmpty {
                parts.append("The user hasn't typed any notes yet.")
            } else {
                parts.append((sentNotes == nil
                              ? "The user's notes:"
                              : "The user's notes have changed. Current notes:")
                             + "\n" + notes)
            }
        }

        let transcript = evidence.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sent = sentTranscript?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sent.isEmpty, transcript.hasPrefix(sent) {
            let tail = String(transcript.dropFirst(sent.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty {
                let body = await condense(transcript: tail)
                parts.append("New transcript since your last answer:\n" + body.text)
            }
        } else if !transcript.isEmpty {
            let body = await condense(transcript: transcript)
            let heading = evidence.isRecording
                ? "Transcript so far (recording in progress)"
                : "Transcript"
            parts.append(heading + (body.summarized ? " (section summaries)" : "")
                         + ":\n" + body.text)
        } else if sentTranscript == nil {
            parts.append(evidence.isRecording
                         ? "The recording has just started — nothing has been transcribed yet."
                         : "This note has no transcript.")
        }

        let pending = evidence.pending.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty {
            parts.append("Being spoken right now (the recognizer's guess, may change):\n"
                         + pending)
        }

        parts.append("Question: " + query)
        return parts.joined(separator: "\n\n")
    }

    private static var noteInstructions: String {
        var text = """
        You are Thread's assistant for the one note the user is looking at. \
        Everything you know about it arrives in this conversation: the note's text \
        and transcript are given to you, and while a recording runs the new lines \
        arrive as they are transcribed.

        - This is an ongoing conversation about that note. A follow-up such as \
        "why?", "expand on that" or "and the second one?" refers to what you just \
        said — answer it in that context rather than starting over.
        - Answer only from what you have been given. If it isn't there, say so \
        plainly instead of guessing.
        - In transcripts the user's own words are labeled "You" and everyone else \
        "Meeting". When the user asks about themselves — "my tasks", "what did I \
        say" — only include what is actually theirs, never other people's items.
        - Lines marked as being spoken right now are the recognizer's best guess and \
        may still change. Use them for "what did they just say", but don't treat \
        their wording as final.
        - Answer directly first, then briefly explain, in concise natural prose. No \
        citations — there is only one note. Greetings and small talk get a natural \
        reply, with no note content pulled in.
        """
        let names = UserDefaults.standard.string(forKey: AppSettings.yourNamesKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !names.isEmpty {
            text += "\n\nNames and aliases used for the user: \(names). "
            text += "Treat action items explicitly assigned to any of these names as theirs."
        }
        return text
    }

    private static func instructions(currentTitle: String?) -> String {
        var text = """
        You are Thread's note assistant. You help the user with their saved notes \
        and meeting transcripts, and you have these tools:
        - searchNotes: find passages relevant to a query across the notes. Use for \
        factual or analytical questions about what was said or decided.
        - summarizeTopic: gather relevant passages about one topic across multiple \
        notes. Use for requests such as "summarize everything about Shark Ninja" \
        or "what have we discussed about onboarding".
        - readNote: read a single note's full text. Use for a targeted question \
        about one specific, shorter note.
        - summarizeNote: summarize one note or meeting (handles long transcripts). \
        Use only when the user identifies a specific note or meeting by title. \
        Never use it for a topic that may appear across multiple notes; use \
        summarizeTopic instead.
        - listTasks: list a note's checkbox tasks (open and done), numbered. Use \
        for "what tasks", "what's open", "what's left to do". This reads the \
        actual task list, so prefer it over searchNotes for task questions.
        - setTaskDone: mark a task done (or reopen it) by its number from \
        listTasks. Use when the user says they finished/completed something or \
        asks to check items off. Always call listTasks first to get the right \
        number, then state plainly what you changed. If a task title is omitted, \
        act on the note the user is currently viewing.

        Decide whether a tool is even needed: for greetings or small talk, just \
        reply naturally and don't call any tool or pull in note content. When you \
        do use information from a note, cite it inline with a bracketed number \
        like [1]; never begin a sentence with a citation. Directly answer first, \
        then briefly explain, in concise natural prose. Don't invent details; if \
        the notes don't contain the answer, say you couldn't find it.

        You are the assistant for the user, who is the note-taker. In transcripts \
        the user's own words are labeled "You" and other participants "Meeting". \
        When the user asks about themselves — "my tasks", "what did I say", "my \
        action items" — only include items that are actually the user's: things \
        labeled "You" or explicitly assigned to them by name. Do NOT present other \
        people's action items as the user's. If you can't tell which items belong \
        to the user, say so plainly instead of listing everyone's.
        """
        let names = UserDefaults.standard.string(forKey: AppSettings.yourNamesKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !names.isEmpty {
            text += "\n\nNames and aliases used for the user: \(names). "
            text += "Treat action items explicitly assigned to any of these names as the user's."
        }
        if let title = currentTitle {
            text += "\n\nThe user is currently viewing the note titled \"\(title)\". "
            text += "Treat \"this note\" / \"this meeting\" as that note, and scope searches to it."
        }
        return text
    }

    // MARK: - Enhance (notes rewrite)

    /// Turns the user's rough notes + a transcript into clean, structured
    /// Markdown notes (Granola-style), grounded in the transcript with the
    /// user's notes as priority anchors. Long transcripts are map-reduced so
    /// they fit the context window. Returns nil if the model is unavailable or
    /// generation fails, so the caller can leave the raw notes untouched.
    ///
    /// Streams the model's output through `onPartial` (cumulative Markdown) so the
    /// caller can render the notes filling in live; the final string is returned.
    func enhance(notes: String, transcript: String,
                 customInstructions: String? = nil,
                 onPartial: @MainActor @escaping (String) -> Void = { _ in }) async -> EnhanceResult? {
        guard isAvailable else { return nil }

        let anchors = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing to work with — don't clobber the notes with an empty summary.
        guard !anchors.isEmpty || !body.isEmpty else { return nil }

        let context = await Self.condense(transcript: body)
        let names = UserDefaults.standard.string(forKey: AppSettings.yourNamesKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let template = customInstructions?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = """
        Selected enhancement template:
        \(template.isEmpty ? Self.defaultEnhanceTemplate : template)

        Names and aliases used for the note-taker:
        \(names.isEmpty ? "(not provided)" : names)

        User's notes (priority anchors — expand and organize around these):
        \(anchors.isEmpty ? "(none — summarize from the transcript alone)" : anchors)

        Transcript\(context.summarized ? " (section summaries)" : ""):
        \(context.text.isEmpty ? "(none)" : context.text)
        """

        let session = LanguageModelSession(instructions: Self.enhanceInstructions)
        // Cap the response so the model can't run away generating filler; keeps
        // the whole enhance bounded and fast.
        let options = GenerationOptions(maximumResponseTokens: 900)
        var last = ""
        let start = Date()
        do {
            let stream = session.streamResponse(to: prompt, options: options)
            for try await snapshot in stream {
                if Task.isCancelled { break }
                last = snapshot.content
                let partial = last
                await MainActor.run { onPartial(partial) }
                // Safety valve: never let a wedged stream spin forever.
                if Date().timeIntervalSince(start) > 180 { break }
            }
        } catch {
            if last.isEmpty { return nil }
        }
        let notesOutput = last.trimmingCharacters(in: .whitespacesAndNewlines)
        // Never let a task-only/empty model response erase the user's notes.
        guard !notesOutput.isEmpty else { return nil }
        let actionItems = await Self.extractActionItems(
            notes: anchors,
            transcript: context.text,
            groundingText: body,
            names: names
        )
        return EnhanceResult(notesMarkdown: notesOutput, actionItems: actionItems)
    }

    /// Enhances a single block (a paragraph, heading, or list item) of the notes
    /// in place. The model decides per block whether to simply rewrite it more
    /// clearly, or to rewrite it AND append concise supporting detail — but any
    /// added detail must be grounded strictly in the transcript. With no
    /// transcript it falls back to a pure rewrite (no new facts). Streams
    /// cumulative Markdown through `onPartial` and returns the final block
    /// Markdown, or nil on failure / unavailability.
    func enhanceBlock(_ block: String,
                      transcript: String,
                      onPartial: @MainActor @escaping (String) -> Void = { _ in }) async -> String? {
        guard isAvailable else { return nil }
        let anchor = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !anchor.isEmpty else { return nil }

        let body = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = await Self.condense(transcript: body)
        let evidence = context.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let grounded = !evidence.isEmpty
        let names = UserDefaults.standard.string(forKey: AppSettings.yourNamesKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let prompt = """
        Names and aliases used for the note-taker:
        \(names.isEmpty ? "(not provided)" : names)

        Transcript evidence\(context.summarized ? " (section summaries)" : ""):
        \(grounded ? evidence : "(none provided — rewrite only; do not add any new facts)")

        Block to enhance (rewrite this in place, preserving its Markdown form):
        \(anchor)
        """

        let session = LanguageModelSession(instructions: Self.enhanceBlockInstructions)
        // Bounded so an expansion can add a few bullets but never run away.
        let options = GenerationOptions(maximumResponseTokens: 500)
        var last = ""
        let start = Date()
        do {
            let stream = session.streamResponse(to: prompt, options: options)
            for try await snapshot in stream {
                if Task.isCancelled { break }
                last = snapshot.content
                let partial = last
                await MainActor.run { onPartial(partial) }
                if Date().timeIntervalSince(start) > 120 { break }
            }
        } catch {
            if last.isEmpty { return nil }
        }
        let out = last.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// Produces a compact mini-summary of a single recording segment. Cached in
    /// the file so enhance can reuse it for older segments instead of re-reading
    /// the full transcript every time. Very long segments are condensed first.
    func summarizeSegment(_ text: String) async -> String? {
        guard isAvailable else { return nil }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let input = await Self.condense(transcript: body).text
        let sub = LanguageModelSession(instructions:
            "Summarize this segment of a meeting transcript in 3–5 sentences, focusing on decisions, key topics, and action items. Be factual and concise. Do not introduce any names or attributions that are not present verbatim in the text; do not invent anything.")
        let options = GenerationOptions(maximumResponseTokens: 260)
        guard let r = try? await sub.respond(to: input, options: options) else { return nil }
        let out = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// Condenses a transcript to fit the window: short ones pass through, long
    /// ones are summarized section-by-section first. Larger chunks mean fewer
    /// summarization round-trips, which is the main enhance latency win.
    private static func condense(transcript: String) async -> (text: String, summarized: Bool) {
        let pieces = chunkText(transcript, limit: 6000)
        if pieces.count <= 1 { return (transcript, false) }
        let sub = LanguageModelSession(instructions:
            "Summarize this excerpt of a meeting transcript in 2–4 sentences, focusing on decisions, key topics, and action items. Be factual. Do not introduce any names or attributions that are not present verbatim in the text.")
        let options = GenerationOptions(maximumResponseTokens: 220)
        var partials: [String] = []
        for (i, piece) in pieces.enumerated() {
            if Task.isCancelled { break }
            guard let r = try? await sub.respond(to: piece, options: options) else { continue }
            partials.append("Section \(i + 1): \(r.content)")
        }
        return (partials.joined(separator: "\n"), true)
    }

    private static func extractActionItems(notes: String,
                                           transcript: String,
                                           groundingText: String,
                                           names: String) async -> [String]? {
        let session = LanguageModelSession(instructions: """
        Extract concrete action items into the provided structured schema. Tasks \
        may come from EITHER the user's notes or the meeting transcript — the user \
        may have jotted a to-do that was never said aloud, and that is still a \
        valid task. This is independent of the notes template and is mandatory. \
        Include explicit commitments and assigned follow-ups. Existing tasks are \
        preserved by Thread: do not return a task already represented in the \
        existing list. Do not turn general discussion, observations, questions, or \
        decisions without a follow-up into tasks.

        Owners: only set an owner to a person's name that appears verbatim in the \
        user's notes or the transcript, or that matches the note-taker's aliases. \
        If no such name is clearly present, leave the owner empty. Never guess or \
        invent a name — most speakers are unlabeled, so an empty owner is normal \
        and expected.
        """)
        let prompt = """
        Names and aliases used for the note-taker:
        \(names.isEmpty ? "(not provided)" : names)

        User's notes (a valid source of tasks on their own):
        \(notes.isEmpty ? "(none)" : notes)

        Meeting evidence:
        \(transcript.isEmpty ? "(none)" : transcript)
        """
        let options = GenerationOptions(maximumResponseTokens: 400)
        // Deterministic guard against fabricated owners: a name survives only if
        // it actually appears in the notes, the transcript, or the aliases. We
        // keep the task and simply blank an ungrounded owner (a task with no
        // owner is still valid).
        let gate = (groundingText + "\n" + notes + "\n" + names).lowercased()
        do {
            let response = try await session.respond(
                to: prompt,
                generating: ExtractedActionItems.self,
                options: options
            )
            var seen = Set<String>()
            return response.content.items.compactMap { item in
                let task = item.task.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !task.isEmpty else { return nil }
                var owner = item.owner.trimmingCharacters(in: .whitespacesAndNewlines)
                if !owner.isEmpty && !ownerIsGrounded(owner, in: gate) { owner = "" }
                let rendered = owner.isEmpty ? task : "\(task) — \(owner)"
                let key = rendered.lowercased()
                guard seen.insert(key).inserted else { return nil }
                return rendered
            }
        } catch {
            return nil
        }
    }

    /// True if an extracted owner name actually appears in the grounding corpus
    /// (notes + transcript + aliases). Accepts a full-string match or any single
    /// name token, so "Alex" and "Alex Kim" both pass when present, but a wholly
    /// invented name is rejected.
    private static func ownerIsGrounded(_ owner: String, in gateLowercased: String) -> Bool {
        let lowered = owner.lowercased()
        if gateLowercased.contains(lowered) { return true }
        for token in lowered.split(whereSeparator: { !$0.isLetter }) where token.count > 1 {
            if gateLowercased.contains(token) { return true }
        }
        return false
    }

    private static let defaultEnhanceTemplate = """
    Create concise, skimmable meeting notes. Use these Markdown sections only \
    when the evidence supports real content:
    ## Overview
    ## Key Points
    ## Decisions
    ## Open Questions

    Write Overview as 2–3 sentences and use concise bullets for the other \
    sections. Omit empty or redundant sections.
    """

    private static let enhanceInstructions = """
    Produce clean Markdown notes according to the selected enhancement template. \
    The template controls the notes' purpose, organization, headings, tone, and \
    level of detail.

    NON-NEGOTIABLE RULES:
    - Treat the user's notes as priority anchors and ground every claim in the \
    meeting evidence. Never invent facts, names, numbers, decisions, or outcomes.
    - Never repeat the same information in multiple sections.
    - Never print filler such as "None", "No decisions were made", or an empty \
    heading. Omit unsupported content instead.
    - Do not output action items, task lists, checkbox syntax, or labels such as \
    "Current tasks". Thread extracts and preserves action items separately.
    - Output only the finished notes Markdown. Do not include a preamble, closing \
    remarks, explanations, or these instructions.
    """

    private static let enhanceBlockInstructions = """
    You improve a single block of the user's notes, in place. You are given that \
    one block plus the meeting transcript as evidence.

    Decide, for this block:
    - If the transcript contains relevant supporting detail for the block, \
    rewrite the block clearly AND expand it: keep the rewritten line first, then \
    add a few concise Markdown bullets of supporting detail drawn STRICTLY from \
    the transcript.
    - Otherwise, simply rewrite the block so it is clearer and better worded, \
    with no added bullets.

    NON-NEGOTIABLE RULES:
    - Preserve the block's Markdown form: a heading stays a heading of the same \
    level; a list item stays a list item; a plain paragraph stays a paragraph \
    (though you may add bullets beneath it when — and only when — expanding).
    - Never invent facts, names, numbers, decisions, or outcomes. Only the \
    transcript may justify added detail. If no transcript evidence is provided, \
    only rewrite; do not add any new information.
    - Preserve the block's original meaning and intent. Do not answer it, argue \
    with it, or change what the user meant.
    - Output ONLY the replacement Markdown for this block. No preamble, no \
    explanation, no surrounding quotes, and no code fences.
    """

    // MARK: - Retrieval helpers (used by tools)

    fileprivate nonisolated static func rank(
        query: String,
        in pool: [Chunk],
        k: Int,
        model: SearchEmbeddingModel?
    ) -> [Chunk] {
        guard !pool.isEmpty else { return [] }

        let semanticRanked: [(chunk: Chunk, score: Float)]
        if let queryVector = model?.vector(for: query) {
            semanticRanked = pool
                .map { (chunk: $0, score: cosine(queryVector, $0.vector)) }
                .sorted { $0.score > $1.score }
        } else {
            semanticRanked = []
        }
        let lexicalRanked = lexicalRank(query: query, pool: pool)
        let semanticRanks = Dictionary(
            semanticRanked.enumerated().map {
                ($0.element.chunk.id, $0.offset + 1)
            },
            uniquingKeysWith: min
        )
        let lexicalRanks = Dictionary(
            lexicalRanked.enumerated().map {
                ($0.element.chunkID, $0.offset + 1)
            },
            uniquingKeysWith: min
        )
        let queryTerms = Set(lexicalTerms(query))

        return pool
            .map { chunk -> (chunk: Chunk, score: Float) in
                let id = chunk.id
                let semantic = semanticRanks[id].map {
                    0.8 / Float(10 + $0)
                } ?? 0
                let lexical = lexicalRanks[id].map {
                    0.2 / Float(10 + $0)
                } ?? 0
                let titleTerms = Set(lexicalDocumentTerms(chunk.title))
                let exactTitleBonus: Float =
                    !queryTerms.isEmpty && queryTerms.isSubset(of: titleTerms)
                    ? 0.35 / 11
                    : 0
                return (
                    chunk: chunk,
                    score: semantic + lexical + exactTitleBonus
                )
            }
            .sorted { $0.score > $1.score }
            .prefix(k)
            .map(\.chunk)
    }

    private nonisolated static func lexicalRank(
        query: String,
        pool: [Chunk]
    ) -> [(chunkID: String, score: Float)] {
        let queryTerms = lexicalTerms(query)
        guard !queryTerms.isEmpty else { return [] }

        let documents = pool.map {
            lexicalDocumentTerms($0.title + " " + $0.text)
        }
        let averageLength = max(
            1,
            Double(documents.reduce(0) { $0 + $1.count })
                / Double(documents.count)
        )
        let documentCount = Double(documents.count)
        let uniqueQueryTerms = Set(queryTerms)
        var documentFrequency: [String: Int] = [:]
        for term in uniqueQueryTerms {
            documentFrequency[term] = documents.reduce(0) {
                $0 + (Set($1).contains(term) ? 1 : 0)
            }
        }

        let normalizedPhrase = queryTerms.joined(separator: " ")
        var ranked: [(chunkID: String, score: Float)] = []
        for (chunk, terms) in zip(pool, documents) {
            var frequencies: [String: Int] = [:]
            for term in terms { frequencies[term, default: 0] += 1 }

            var score = 0.0
            let lengthRatio = Double(terms.count) / averageLength
            for term in uniqueQueryTerms {
                guard let frequency = frequencies[term],
                      let frequencyInDocuments = documentFrequency[term]
                else { continue }
                let numerator = documentCount
                    - Double(frequencyInDocuments)
                    + 0.5
                let denominator = Double(frequencyInDocuments) + 0.5
                let idf = log(1 + numerator / denominator)
                let tf = Double(frequency)
                let normalization = tf
                    + 1.2 * (0.25 + 0.75 * lengthRatio)
                score += idf * (tf * 2.2) / normalization
            }
            if queryTerms.count > 1,
               terms.joined(separator: " ").contains(normalizedPhrase) {
                score += 2
            }
            if score > 0 {
                ranked.append((chunkID: chunk.id, score: Float(score)))
            }
        }
        return ranked.sorted { $0.score > $1.score }
    }

    private nonisolated static func lexicalTerms(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter {
                $0.count > 1 && !lexicalStopWords.contains($0)
            }
    }

    /// Add adjacent joined terms to documents so compact spellings such as
    /// "sharkninja" can still match text containing "Shark Ninja".
    private nonisolated static func lexicalDocumentTerms(
        _ text: String
    ) -> [String] {
        let terms = lexicalTerms(text)
        guard terms.count > 1 else { return terms }
        let joined = zip(terms, terms.dropFirst()).map(+)
        return terms + joined
    }

    private nonisolated static let lexicalStopWords: Set<String> = [
        "a", "an", "and", "any", "about", "are", "decided", "did",
        "discussed", "do", "for", "from", "in", "is", "it", "me",
        "meeting", "my", "of", "on", "should", "the", "to", "was",
        "were", "what", "which", "who"
    ]

    /// Groups retrieved chunks by source note, numbering each source once.
    fileprivate nonisolated static func buildContext(from hits: [Chunk]) -> (context: String, sources: [AskSource]) {
        var order: [URL] = []
        var byURL: [URL: (title: String, texts: [String])] = [:]
        for hit in hits {
            if byURL[hit.url] == nil {
                order.append(hit.url)
                byURL[hit.url] = (hit.title, [])
            }
            byURL[hit.url]?.texts.append(hit.text)
        }
        var context = ""
        var sources: [AskSource] = []
        for (i, url) in order.enumerated() {
            guard let entry = byURL[url] else { continue }
            sources.append(AskSource(url: url, title: entry.title))
            context += "[\(i + 1)] From \"\(entry.title)\":\n"
            context += entry.texts.joined(separator: "\n")
            context += "\n\n"
        }
        return (context, sources)
    }

    fileprivate nonisolated static func fullText(of url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return cleanText(from: text)
    }

    private nonisolated static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom == 0 ? 0 : dot / denom
    }

    // MARK: - Text cleaning / chunking

    nonisolated static func cleanText(from markdown: String) -> String {
        let parts = SessionStore.components(of: markdown)
        var pieces: [String] = []
        if !parts.notes.isEmpty { pieces.append(parts.notes) }
        if !parts.tasks.isEmpty { pieces.append(parts.tasks) }

        // Keep speaker attribution ("You:" vs "Meeting:") so the model can tell
        // the user's own words/tasks from other participants'.
        let transcript = SessionStore.parse(markdown)
            .map { "\($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
        if !transcript.isEmpty { pieces.append(transcript) }

        var out = pieces.joined(separator: "\n")
        for marker in ["**", "~~", "`", "•"] {
            out = out.replacingOccurrences(of: marker, with: "")
        }
        return out.replacingOccurrences(of: "\t", with: " ")
    }

    /// Packs text into ~`limit`-char chunks along paragraph boundaries.
    nonisolated static func chunkText(_ text: String, limit: Int = 600) -> [String] {
        let paragraphs = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var result: [String] = []
        var buffer = ""
        func flush() {
            let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { result.append(t) }
            buffer = ""
        }
        for para in paragraphs {
            if buffer.isEmpty {
                buffer = para
            } else if buffer.count + para.count + 1 <= limit {
                buffer += " " + para
            } else {
                flush()
                buffer = para
            }
            while buffer.count > limit + 200 {
                let cut = buffer.index(buffer.startIndex, offsetBy: limit + 200)
                result.append(String(buffer[..<cut]))
                buffer = String(buffer[cut...])
            }
        }
        flush()
        return result
    }
}

// MARK: - Tools

/// Semantic search over the (scoped) note index.
private struct SearchNotesTool: Tool {
    let name = "searchNotes"
    let description = "Search the user's notes and meeting transcripts for passages relevant to a query, returning the most relevant excerpts with source labels."
    let chunks: [Chunk]
    let model: SearchEmbeddingModel?
    let sink: SourceSink

    @Generable
    struct Arguments {
        @Guide(description: "What to look for, phrased as a natural-language query.")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let hits = AskEngine.rank(
            query: arguments.query,
            in: chunks,
            k: 5,
            model: model
        )
        let grounding = AskEngine.buildContext(from: hits)
        sink.add(grounding.sources)
        return grounding.context.isEmpty
            ? "No relevant passages were found in the notes."
            : grounding.context
    }
}

/// Retrieves broader evidence for a topic spanning multiple notes. The calling
/// model turns these passages into the final cross-note summary.
private struct SummarizeTopicTool: Tool {
    let name = "summarizeTopic"
    let description = "Gather relevant passages about a topic across multiple notes or meetings. Use for requests to summarize everything discussed about a subject. Do not use for a specific note title."
    let chunks: [Chunk]
    let model: SearchEmbeddingModel?
    let sink: SourceSink

    @Generable
    struct Arguments {
        @Guide(description: "The subject to summarize, written as a short search phrase rather than a note title.")
        var topic: String
    }

    func call(arguments: Arguments) async throws -> String {
        let ranked = AskEngine.rank(
            query: arguments.topic,
            in: chunks,
            k: 20,
            model: model
        )
        var perNote: [URL: Int] = [:]
        let hits = Array(
            ranked.filter { chunk in
                guard perNote[chunk.url, default: 0] < 3 else { return false }
                perNote[chunk.url, default: 0] += 1
                return true
            }.prefix(10)
        )
        let grounding = AskEngine.buildContext(from: hits)
        sink.add(grounding.sources)
        return grounding.context.isEmpty
            ? "No relevant passages were found for that topic."
            : "Evidence about \"\(arguments.topic)\" from the notes:\n\n"
                + grounding.context
    }
}

/// Reads a single note's full (cleaned) text, truncating very long ones.
private struct ReadNoteTool: Tool {
    let name = "readNote"
    let description = "Read the full text of one specific note by its title. Use for a targeted question about a single, shorter note."
    let refs: [NoteRef]
    let sink: SourceSink

    @Generable
    struct Arguments {
        @Guide(description: "The title (or part of the title) of the note to read.")
        var noteTitle: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let ref = AskEngine.resolve(arguments.noteTitle, in: refs) else {
            return "No note matching \"\(arguments.noteTitle)\" was found."
        }
        let text = AskEngine.fullText(of: ref.url)
        guard !text.isEmpty else { return "The note \"\(ref.title)\" is empty." }
        sink.add([AskSource(url: ref.url, title: ref.title)])
        if text.count > 6000 {
            return String(text.prefix(6000)) + "\n[truncated — use summarizeNote for the full note]"
        }
        return text
    }
}

/// Summarizes one note, map-reducing long transcripts so they fit the window.
private struct SummarizeNoteTool: Tool {
    let name = "summarizeNote"
    let description = "Summarize one specific note or meeting identified by its title. Handles long transcripts. Never use for a subject spanning multiple notes; use summarizeTopic for that."
    let refs: [NoteRef]
    let sink: SourceSink

    @Generable
    struct Arguments {
        @Guide(description: "The title (or part of the title) of the note to summarize.")
        var noteTitle: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let ref = AskEngine.resolve(arguments.noteTitle, in: refs) else {
            return "No note matching \"\(arguments.noteTitle)\" was found."
        }
        let text = AskEngine.fullText(of: ref.url)
        guard !text.isEmpty else { return "The note \"\(ref.title)\" is empty." }
        sink.add([AskSource(url: ref.url, title: ref.title)])

        let pieces = AskEngine.chunkText(text, limit: 1800)
        // Short enough to summarize directly — hand the raw text back.
        if pieces.count <= 1 { return text }

        // Map: summarize each section; the caller model reduces into a final answer.
        let sub = LanguageModelSession(instructions:
            "Summarize this excerpt of a meeting transcript in 2–4 sentences, focusing on decisions, key topics, and action items. Be factual.")
        var partials: [String] = []
        for (i, piece) in pieces.enumerated() {
            if Task.isCancelled { break }
            do {
                let response = try await sub.respond(to: piece)
                partials.append("Section \(i + 1): \(response.content)")
            } catch {
                // Keep the tool call alive so one failed map step does not leak
                // an internal Foundation Models error into the conversation.
                if !partials.isEmpty {
                    return "Section summaries of \"\(ref.title)\":\n"
                        + partials.joined(separator: "\n")
                }
                return "Excerpt from \"\(ref.title)\":\n"
                    + String(text.prefix(6_000))
            }
        }
        return "Section summaries of \"\(ref.title)\":\n" + partials.joined(separator: "\n")
    }
}

/// Lists a note's checkbox tasks (numbered), reading the file directly rather
/// than the embedding index so it's always accurate.
private struct ListTasksTool: Tool {
    let name = "listTasks"
    let description = "List a note's checkbox tasks (open and done) as a numbered list. Reads the actual task list; use this for questions about tasks / what's open / what's left."
    let refs: [NoteRef]
    let current: NoteRef?
    let sink: SourceSink

    @Generable
    struct Arguments {
        @Guide(description: "The note's title. Leave empty for the note the user is currently viewing.")
        var noteTitle: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let ref = resolveNoteRef(arguments.noteTitle, refs: refs, current: current) else {
            return "No matching note was found."
        }
        sink.add([AskSource(url: ref.url, title: ref.title)])
        let tasks = SessionStore.tasksInFile(at: ref.url)
        guard !tasks.isEmpty else { return "\"\(ref.title)\" has no tasks." }
        let lines = tasks.enumerated().map { i, t in
            "\(i + 1). [\(t.done ? "done" : "open")] \(t.text)"
        }
        return "Tasks in \"\(ref.title)\":\n" + lines.joined(separator: "\n")
    }
}

/// Marks a task done / not done by its (1-based) number from listTasks, writing
/// straight to the file and notifying the UI to reload.
private struct SetTaskDoneTool: Tool {
    let name = "setTaskDone"
    let description = "Mark a task done or not done by its number (from listTasks). Call listTasks first to get the number."
    let refs: [NoteRef]
    let current: NoteRef?
    let sink: SourceSink

    @Generable
    struct Arguments {
        @Guide(description: "The note's title. Leave empty for the note the user is currently viewing.")
        var noteTitle: String
        @Guide(description: "The task's 1-based number as shown by listTasks.")
        var taskNumber: Int
        @Guide(description: "true to mark done, false to reopen it.")
        var done: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        guard let ref = resolveNoteRef(arguments.noteTitle, refs: refs, current: current) else {
            return "No matching note was found."
        }
        var tasks = SessionStore.tasksInFile(at: ref.url)
        let idx = arguments.taskNumber - 1
        guard tasks.indices.contains(idx) else {
            return "There's no task #\(arguments.taskNumber) in \"\(ref.title)\"."
        }
        tasks[idx].done = arguments.done
        let changed = tasks[idx].text
        SessionStore.writeTasks(tasks, toFileAt: ref.url)
        await MainActor.run {
            NotificationCenter.default.post(name: .threadTasksDidChange, object: ref.url)
        }
        sink.add([AskSource(url: ref.url, title: ref.title)])
        return "Marked \"\(changed)\" as \(arguments.done ? "done" : "open") in \"\(ref.title)\"."
    }
}

/// Resolves a model-supplied note title (empty → the current note) to a ref.
private func resolveNoteRef(_ title: String, refs: [NoteRef], current: NoteRef?) -> NoteRef? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return current ?? refs.first }
    return AskEngine.resolve(trimmed, in: refs) ?? current
}

extension AskEngine {
    /// Resolves a model-supplied note title to a real note (exact, then
    /// case-insensitive contains, either direction).
    fileprivate nonisolated static func resolve(_ title: String, in refs: [NoteRef]) -> NoteRef? {
        let needle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return refs.first }
        if let exact = refs.first(where: { $0.title.lowercased() == needle }) { return exact }
        return refs.first { ref in
            let t = ref.title.lowercased()
            return t.contains(needle) || needle.contains(t)
        }
    }
}
