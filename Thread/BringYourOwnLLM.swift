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

import SwiftUI
import AppKit
import Security

enum LLMProvider: String, CaseIterable, Identifiable {
    case openAI = "openai"
    case claude = "claude"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI: return "OpenAI"
        case .claude: return "Anthropic"
        }
    }

    var markName: String {
        switch self {
        case .openAI: return "OpenAIMark"
        case .claude: return "ClaudeMark"
        }
    }

    /// OpenAI's mark is a template glyph; Claude's stays the terracotta flower.
    var rendersAsTemplate: Bool {
        switch self {
        case .openAI: return true
        case .claude: return false
        }
    }
}

enum LLMKeyStatus: Equatable {
    case idle
    case checking
    case connected
    case rejected
    case unreachable
}

enum LLMKeyRole {
    case chat
    case transcription

    fileprivate func account(provider: String) -> String {
        switch self {
        case .chat: return provider
        case .transcription: return provider + ".stt"
        }
    }
}

enum LLMAPIKeyStore {
    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "com.thread.app") + ".byollm"
    }

    static func load(provider: String, role: LLMKeyRole = .chat) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: role.account(provider: provider),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return "" }
        return value
    }

    static func isPresent(provider: String, role: LLMKeyRole = .chat) -> Bool {
        !load(provider: provider, role: role)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    static func save(_ value: String, provider: String, role: LLMKeyRole = .chat) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: role.account(provider: provider),
        ]
        if value.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let encoded = Data(value.utf8)
        let updated = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: encoded] as CFDictionary
        )
        if updated == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = encoded
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

/// `GET /v1/models` — proves the key and lists chat models that key can use.
enum OpenAIKeyVerifier {
    private static let endpoint = URL(string: "https://api.openai.com/v1/models")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    struct Outcome {
        var status: LLMKeyStatus
        var chatModels: [String]
        var transcriptionModels: [String]
    }

    /// `nil` if the caller cancelled mid-flight.
    static func verify(_ key: String) async -> Outcome? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            if Task.isCancelled { return nil }
            guard let http = response as? HTTPURLResponse else {
                return Outcome(status: .unreachable, chatModels: [], transcriptionModels: [])
            }
            #if DEBUG
            NSLog("[byollm] verify HTTP %d", http.statusCode)
            #endif
            switch http.statusCode {
            case 200..<300:
                let parsed = parseModels(from: data)
                return Outcome(
                    status: .connected,
                    chatModels: parsed.chat,
                    transcriptionModels: parsed.transcription
                )
            case 429:
                return Outcome(
                    status: .connected,
                    chatModels: [],
                    transcriptionModels: []
                )
            case 401, 403:
                return Outcome(status: .rejected, chatModels: [], transcriptionModels: [])
            default:
                return Outcome(status: .unreachable, chatModels: [], transcriptionModels: [])
            }
        } catch is CancellationError {
            return nil
        } catch {
            if Task.isCancelled { return nil }
            return Outcome(status: .unreachable, chatModels: [], transcriptionModels: [])
        }
    }

    private struct ModelsList: Decodable {
        struct Item: Decodable { var id: String }
        var data: [Item]
    }

    private static func parseModels(from data: Data) -> (chat: [String], transcription: [String]) {
        guard let list = try? JSONDecoder().decode(ModelsList.self, from: data) else {
            return ([], [])
        }
        let ids = list.data.map(\.id)
        return (
            ordered(ids.filter(isChatModel), preferring: AppSettings.defaultLLMModel),
            ordered(
                ids.filter(isTranscriptionModel),
                preferring: AppSettings.defaultTranscriptionModel
            )
        )
    }

    private static func ordered(_ ids: [String], preferring preferred: String) -> [String] {
        var ordered = Array(Set(ids)).sorted()
        if let index = ordered.firstIndex(of: preferred) {
            ordered.remove(at: index)
            ordered.insert(preferred, at: 0)
        }
        return ordered
    }

    /// Chat Completions models only — skip Whisper, TTS, images, embeddings.
    private static func isChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        let blocked = [
            "whisper", "tts", "dall-e", "dalle", "embedding", "moderation",
            "transcribe", "audio", "realtime", "babbage", "davinci", "sora",
            "image", "codex", "computer-use", "gpt-image", "omni-moderation",
            "text-similarity", "text-search", "text-ada", "curie",
        ]
        if blocked.contains(where: { lower.contains($0) }) { return false }
        if lower.hasPrefix("gpt-") { return true }
        if lower.hasPrefix("chatgpt") { return true }
        if lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4") {
            return true
        }
        return false
    }

    /// File-upload transcription models. Skip live/realtime sockets and diarize.
    private static func isTranscriptionModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        if lower.contains("tts") { return false }
        if lower.contains("live") || lower.contains("realtime") || lower.contains("diarize") {
            return false
        }
        return lower.contains("whisper") || lower.contains("transcribe")
    }
}

