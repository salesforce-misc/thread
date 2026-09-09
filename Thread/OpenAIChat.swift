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

extension Notification.Name {
    static let threadLLMSettingsDidChange = Notification.Name("threadLLMSettingsDidChange")
    static let threadLLMGenerationDidFail = Notification.Name("threadLLMGenerationDidFail")
}

enum LLMRouting {
    /// BYOK is on and a key is present for the selected provider.
    static var usesCloud: Bool {
        UserDefaults.standard.bool(forKey: AppSettings.bringYourOwnLLMEnabledKey)
            && !apiKey.isEmpty
    }

    static var usesOpenAI: Bool { usesCloud && provider == .openAI }

    static var usesClaude: Bool { usesCloud && provider == .claude }

    static var provider: LLMProvider {
        LLMProvider(rawValue: UserDefaults.standard.string(forKey: AppSettings.llmProviderKey) ?? "")
            ?? .openAI
    }

    static var apiKey: String {
        let provider = UserDefaults.standard.string(forKey: AppSettings.llmProviderKey)
            ?? LLMProvider.openAI.rawValue
        return LLMAPIKeyStore.load(provider: provider)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var model: String {
        let saved = UserDefaults.standard.string(forKey: AppSettings.llmModelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !saved.isEmpty { return saved }
        return provider == .claude
            ? AppSettings.defaultClaudeModel
            : AppSettings.defaultLLMModel
    }

    static func notifySettingsChanged() {
        NotificationCenter.default.post(name: .threadLLMSettingsDidChange, object: nil)
    }

    /// Last Enhance/Ask cloud failure. Setup shows it as a red glyph; the key stays.
    private(set) static var lastGenerationError: OpenAIChatError?

    static func noteGenerationFailure(_ error: Error) {
        guard usesCloud else { return }
        if error is CancellationError { return }
        let mapped = error as? OpenAIChatError
            ?? .unreachable(error.localizedDescription)
        lastGenerationError = mapped
        NotificationCenter.default.post(name: .threadLLMGenerationDidFail, object: mapped)
    }

    static func clearGenerationFailure() {
        lastGenerationError = nil
    }
}

/// Live transcription via OpenAI. Toggle on is the opt-in; audio is sent only
/// when a key is present. Own Keychain item first, else the LLM key.
enum STTRouting {
    static var usesOpenAI: Bool {
        UserDefaults.standard.bool(forKey: AppSettings.bringYourOwnTranscriptionEnabledKey)
    }

    static var apiKey: String {
        let own = LLMAPIKeyStore.load(provider: LLMProvider.openAI.rawValue, role: .transcription)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        return LLMAPIKeyStore.load(provider: LLMProvider.openAI.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var model: String {
        let saved = UserDefaults.standard.string(forKey: AppSettings.transcriptionModelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !saved.isEmpty { return saved }
        return AppSettings.defaultTranscriptionModel
    }
}

enum OpenAIChatError: LocalizedError {
    case rejected
    case rateLimited
    case quotaExceeded
    case unreachable(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .rejected:
            return "That API key was rejected."
        case .rateLimited:
            return "The API rate-limited the request. Try again in a moment."
        case .quotaExceeded:
            return "This API key is out of credit. Add billing in the provider console."
        case .unreachable(let detail):
            return detail.isEmpty ? "Couldn't reach the model." : detail
        case .empty:
            return "The model returned an empty response."
        }
    }
}

/// Dispatches Enhance/Ask to OpenAI or Claude from the Setup provider.
enum CloudLLM {
    static let setupHint = "Error: Check your API key in Setup."

    static func stream(
        key: String,
        instructions: String,
        prompt: String,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        switch LLMRouting.provider {
        case .openAI:
            return OpenAIChat.stream(
                key: key, instructions: instructions, prompt: prompt, maxTokens: maxTokens
            )
        case .claude:
            return ClaudeChat.stream(
                key: key, instructions: instructions, prompt: prompt, maxTokens: maxTokens
            )
        }
    }

    static func complete(
        key: String,
        instructions: String,
        prompt: String,
        maxTokens: Int
    ) async throws -> String {
        switch LLMRouting.provider {
        case .openAI:
            return try await OpenAIChat.complete(
                key: key, instructions: instructions, prompt: prompt, maxTokens: maxTokens
            )
        case .claude:
            return try await ClaudeChat.complete(
                key: key, instructions: instructions, prompt: prompt, maxTokens: maxTokens
            )
        }
    }

    static func completeJSON(
        key: String,
        instructions: String,
        prompt: String,
        schemaName: String,
        schema: [String: Any],
        maxTokens: Int
    ) async throws -> Data {
        switch LLMRouting.provider {
        case .openAI:
            return try await OpenAIChat.completeJSON(
                key: key,
                instructions: instructions,
                prompt: prompt,
                schemaName: schemaName,
                schema: schema,
                maxTokens: maxTokens
            )
        case .claude:
            return try await ClaudeChat.completeJSON(
                key: key,
                instructions: instructions,
                prompt: prompt,
                schemaName: schemaName,
                schema: schema,
                maxTokens: maxTokens
            )
        }
    }

    static func runToolConversation(
        key: String,
        instructions: String,
        user: String,
        tools: [OpenAIChat.ToolDefinition],
        maxTokens: Int,
        execute: (String, String) async throws -> String,
        onText: (String) -> Void
    ) async throws {
        switch LLMRouting.provider {
        case .openAI:
            try await OpenAIChat.runToolConversation(
                key: key,
                instructions: instructions,
                user: user,
                tools: tools,
                maxTokens: maxTokens,
                execute: execute,
                onText: onText
            )
        case .claude:
            try await ClaudeChat.runToolConversation(
                key: key,
                instructions: instructions,
                user: user,
                tools: tools,
                maxTokens: maxTokens,
                execute: execute,
                onText: onText
            )
        }
    }

    @discardableResult
    static func runToolConversation(
        key: String,
        messages: [OpenAIChat.Message],
        tools: [OpenAIChat.ToolDefinition],
        maxTokens: Int,
        execute: (String, String) async throws -> String,
        onText: (String) -> Void
    ) async throws -> [OpenAIChat.Message] {
        switch LLMRouting.provider {
        case .openAI:
            return try await OpenAIChat.runToolConversation(
                key: key,
                messages: messages,
                tools: tools,
                maxTokens: maxTokens,
                execute: execute,
                onText: onText
            )
        case .claude:
            return try await ClaudeChat.runToolConversation(
                key: key,
                messages: messages,
                tools: tools,
                maxTokens: maxTokens,
                execute: execute,
                onText: onText
            )
        }
    }
}

/// Thin Chat Completions client. The key is sent as a Bearer token only;
/// notes/transcripts go in `messages`. Nothing is logged.
enum OpenAIChat {
    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    struct Message {
        var role: String
        var content: String?
        var toolCallID: String?
        var toolCalls: [ToolCall]?
    }

    struct ToolCall: Equatable {
        var id: String
        var name: String
        var arguments: String
    }

    struct ToolDefinition {
        var name: String
        var description: String
        var parameters: [String: Any]
    }

    static func stream(
        key: String,
        instructions: String,
        prompt: String,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        let messages = [
            Message(role: "system", content: instructions),
            Message(role: "user", content: prompt),
        ]
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var cumulative = ""
                    let outcome = try await streamTurn(
                        key: key,
                        messages: messages,
                        tools: [],
                        maxTokens: maxTokens
                    ) { text in
                        cumulative = text
                        continuation.yield(text)
                    }
                    if !outcome.toolCalls.isEmpty, cumulative.isEmpty,
                       !outcome.text.isEmpty {
                        continuation.yield(outcome.text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func complete(
        key: String,
        instructions: String,
        prompt: String,
        maxTokens: Int
    ) async throws -> String {
        var last = ""
        for try await chunk in stream(
            key: key,
            instructions: instructions,
            prompt: prompt,
            maxTokens: maxTokens
        ) {
            last = chunk
        }
        let text = last.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { throw OpenAIChatError.empty }
        return text
    }

    static func completeJSON(
        key: String,
        instructions: String,
        prompt: String,
        schemaName: String,
        schema: [String: Any],
        maxTokens: Int
    ) async throws -> Data {
        let messages = [
            Message(role: "system", content: instructions),
            Message(role: "user", content: prompt),
        ]
        var body = baseBody(
            messages: messages,
            stream: false,
            maxTokens: maxTokens,
            tools: []
        )
        body["response_format"] = [
            "type": "json_schema",
            "json_schema": [
                "name": schemaName,
                "strict": true,
                "schema": schema,
            ],
        ]
        let parsed = try await post(key: key, body: body)
        let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let data = text.data(using: .utf8) else {
            throw OpenAIChatError.empty
        }
        return data
    }

    static func runToolConversation(
        key: String,
        instructions: String,
        user: String,
        tools: [ToolDefinition],
        maxTokens: Int,
        execute: (String, String) async throws -> String,
        onText: (String) -> Void
    ) async throws {
        _ = try await runToolConversation(
            key: key,
            messages: [
                Message(role: "system", content: instructions),
                Message(role: "user", content: user),
            ],
            tools: tools,
            maxTokens: maxTokens,
            execute: execute,
            onText: onText
        )
    }

    @discardableResult
    static func runToolConversation(
        key: String,
        messages: [Message],
        tools: [ToolDefinition],
        maxTokens: Int,
        execute: (String, String) async throws -> String,
        onText: (String) -> Void
    ) async throws -> [Message] {
        var messages = messages
        for _ in 0..<8 {
            if Task.isCancelled { return messages }
            let outcome = try await streamTurn(
                key: key,
                messages: messages,
                tools: tools,
                maxTokens: maxTokens,
                onText: onText
            )
            if outcome.toolCalls.isEmpty {
                if !outcome.text.isEmpty {
                    messages.append(Message(role: "assistant", content: outcome.text))
                }
                return messages
            }
            messages.append(
                Message(role: "assistant", content: nil, toolCalls: outcome.toolCalls)
            )
            for call in outcome.toolCalls {
                if Task.isCancelled { return messages }
                let result = try await execute(call.name, call.arguments)
                messages.append(
                    Message(role: "tool", content: result, toolCallID: call.id)
                )
            }
        }
        return messages
    }

    private struct TurnOutcome {
        var text: String
        var toolCalls: [ToolCall]
    }

    private static func streamTurn(
        key: String,
        messages: [Message],
        tools: [ToolDefinition],
        maxTokens: Int,
        onText: (String) -> Void
    ) async throws -> TurnOutcome {
        let body = baseBody(
            messages: messages,
            stream: true,
            maxTokens: maxTokens,
            tools: tools
        )
        let request = try makeRequest(key: key, body: body)
        let (bytes, response) = try await session.bytes(for: request)
        try throwIfNeeded(response, data: nil)

        var cumulative = ""
        var sawToolCall = false
        var builders: [Int: (id: String, name: String, arguments: String)] = [:]

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty || payload == "[DONE]" { continue }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                  let choice = chunk.choices.first
            else { continue }

            if let calls = choice.delta.tool_calls {
                sawToolCall = true
                for call in calls {
                    var current = builders[call.index] ?? (id: "", name: "", arguments: "")
                    if let id = call.id { current.id = id }
                    if let name = call.function?.name { current.name = name }
                    if let args = call.function?.arguments { current.arguments += args }
                    builders[call.index] = current
                }
            }

            if !sawToolCall, let piece = choice.delta.content, !piece.isEmpty {
                cumulative += piece
                onText(cumulative)
            }
        }

        let calls = builders.keys.sorted().compactMap { index -> ToolCall? in
            guard let row = builders[index], !row.id.isEmpty, !row.name.isEmpty else {
                return nil
            }
            return ToolCall(id: row.id, name: row.name, arguments: row.arguments)
        }
        return TurnOutcome(text: cumulative, toolCalls: calls)
    }

    private static func post(
        key: String,
        body: [String: Any]
    ) async throws -> TurnOutcome {
        let request = try makeRequest(key: key, body: body)
        let (data, response) = try await session.data(for: request)
        try throwIfNeeded(response, data: data)
        let decoded = try JSONDecoder().decode(CompletionResponse.self, from: data)
        let message = decoded.choices.first?.message
        let calls = (message?.tool_calls ?? []).map {
            ToolCall(
                id: $0.id,
                name: $0.function.name,
                arguments: $0.function.arguments
            )
        }
        return TurnOutcome(text: message?.content ?? "", toolCalls: calls)
    }

    private static func baseBody(
        messages: [Message],
        stream: Bool,
        maxTokens: Int,
        tools: [ToolDefinition]
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": LLMRouting.model,
            "messages": messages.map(dictionary(for:)),
            "stream": stream,
            "max_tokens": maxTokens,
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters,
                    ],
                ]
            }
        }
        return body
    }

    private static func dictionary(for message: Message) -> [String: Any] {
        var dict: [String: Any] = ["role": message.role]
        if let content = message.content { dict["content"] = content }
        if let toolCallID = message.toolCallID { dict["tool_call_id"] = toolCallID }
        if let toolCalls = message.toolCalls {
            dict["tool_calls"] = toolCalls.map { call -> [String: Any] in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.arguments,
                    ],
                ]
            }
        }
        return dict
    }

