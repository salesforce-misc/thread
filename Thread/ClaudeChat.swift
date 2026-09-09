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

/// Thin Messages client. The key is sent as `x-api-key` only; notes/transcripts
/// go in `messages`. Nothing is logged.
enum ClaudeChat {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func stream(
        key: String,
        instructions: String,
        prompt: String,
        maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        let messages = [
            OpenAIChat.Message(role: "system", content: instructions),
            OpenAIChat.Message(role: "user", content: prompt),
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
            OpenAIChat.Message(role: "system", content: instructions),
            OpenAIChat.Message(role: "user", content: prompt),
        ]
        var body = baseBody(
            messages: messages,
            stream: false,
            maxTokens: maxTokens,
            tools: [
                OpenAIChat.ToolDefinition(
                    name: schemaName,
                    description: "Return the structured result.",
                    parameters: schema
                )
            ]
        )
        body["tool_choice"] = [
            "type": "tool",
            "name": schemaName,
        ]
        let parsed = try await post(key: key, body: body)
        if let call = parsed.toolCalls.first {
            let args = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !args.isEmpty, let data = args.data(using: .utf8) else {
                throw OpenAIChatError.empty
            }
            return data
        }
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
        tools: [OpenAIChat.ToolDefinition],
        maxTokens: Int,
        execute: (String, String) async throws -> String,
        onText: (String) -> Void
    ) async throws {
        _ = try await runToolConversation(
            key: key,
            messages: [
                OpenAIChat.Message(role: "system", content: instructions),
                OpenAIChat.Message(role: "user", content: user),
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
        messages: [OpenAIChat.Message],
        tools: [OpenAIChat.ToolDefinition],
        maxTokens: Int,
        execute: (String, String) async throws -> String,
        onText: (String) -> Void
    ) async throws -> [OpenAIChat.Message] {
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
                    messages.append(OpenAIChat.Message(role: "assistant", content: outcome.text))
                }
                return messages
            }
            messages.append(
                OpenAIChat.Message(
                    role: "assistant",
                    content: outcome.text.isEmpty ? nil : outcome.text,
                    toolCalls: outcome.toolCalls
                )
            )
            for call in outcome.toolCalls {
                if Task.isCancelled { return messages }
                let result = try await execute(call.name, call.arguments)
                messages.append(
                    OpenAIChat.Message(role: "tool", content: result, toolCallID: call.id)
                )
            }
        }
        return messages
    }

    private struct TurnOutcome {
        var text: String
        var toolCalls: [OpenAIChat.ToolCall]
    }

    private static func streamTurn(
        key: String,
        messages: [OpenAIChat.Message],
        tools: [OpenAIChat.ToolDefinition],
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
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIChatError.unreachable("Couldn't reach Anthropic.")
        }
        if !(200..<300).contains(http.statusCode) {
            var collected = Data()
            for try await byte in bytes {
                collected.append(byte)
                if collected.count > 8_192 { break }
            }
            try throwIfNeeded(http, data: collected)
            throw OpenAIChatError.unreachable("Couldn't reach Anthropic.")
        }

        var cumulative = ""
        var sawToolCall = false
        var builders: [Int: (id: String, name: String, arguments: String)] = [:]

        for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONDecoder().decode(StreamEvent.self, from: data)
            else { continue }

            if event.type == "error" {
                throw mappedError(
                    status: 0,
                    type: event.error?.type,
                    message: event.error?.message ?? ""
                )
            }

            if event.type == "content_block_start",
               event.content_block?.type == "tool_use" {
                sawToolCall = true
                let index = event.index ?? builders.count
                builders[index] = (
                    id: event.content_block?.id ?? "",
                    name: event.content_block?.name ?? "",
                    arguments: ""
                )
            }

            if event.type == "content_block_delta" {
                let index = event.index ?? 0
                if event.delta?.type == "text_delta",
                   let piece = event.delta?.text, !piece.isEmpty, !sawToolCall {
                    cumulative += piece
                    onText(cumulative)
                }
                if event.delta?.type == "input_json_delta",
                   let piece = event.delta?.partial_json {
                    var current = builders[index] ?? (id: "", name: "", arguments: "")
                    current.arguments += piece
                    builders[index] = current
                }
            }
        }

        let calls = builders.keys.sorted().compactMap { index -> OpenAIChat.ToolCall? in
            guard let row = builders[index], !row.id.isEmpty, !row.name.isEmpty else {
                return nil
            }
            let args = row.arguments.isEmpty ? "{}" : row.arguments
            return OpenAIChat.ToolCall(id: row.id, name: row.name, arguments: args)
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
        return parseMessage(data)
    }

    private static func parseMessage(_ data: Data) -> TurnOutcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]]
        else { return TurnOutcome(text: "", toolCalls: []) }
        var text = ""
        var calls: [OpenAIChat.ToolCall] = []
        for block in content {
            let type = block["type"] as? String
            if type == "text", let piece = block["text"] as? String {
                text += piece
            }
            if type == "tool_use" {
                let id = block["id"] as? String ?? ""
                let name = block["name"] as? String ?? ""
                let args = jsonString(block["input"])
                if !id.isEmpty, !name.isEmpty {
                    calls.append(OpenAIChat.ToolCall(id: id, name: name, arguments: args))
                }
            }
        }
        return TurnOutcome(text: text, toolCalls: calls)
    }

    private static func jsonString(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private static func baseBody(
        messages: [OpenAIChat.Message],
        stream: Bool,
        maxTokens: Int,
        tools: [OpenAIChat.ToolDefinition]
    ) -> [String: Any] {
        let split = splitMessages(messages)
        var body: [String: Any] = [
            "model": LLMRouting.model,
            "messages": split.messages,
            "stream": stream,
            "max_tokens": maxTokens,
        ]
        if !split.system.isEmpty {
            body["system"] = split.system
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { tool -> [String: Any] in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.parameters,
                ]
            }
        }
        return body
    }

    private static func splitMessages(
        _ messages: [OpenAIChat.Message]
    ) -> (system: String, messages: [[String: Any]]) {
        let system = messages
            .filter { $0.role == "system" }
            .compactMap(\.content)
            .joined(separator: "\n\n")
        var out: [[String: Any]] = []
        let rest = messages.filter { $0.role != "system" }
        var i = 0
        while i < rest.count {
            let message = rest[i]
            if message.role == "user" {
                out.append(["role": "user", "content": message.content ?? ""])
                i += 1
                continue
            }
            if message.role == "assistant" {
                var blocks: [[String: Any]] = []
                if let content = message.content, !content.isEmpty {
                    blocks.append(["type": "text", "text": content])
                }
                for call in message.toolCalls ?? [] {
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": jsonObject(call.arguments),
                    ])
                }
                if !blocks.isEmpty {
                    out.append(["role": "assistant", "content": blocks])
                }
                i += 1
                continue
            }
            if message.role == "tool" {
                var results: [[String: Any]] = []
                while i < rest.count, rest[i].role == "tool" {
                    results.append([
                        "type": "tool_result",
                        "tool_use_id": rest[i].toolCallID ?? "",
                        "content": rest[i].content ?? "",
                    ])
                    i += 1
                }
                out.append(["role": "user", "content": results])
                continue
            }
            i += 1
        }
        return (system, out)
    }

    private static func jsonObject(_ arguments: String) -> Any {
        let data = Data(arguments.utf8)
        if let obj = try? JSONSerialization.jsonObject(with: data),
           JSONSerialization.isValidJSONObject(obj) {
            return obj
        }
        return [String: Any]()
    }

    private static func makeRequest(key: String, body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func throwIfNeeded(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIChatError.unreachable("Couldn't reach Anthropic.")
        }
        if (200..<300).contains(http.statusCode) { return }
        #if DEBUG
        NSLog("[byocld] HTTP %d", http.statusCode)
        #endif
        let parsed = errorPayload(in: data)
        throw mappedError(status: http.statusCode, type: parsed.type, message: parsed.message)
    }

    private static func mappedError(status: Int, type: String?, message: String) -> OpenAIChatError {
        let combined = ((type ?? "") + " " + message).lowercased()
        if status == 401 || status == 403 || type == "authentication_error"
            || type == "permission_error" {
            return .rejected
        }
        if status == 402 || type == "billing_error" || isQuotaMessage(combined) {
            return .quotaExceeded
        }
        if status == 429 || type == "rate_limit_error" {
            if isQuotaMessage(combined) { return .quotaExceeded }
            return .rateLimited
        }
        if status == 400, isQuotaMessage(combined) {
            return .quotaExceeded
        }
        if !message.isEmpty { return .unreachable(message) }
        return .unreachable("Couldn't reach Anthropic.")
    }

    private static func isQuotaMessage(_ text: String) -> Bool {
        text.contains("credit")
            || text.contains("balance")
            || text.contains("billing")
            || text.contains("spend")
            || text.contains("quota")
    }

    private static func errorPayload(in data: Data?) -> (type: String?, message: String) {
        guard let data,
              let body = try? JSONDecoder().decode(APIErrorBody.self, from: data)
        else { return (nil, "") }
        return (body.error?.type, body.error?.message ?? "")
    }

    private struct StreamEvent: Decodable {
        var type: String
        var index: Int?
        var delta: Delta?
        var content_block: ContentBlock?
        var error: Payload?

        struct Delta: Decodable {
            var type: String?
            var text: String?
            var partial_json: String?
        }

        struct ContentBlock: Decodable {
            var type: String
            var id: String?
            var name: String?
        }

        struct Payload: Decodable {
            var type: String?
            var message: String?
        }
    }

    private struct APIErrorBody: Decodable {
        var error: StreamEvent.Payload?
    }
}