/// `GET /v1/models` — proves an Anthropic key and lists Claude models.
enum ClaudeKeyVerifier {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/models")!
    private static let apiVersion = "2023-06-01"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    struct Outcome {
        var status: LLMKeyStatus
        var models: [String]
    }

    /// `nil` if the caller cancelled mid-flight.
    static func verify(_ key: String) async -> Outcome? {
        var models: [String] = []
        var after: String?
        for _ in 0..<10 {
            if Task.isCancelled { return nil }
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
            var items = [URLQueryItem(name: "limit", value: "100")]
            if let after { items.append(URLQueryItem(name: "after_id", value: after)) }
            components?.queryItems = items
            guard let url = components?.url else {
                return Outcome(status: .unreachable, models: [])
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await session.data(for: request)
                if Task.isCancelled { return nil }
                guard let http = response as? HTTPURLResponse else {
                    return Outcome(status: .unreachable, models: [])
                }
                #if DEBUG
                NSLog("[byocld] verify HTTP %d", http.statusCode)
                #endif
                switch http.statusCode {
                case 200..<300:
                    let page = parsePage(from: data)
                    models.append(contentsOf: page.ids)
                    if page.hasMore, let last = page.lastID, last != after {
                        after = last
                        continue
                    }
                    return Outcome(
                        status: .connected,
                        models: ordered(models, preferring: AppSettings.defaultClaudeModel)
                    )
                case 429:
                    return Outcome(status: .connected, models: [])
                case 401, 403:
                    return Outcome(status: .rejected, models: [])
                default:
                    return Outcome(status: .unreachable, models: [])
                }
            } catch is CancellationError {
                return nil
            } catch {
                if Task.isCancelled { return nil }
                return Outcome(status: .unreachable, models: [])
            }
        }
        return Outcome(
            status: .connected,
            models: ordered(models, preferring: AppSettings.defaultClaudeModel)
        )
    }

    private struct ModelsPage: Decodable {
        struct Item: Decodable { var id: String }
        var data: [Item]
        var has_more: Bool?
        var last_id: String?
    }

    private static func parsePage(from data: Data) -> (ids: [String], hasMore: Bool, lastID: String?) {
        guard let page = try? JSONDecoder().decode(ModelsPage.self, from: data) else {
            return ([], false, nil)
        }
        let ids = page.data.map(\.id).filter(isClaudeModel)
        return (ids, page.has_more == true, page.last_id)
    }

    /// Keep Messages-API Claude IDs; drop anything that isn't a Claude model.
    private static func isClaudeModel(_ id: String) -> Bool {
        id.lowercased().hasPrefix("claude")
    }

    /// API order is newest-first; pin the default to the top when the key has it.
    private static func ordered(_ ids: [String], preferring preferred: String) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        for id in ids where seen.insert(id).inserted {
            unique.append(id)
        }
        if let index = unique.firstIndex(of: preferred) {
            unique.remove(at: index)
            unique.insert(preferred, at: 0)
        }
        return unique
    }
}

private struct StoredBYOKKey: Identifiable {
    var id: String
    var title: String
    var usedFor: String
    var markName: String
    var rendersAsTemplate: Bool
    var provider: String
    var role: LLMKeyRole
}