    private static func makeRequest(key: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func throwIfNeeded(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIChatError.unreachable("")
        }
        if (200..<300).contains(http.statusCode) { return }
        let detail = errorMessage(in: data)
        let lowered = detail.lowercased()
        switch http.statusCode {
        case 401, 403:
            throw OpenAIChatError.rejected
        case 402:
            throw OpenAIChatError.quotaExceeded
        case 429:
            if lowered.contains("quota") || lowered.contains("insufficient")
                || lowered.contains("billing") {
                throw OpenAIChatError.quotaExceeded
            }
            throw OpenAIChatError.rateLimited
        default:
            if lowered.contains("quota") || lowered.contains("insufficient_quota") {
                throw OpenAIChatError.quotaExceeded
            }
            throw OpenAIChatError.unreachable(detail)
        }
    }

    private static func errorMessage(in data: Data?) -> String {
        guard let data,
              let body = try? JSONDecoder().decode(APIErrorBody.self, from: data),
              let message = body.error?.message
        else { return "" }
        return message
    }

    private struct StreamChunk: Decodable {
        var choices: [Choice]
        struct Choice: Decodable {
            var delta: Delta
            struct Delta: Decodable {
                var content: String?
                var tool_calls: [ToolCallDelta]?
            }
        }
    }

    private struct ToolCallDelta: Decodable {
        var index: Int
        var id: String?
        var function: FunctionDelta?
        struct FunctionDelta: Decodable {
            var name: String?
            var arguments: String?
        }
    }

    private struct CompletionResponse: Decodable {
        var choices: [Choice]
        struct Choice: Decodable {
            var message: Message
            struct Message: Decodable {
                var content: String?
                var tool_calls: [ToolCallPayload]?
            }
        }
    }

    private struct ToolCallPayload: Decodable {
        var id: String
        var function: Function
        struct Function: Decodable {
            var name: String
            var arguments: String
        }
    }

    private struct APIErrorBody: Decodable {
        var error: Payload?
        struct Payload: Decodable {
            var message: String?
        }
    }
}