/// Setup cards: LLM and transcription. Separate Keychain keys; transcription
/// reuses the LLM key until you set one of its own.
struct BringYourOwnLLMSettings: View {
    @AppStorage(AppSettings.bringYourOwnLLMEnabledKey) private var enabled = false
    @AppStorage(AppSettings.bringYourOwnTranscriptionEnabledKey) private var transcriptionEnabled = false
    @AppStorage(AppSettings.llmProviderKey) private var providerRaw = LLMProvider.openAI.rawValue
    @AppStorage(AppSettings.llmModelKey) private var selectedModel = AppSettings.defaultLLMModel
    @AppStorage(AppSettings.transcriptionModelKey)
    private var selectedTranscriptionModel = AppSettings.defaultTranscriptionModel
    @State private var apiKey = ""
    @State private var transcriptionAPIKey = ""
    @State private var llmStatus: LLMKeyStatus = .idle
    @State private var transcriptionStatus: LLMKeyStatus = .idle
    @State private var availableModels: [String] = []
    @State private var transcriptionModels: [String] = []
    @State private var llmVerifyTask: Task<Void, Never>?
    @State private var transcriptionVerifyTask: Task<Void, Never>?
    @State private var isEditingTranscriptionKey = false
    @State private var transcriptionKeyFocusTick = 0
    @State private var transcriptionProviderRaw = LLMProvider.openAI.rawValue
    @State private var keyListEpoch = 0
    @State private var generationHint: String?

    private var provider: LLMProvider {
        LLMProvider(rawValue: providerRaw) ?? .openAI
    }

    private var trimmedLLMKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedTranscriptionKey: String {
        transcriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasLLMKey: Bool { !trimmedLLMKey.isEmpty }

    private var hasOwnTranscriptionKey: Bool { !trimmedTranscriptionKey.isEmpty }

    private var hasOpenAIChatKey: Bool {
        if provider == .openAI { return hasLLMKey }
        return !LLMAPIKeyStore.load(provider: LLMProvider.openAI.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var effectiveTranscriptionKey: String {
        if hasOwnTranscriptionKey { return trimmedTranscriptionKey }
        if provider == .openAI { return trimmedLLMKey }
        return LLMAPIKeyStore.load(provider: LLMProvider.openAI.rawValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showTranscriptionKeyField: Bool {
        hasOwnTranscriptionKey || isEditingTranscriptionKey || !hasOpenAIChatKey
    }

    private var statusLine: String {
        if let generationHint { return generationHint }
        switch llmStatus {
        case .idle:
            return "Notes are sent to \(provider.title) when you Enhance or Ask."
        case .checking:
            return "Checking key"
        case .connected:
            return "Connected. Notes are sent to \(provider.title) when you Enhance or Ask."
        case .rejected:
            return "That key was rejected."
        case .unreachable:
            return provider == .claude ? "Couldn't reach Anthropic." : "Couldn't reach OpenAI."
        }
    }

    private var transcriptionStatusLine: String {
        switch transcriptionStatus {
        case .idle:
            return "Microphone and meeting audio are sent to OpenAI while this is on."
        case .checking:
            return "Checking key"
        case .connected:
            return "Connected. Microphone and meeting audio are sent to OpenAI."
        case .rejected:
            return "That key was rejected."
        case .unreachable:
            return "Couldn't reach OpenAI."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            llmCard
            transcriptionCard
            savedKeysCard
        }
        .onAppear {
            apiKey = LLMAPIKeyStore.load(provider: provider.rawValue)
            transcriptionAPIKey = LLMAPIKeyStore.load(
                provider: LLMProvider.openAI.rawValue,
                role: .transcription
            )
            if enabled {
                if LLMRouting.lastGenerationError != nil {
                    applyGenerationFailure(LLMRouting.lastGenerationError)
                } else {
                    scheduleLLMVerify(apiKey)
                }
            }
            if transcriptionEnabled { scheduleTranscriptionVerify() }
        }
        .onDisappear {
            llmVerifyTask?.cancel()
            transcriptionVerifyTask?.cancel()
        }
        .onChange(of: selectedModel) { _, _ in
            LLMRouting.notifySettingsChanged()
        }
        .onChange(of: apiKey) { _, new in
            LLMAPIKeyStore.save(new, provider: provider.rawValue)
            LLMRouting.notifySettingsChanged()
            LLMRouting.clearGenerationFailure()
            generationHint = nil
            keyListEpoch += 1
            if enabled { scheduleLLMVerify(new) }
            if transcriptionEnabled, provider == .openAI, !hasOwnTranscriptionKey {
                scheduleTranscriptionVerify()
            }
        }
        .onChange(of: providerRaw) { _, new in
            apiKey = LLMAPIKeyStore.load(provider: new)
            LLMRouting.notifySettingsChanged()
            LLMRouting.clearGenerationFailure()
            generationHint = nil
            if enabled { scheduleLLMVerify(apiKey) }
        }
        .onChange(of: transcriptionAPIKey) { _, new in
            LLMAPIKeyStore.save(new, provider: LLMProvider.openAI.rawValue, role: .transcription)
            keyListEpoch += 1
            if transcriptionEnabled { scheduleTranscriptionVerify() }
        }
        .onChange(of: enabled) { _, on in
            LLMRouting.notifySettingsChanged()
            if on {
                if LLMRouting.lastGenerationError != nil {
                    applyGenerationFailure(LLMRouting.lastGenerationError)
                } else {
                    scheduleLLMVerify(apiKey)
                }
            } else {
                llmVerifyTask?.cancel()
                llmStatus = .idle
                availableModels = []
            }
        }
        .onChange(of: transcriptionEnabled) { _, on in
            if on {
                scheduleTranscriptionVerify()
            } else {
                transcriptionVerifyTask?.cancel()
                transcriptionStatus = .idle
                transcriptionModels = []
                isEditingTranscriptionKey = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .threadLLMGenerationDidFail)) { note in
            applyGenerationFailure(note.object as? OpenAIChatError)
        }
    }

    private func applyGenerationFailure(_ error: OpenAIChatError?) {
        guard enabled else { return }
        generationHint = nil
        switch error {
        case .rejected:
            llmStatus = .rejected
        case .quotaExceeded:
            llmStatus = .unreachable
            generationHint = "This API key is out of credit. Add billing in the provider console."
        case .rateLimited:
            llmStatus = .unreachable
            generationHint = "The API rate-limited the request. Try again in a moment."
        case .unreachable(let detail):
            llmStatus = .unreachable
            if !detail.isEmpty { generationHint = detail }
        default:
            llmStatus = .unreachable
        }
    }

    private var llmCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bring Your Own LLM")
                        .font(.system(size: 13, weight: .semibold))
                    Text(enabled
                         ? "Enhance and Ask use this Keychain key instead of Apple Intelligence. Turning this off keeps the key in Keychain."
                         : "Use your own API key instead of Apple Intelligence. The key stays in Keychain if you turn this off.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("Bring Your Own LLM", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(SetupToggleStyle())
            }

            if enabled {
                Divider().opacity(0.35)
                LLMKeyPill(
                    providerRaw: $providerRaw,
                    apiKey: $apiKey,
                    status: llmStatus,
                    onRetry: { scheduleLLMVerify(apiKey, delay: false) }
                )
                if llmStatus == .connected, !availableModels.isEmpty {
                    LLMModelPicker(
                        selectedModel: $selectedModel,
                        models: availableModels,
                        caption: "Used for Enhance and Ask.",
                        accessibilityName: provider == .claude ? "Anthropic model" : "OpenAI model"
                    )
                }
                Text(statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(llmStatus == .rejected || llmStatus == .unreachable
                                     || generationHint != nil
                                     ? Color(nsColor: .systemRed)
                                     : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .byoSetupCard()
    }

    private var transcriptionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bring Your Own Transcription")
                        .font(.system(size: 13, weight: .semibold))
                    Text(transcriptionEnabled
                         ? "Live transcription uses OpenAI instead of on-device speech. Turning this off keeps the key in Keychain."
                         : "Use your own API key instead of on-device speech. The key stays in Keychain if you turn this off.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("Bring Your Own Transcription", isOn: $transcriptionEnabled)
                    .labelsHidden()
                    .toggleStyle(SetupToggleStyle())
            }

            if transcriptionEnabled {
                Divider().opacity(0.35)
                LLMKeyPill(
                    providerRaw: $transcriptionProviderRaw,
                    apiKey: $transcriptionAPIKey,
                    status: transcriptionStatus,
                    showsKeyField: showTranscriptionKeyField,
                    reusedKeyLabel: "Using your OpenAI key from Keychain, double click to change this",
                    allowedProviders: [.openAI],
                    focusTick: transcriptionKeyFocusTick,
                    onRetry: { scheduleTranscriptionVerify(delay: false) },
                    onRequestEdit: {
                        isEditingTranscriptionKey = true
                        transcriptionKeyFocusTick += 1
                    },
                    onEndEditing: {
                        isEditingTranscriptionKey = false
                    }
                )
                if transcriptionStatus == .connected, !transcriptionModels.isEmpty {
                    LLMModelPicker(
                        selectedModel: $selectedTranscriptionModel,
                        models: transcriptionModels,
                        caption: "Used for live transcription.",
                        accessibilityName: "Transcription model"
                    )
                }
                Text(transcriptionStatusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(transcriptionStatus == .rejected || transcriptionStatus == .unreachable
                                     ? Color(nsColor: .systemRed)
                                     : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .byoSetupCard()
    }

    private var savedKeysCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved Keys")
                    .font(.system(size: 13, weight: .semibold))
                Text("Turning a toggle off keeps the key in Keychain. Remove from Mac deletes it from Keychain here. It does not revoke the key at OpenAI or Anthropic.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if storedKeyRows.isEmpty {
                Text("None stored yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Divider().opacity(0.35)
                ForEach(Array(storedKeyRows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().opacity(0.35) }
                    HStack(alignment: .center, spacing: 12) {
                        Image(row.markName)
                            .renderingMode(row.rendersAsTemplate ? .template : .original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 13, height: 13)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(row.usedFor)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Button("Remove from Mac") { removeStoredKey(row) }
                            .controlSize(.small)
                            .help("Deletes this key from Keychain on this Mac. Does not revoke it at OpenAI or Anthropic.")
                            .accessibilityLabel("Remove \(row.title) key from Keychain")
                            .accessibilityHint("Does not revoke the key at OpenAI or Anthropic.")
                    }
                }
            }
        }
        .byoSetupCard()
    }

    private var storedKeyRows: [StoredBYOKKey] {
        _ = keyListEpoch
        let hasOpenAI = LLMAPIKeyStore.isPresent(provider: LLMProvider.openAI.rawValue)
        let hasClaude = LLMAPIKeyStore.isPresent(provider: LLMProvider.claude.rawValue)
        let hasSTT = LLMAPIKeyStore.isPresent(
            provider: LLMProvider.openAI.rawValue,
            role: .transcription
        )
        var rows: [StoredBYOKKey] = []
        if hasOpenAI {
            rows.append(
                StoredBYOKKey(
                    id: "openai.chat",
                    title: "OpenAI",
                    usedFor: hasSTT
                        ? "Enhance and Ask"
                        : "Enhance and Ask. Transcription uses this Keychain key unless you set a separate one.",
                    markName: LLMProvider.openAI.markName,
                    rendersAsTemplate: LLMProvider.openAI.rendersAsTemplate,
                    provider: LLMProvider.openAI.rawValue,
                    role: .chat
                )
            )
        }
        if hasClaude {
            rows.append(
                StoredBYOKKey(
                    id: "claude.chat",
                    title: "Anthropic",
                    usedFor: "Enhance and Ask",
                    markName: LLMProvider.claude.markName,
                    rendersAsTemplate: LLMProvider.claude.rendersAsTemplate,
                    provider: LLMProvider.claude.rawValue,
                    role: .chat
                )
            )
        }
        if hasSTT {
            rows.append(
                StoredBYOKKey(
                    id: "openai.stt",
                    title: "OpenAI Transcription",
                    usedFor: "Live transcription. This is a separate Keychain key from Enhance and Ask.",
                    markName: LLMProvider.openAI.markName,
                    rendersAsTemplate: LLMProvider.openAI.rendersAsTemplate,
                    provider: LLMProvider.openAI.rawValue,
                    role: .transcription
                )
            )
        }
        return rows
    }

    private func removeStoredKey(_ row: StoredBYOKKey) {
        LLMAPIKeyStore.save("", provider: row.provider, role: row.role)
        switch row.role {
        case .chat:
            if provider.rawValue == row.provider { apiKey = "" }
        case .transcription:
            transcriptionAPIKey = ""
        }
        keyListEpoch += 1
        LLMRouting.notifySettingsChanged()
        if row.role == .chat, row.provider == LLMProvider.openAI.rawValue,
           transcriptionEnabled, !hasOwnTranscriptionKey {
            scheduleTranscriptionVerify()
        }
    }

    private func scheduleLLMVerify(_ key: String, delay: Bool = true) {
        llmVerifyTask?.cancel()
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !trimmed.isEmpty else {
            llmStatus = .idle
            availableModels = []
            return
        }
        llmStatus = .idle
        generationHint = nil
        availableModels = []
        llmVerifyTask = Task { @MainActor in
            if delay {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            llmStatus = .checking
            switch provider {
            case .openAI:
                let result = await OpenAIKeyVerifier.verify(trimmed)
                guard !Task.isCancelled, let result else { return }
                llmStatus = result.status
                if result.status == .connected {
                    LLMRouting.clearGenerationFailure()
                    generationHint = nil
                    adoptChat(result.chatModels)
                } else {
                    availableModels = []
                }
            case .claude:
                let result = await ClaudeKeyVerifier.verify(trimmed)
                guard !Task.isCancelled, let result else { return }
                llmStatus = result.status
                if result.status == .connected {
                    LLMRouting.clearGenerationFailure()
                    generationHint = nil
                    adoptChat(result.models)
                } else {
                    availableModels = []
                }
            }
        }
    }

    private func scheduleTranscriptionVerify(delay: Bool = true) {
        transcriptionVerifyTask?.cancel()
        let trimmed = effectiveTranscriptionKey
        guard transcriptionEnabled, !trimmed.isEmpty else {
            transcriptionStatus = .idle
            transcriptionModels = []
            return
        }
        transcriptionStatus = .idle
        transcriptionModels = []
        transcriptionVerifyTask = Task { @MainActor in
            if delay {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            transcriptionStatus = .checking
            let result = await OpenAIKeyVerifier.verify(trimmed)
            guard !Task.isCancelled, let result else { return }
            transcriptionStatus = result.status
            if result.status == .connected {
                adoptTranscription(result.transcriptionModels)
            } else {
                transcriptionModels = []
            }
        }
    }

    private func adoptChat(_ models: [String]) {
        availableModels = models
        guard !models.isEmpty else { return }
        if models.contains(selectedModel) { return }
        selectedModel = models.contains(preferredChatModel)
            ? preferredChatModel
            : models[0]
    }

    private var preferredChatModel: String {
        switch provider {
        case .openAI: return AppSettings.defaultLLMModel
        case .claude: return AppSettings.defaultClaudeModel
        }
    }

    private func adoptTranscription(_ models: [String]) {
        transcriptionModels = models
        guard !models.isEmpty else { return }
        if models.contains(selectedTranscriptionModel) { return }
        selectedTranscriptionModel = models.contains(AppSettings.defaultTranscriptionModel)
            ? AppSettings.defaultTranscriptionModel
            : models[0]
    }
}

private struct LLMModelPicker: View {
    @Binding var selectedModel: String
    var models: [String]
    var caption: String
    var accessibilityName: String

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Model")
                    .font(.system(size: 13, weight: .semibold))
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Picker("Model", selection: $selectedModel) {
                ForEach(models, id: \.self) { id in
                    Text(id).tag(id)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(accessibilityName)
        }
    }
}

/// Capsule field: provider menu on the left, API key on the right, split by a hairline.
private struct LLMKeyPill: View {
    @Binding var providerRaw: String
    @Binding var apiKey: String
    var status: LLMKeyStatus
    var showsKeyField: Bool = true
    var reusedKeyLabel: String = "Using your OpenAI key from Keychain, double click to change this"
    var allowedProviders: [LLMProvider] = LLMProvider.allCases
    var focusTick: Int = 0
    var onRetry: () -> Void
    var onRequestEdit: (() -> Void)? = nil
    var onEndEditing: (() -> Void)? = nil

    private var provider: LLMProvider {
        LLMProvider(rawValue: providerRaw) ?? .openAI
    }

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(allowedProviders) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 4) {
                    Image(provider.markName)
                        .renderingMode(provider.rendersAsTemplate ? .template : .original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("LLM provider")
            .help(provider.title)

            Rectangle()
                .fill(.primary.opacity(0.18))
                .frame(width: 1, height: 14)

            if showsKeyField {
                LLMAPIKeyField(
                    text: $apiKey,
                    focusTick: focusTick,
                    onEndEditing: { onEndEditing?() }
                )
                .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18)
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .padding(.vertical, 7)
            } else {
                Text(reusedKeyLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .padding(.trailing, 6)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onRequestEdit?() }
                    .help("Double-click to use a different OpenAI key")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Double-click to use a different OpenAI key")
                    .accessibilityAction(named: "Change API key") { onRequestEdit?() }
            }

            // Always occupy this slot so check/x/ellipsis never restretch the pill.
            LLMKeyStatusGlyph(status: status, onRetry: onRetry)
                .padding(.trailing, 10)
        }
        .background {
            Capsule(style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct LLMKeyStatusGlyph: View {
    var status: LLMKeyStatus
    var onRetry: () -> Void

    var body: some View {
        Group {
            switch status {
            case .idle:
                EmptyView()
            case .checking:
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Checking key")
            case .connected:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(nsColor: .systemGreen))
                    .accessibilityLabel("Key connected")
            case .rejected, .unreachable:
                Button(action: onRetry) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(nsColor: .systemRed))
                }
                .buttonStyle(.plain)
                .help("Try again")
                .accessibilityLabel("Key check failed, try again")
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// Borderless secure field. Paste in is allowed; the system secure field
/// does not put the key on the pasteboard. Intrinsic width is unset so typing
/// a long key cannot restretch the window's Auto Layout pass.
private struct LLMAPIKeyField: NSViewRepresentable {
    @Binding var text: String
    var focusTick: Int = 0
    var onEndEditing: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> LLMAPIKeySecureField {
        let field = LLMAPIKeySecureField()
        field.placeholderString = "API key"
        field.stringValue = text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("API key")
        return field
    }

    func updateNSView(_ nsView: LLMAPIKeySecureField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            context.coordinator.isApplying = true
            nsView.stringValue = text
            context.coordinator.isApplying = false
        }
        if focusTick != context.coordinator.lastFocusTick {
            context.coordinator.lastFocusTick = focusTick
            if focusTick > 0 {
                DispatchQueue.main.async {
                    nsView.window?.makeFirstResponder(nsView)
                }
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LLMAPIKeyField
        var isApplying = false
        var lastFocusTick = 0
        private var clickMonitor: Any?
        init(_ parent: LLMAPIKeyField) { self.parent = parent }

        deinit { removeClickMonitor() }

        func controlTextDidChange(_ obj: Notification) {
            guard !isApplying, let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            installClickMonitor(for: obj.object as? NSTextField)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            removeClickMonitor()
            parent.onEndEditing?()
        }

        private func installClickMonitor(for field: NSTextField?) {
            removeClickMonitor()
            guard let field else { return }
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
                guard let window = field.window, event.window === window else { return event }
                if Self.event(event, isInside: field) { return event }
                window.makeFirstResponder(nil)
                return event
            }
        }

        private func removeClickMonitor() {
            if let clickMonitor {
                NSEvent.removeMonitor(clickMonitor)
                self.clickMonitor = nil
            }
        }

        private static func event(_ event: NSEvent, isInside field: NSTextField) -> Bool {
            guard let hit = field.window?.contentView?.hitTest(event.locationInWindow) else {
                return false
            }
            if hit === field || hit.isDescendant(of: field) { return true }
            if let editor = field.currentEditor(),
               hit === editor || hit.isDescendant(of: editor) {
                return true
            }
            return false
        }
    }
}

private final class LLMAPIKeySecureField: NSSecureTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 18)
    }

    override func cancelOperation(_ sender: Any?) {
        window?.makeFirstResponder(nil)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let command = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command)
        if command,
           let chars = event.charactersIgnoringModifiers?.lowercased(),
           chars == "c" || chars == "x" {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private extension View {
    func byoSetupCard() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassEffect(AppAppearance.glass(), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
            }
    }
}
