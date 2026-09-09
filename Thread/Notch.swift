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
import Combine

/// Layout constants for the notch band and its expanded chat panel.
enum NotchMetrics {
    /// How far the band reaches left and right beyond the physical notch when
    /// idle: narrow, just the mic and a notepad button in the ears.
    static let sidePadding: CGFloat = 52
    /// Wider ears while recording, so the running timer fits on the left and the
    /// notepad + chat pair fits on the right without crowding the notch.
    static let recordingSidePadding: CGFloat = 86
    /// How far the band drops below the notch when collapsed — the visible strip.
    static let drop: CGFloat = 14
    /// Radius of the band's two bottom corners; the top corners stay square so
    /// the band is flush with the screen edge.
    static let bottomRadius: CGFloat = 16
    /// Width of the expanded chat panel.
    static let expandedWidth: CGFloat = 560
    /// Height of just the input row below the control row (before an answer).
    static let chatInputHeight: CGFloat = 52
    /// Height of the chat body once an answer is streaming in.
    static let chatBodyHeight: CGFloat = 240
    /// Height of the recording-consent body below the control row.
    static let consentBodyHeight: CGFloat = 226
    /// Fallback size for Macs without a physical notch: a centered top pill.
    static let fallbackWidth: CGFloat = 200
    static let fallbackHeight: CGFloat = 34
}

/// Physical notch geometry of the built-in display, mirrored from Gradient's
/// native overlay: the width is the gap between the two auxiliary top areas and
/// the height is the top safe-area inset. Falls back to a centered pill on Macs
/// without a notch.
struct NotchGeometry {
    let screen: NSScreen
    let width: CGFloat
    let height: CGFloat
    let hasNotch: Bool

    static func current() -> NotchGeometry? {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        guard let screen = notched ?? NSScreen.main else { return nil }

        let insetTop = screen.safeAreaInsets.top
        var width: CGFloat = 0
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           left.width > 0, right.width > 0 {
            width = right.minX - left.maxX
        }

        let hasNotch = insetTop > 0 && width > 0
        if hasNotch {
            return NotchGeometry(screen: screen, width: width,
                                 height: insetTop, hasNotch: true)
        }
        return NotchGeometry(screen: screen,
                             width: NotchMetrics.fallbackWidth,
                             height: NotchMetrics.fallbackHeight,
                             hasNotch: false)
    }
}

/// The band shape: a rounded-bottom rectangle whose top edge sits flush with the
/// screen so it merges with the physical notch. Mirrors the bottom-rounded path
/// from Gradient's `native_overlay.mm`.
struct NotchShape: Shape {
    var bottomRadius: CGFloat = NotchMetrics.bottomRadius

    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, rect.height, rect.width / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))          // top-left
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))       // top-right
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// What the notch is currently showing. One published value drives both the panel
/// size and which content the view builds.
enum NotchMode: Equatable {
    case collapsed          // just the two controls in the ears
    case consent            // recording consent, before capture starts
    case chatInput          // narrow input, no question asked yet
    case chatAnswer         // widened panel with the question bubble + answer
}

/// Shared state for the notch overlay: live app references it drives (recording
/// toggle, note-scoped chat) plus the ephemeral chat UI that clears on collapse.
@MainActor
final class NotchModel: ObservableObject {
    /// Bumped by the notch's record button to stop an active recording; observed
    /// by `ContentView` so stop runs through the same path as the toolbar button.
    @Published var recordToggleTick = 0
    /// Bumped when the user confirms consent in the notch; `ContentView` observes
    /// it and starts capture (mirroring `confirmRecordingStart`).
    @Published var confirmRecordTick = 0

    @Published var mode: NotchMode = .collapsed
    @Published var query = ""
    /// The question actually sent, shown as a right-aligned bubble above the answer.
    @Published var submittedQuery = ""
    @Published var answer = ""
    @Published var errorText: String?
    @Published var isAnswering = false

    // Injected from ContentView once its stores exist.
    var capture: AudioCaptureController?
    var engine: AskEngine?
    var store: SessionStore?

    /// Where the notch keys its conversation when no meeting is live yet, so the
    /// model still gets a real, coherent note rather than a throwaway path (which
    /// left the task tools pointed at a nonexistent file and derailed the answer).
    private static let draftKey = URL(fileURLWithPath: "/thread/notch/draft")
    /// The key used for the turn in flight, remembered so collapse can forget it.
    private var conversationKey: URL?
    private var askTask: Task<Void, Never>?

    /// Record button tapped: stop if recording, otherwise ask for consent first.
    func recordTapped(isRecording: Bool) {
        if isRecording {
            stopRecording()
        } else {
            mode = .consent
        }
    }

    /// Stops the live recording. Prefer the window path so `ContentView` stays
    /// coordinated; when the window is closed, drive capture directly so the notch
    /// still works while recording continues headless.
    private func stopRecording() {
        if NotchController.shared.hasMainWindow {
            recordToggleTick &+= 1
        } else if capture?.isActive == true {
            capture?.stop()
        }
    }

    /// Consent confirmed in the notch — start capture and collapse back to the band.
    func confirmConsent() {
        if NotchController.shared.hasMainWindow {
            confirmRecordTick &+= 1
        } else {
            // No window is listening: start capture ourselves. A notch-initiated
            // start is always a new session, never an append.
            capture?.appendTarget = nil
            capture?.appendBaseTranscript = nil
            capture?.start()
        }
        mode = .collapsed
    }

    func openChat() {
        answer = ""
        errorText = nil
        query = ""
        submittedQuery = ""
        mode = .chatInput
    }

    /// Collapses the notch from any mode and clears the ephemeral chat state. The
    /// model's memory goes with it: a live meeting keeps its own thread, but a
    /// draft conversation the notch started is forgotten so nothing lingers.
    func dismiss() {
        askTask?.cancel()
        askTask = nil
        if conversationKey == Self.draftKey { engine?.forgetNoteConversation(Self.draftKey) }
        conversationKey = nil
        query = ""
        submittedQuery = ""
        answer = ""
        errorText = nil
        isAnswering = false
        mode = .collapsed
    }

    func submit() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let engine, let capture else { return }
        // Scope to the live meeting note when there is one — real title, notes,
        // transcript and tasks — else a stable draft note, never a random path.
        let key = store?.liveURL ?? Self.draftKey
        conversationKey = key
        let evidence = Self.evidence(from: capture)

        answer = ""
        errorText = nil
        isAnswering = true
        submittedQuery = text
        query = ""
        mode = .chatAnswer
        askTask?.cancel()
        askTask = Task { @MainActor [weak self] in
            for await event in engine.askNote(text, note: key, evidence: evidence) {
                guard let self, !Task.isCancelled else { break }
                switch event {
                case .answer(let partial): self.answer = partial
                case .failed(let message): self.errorText = message
                case .sources: break
                }
            }
            self?.isAnswering = false
        }
    }

    /// Assembles the note-scoped evidence exactly like the in-app mid-meeting Ask
    /// bar: this meeting's transcript, its typed notes, and the sentence in flight.
    static func evidence(from capture: AudioCaptureController) -> AskEngine.NoteEvidence {
        let transcript = capture.entries
            .map { entry -> String in
                if let name = entry.speakerName,
                   !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "\(name): \(entry.text)"
                }
                return "\(entry.speaker.rawValue): \(entry.text)"
            }
            .joined(separator: "\n")

        var pending: [String] = []
        if !capture.youVolatile.isEmpty {
            pending.append("\(capture.localUserName ?? "You"): \(capture.youVolatile)")
        }
        if !capture.meetingVolatile.isEmpty {
            pending.append("\(capture.meetingVolatileSpeaker ?? "Meeting"): \(capture.meetingVolatile)")
        }

        return AskEngine.NoteEvidence(
            title: "This meeting",
            notes: capture.notes,
            transcript: transcript,
            pending: capture.isActive ? pending.joined(separator: "\n") : "",
            isRecording: capture.isActive)
    }
}

/// A borderless panel that can take keyboard focus for the chat field without
/// activating the app, so typing works but Zoom/Meet keeps the foreground.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The recording control in the left "ear": mirrors the toolbar `RecordButton`'s
/// glyphs (animated red waveform while recording, accent mic when idle) and adds a
/// running timer.
private struct NotchRecordButton: View {
    @ObservedObject var capture: AudioCaptureController
    let toggle: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Group {
                    if capture.isActive {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                            .foregroundStyle(.red)
                    } else {
                        Image(systemName: "waveform.badge.mic")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 26, height: 26)
                .background { if scheme == .dark { Circle().fill(.white.opacity(0.75)) } }

                if capture.isActive {
                    Text(capture.startedAt ?? Date(), style: .timer)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(capture.isActive ? "Stop" : "Start")
    }
}

/// The chat control in the right "ear", shown only while recording: opens/closes
/// the note-scoped Ask panel using the app's "Ask AI" `message` glyph.
private struct NotchChatButton: View {
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isOpen ? "xmark" : "message")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isOpen ? .secondary : .primary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOpen ? "Close" : "Ask AI")
    }
}

/// The right "ear" control when idle: brings the main Thread window to the front.
private struct NotchNotepadButton: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Image(systemName: "note.text")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Thread")
    }
}

private extension View {
    /// Insets the body onto a rounded panel drawn over the notch's outer liquid
    /// band. The blur lives here — the same clear desktop frost the main app's
    /// `pageGlassBackground` uses — so the inner panel reads as transparent glass
    /// rather than a flat sheet, while the outer band stays a clean liquid outline.
    @ViewBuilder
    func notchInnerPanel() -> some View {
        let radius = DetailPanel.radius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        background {
            Group {
                if AppAppearance.liquidGlass {
                    VisualEffectView(material: .underWindowBackground)
                        .opacity(0.7)
                        .glassEffect(.clear, in: .rect(cornerRadius: radius))
                } else {
                    VisualEffectView(material: .sidebar)
                        .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.68))
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.primary.opacity(0.10), lineWidth: 0.5) }
            .padding(EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8))
        }
    }
}

/// The SwiftUI content hosted inside the overlay window.
struct NotchView: View {
    let geometry: NotchGeometry
    @ObservedObject var capture: AudioCaptureController
    @ObservedObject var model: NotchModel
    @FocusState private var chatFocused: Bool

    static func compactSize(for geo: NotchGeometry, recording: Bool) -> CGSize {
        let pad = recording ? NotchMetrics.recordingSidePadding : NotchMetrics.sidePadding
        return CGSize(width: geo.width + pad * 2,
                      height: geo.height + NotchMetrics.drop)
    }

    /// Chat open, no answer yet: only drops down for the input — same width as the
    /// recording band (chat only opens mid-recording), so opening it doesn't widen.
    static func inputSize(for geo: NotchGeometry) -> CGSize {
        CGSize(width: compactSize(for: geo, recording: true).width,
               height: geo.height + NotchMetrics.chatInputHeight)
    }

    /// Chat open with an answer streaming in: the full panel.
    static func answerSize(for geo: NotchGeometry) -> CGSize {
        CGSize(width: NotchMetrics.expandedWidth,
               height: geo.height + NotchMetrics.chatBodyHeight)
    }

    /// Recording consent panel.
    static func consentSize(for geo: NotchGeometry) -> CGSize {
        CGSize(width: NotchMetrics.expandedWidth,
               height: geo.height + NotchMetrics.consentBodyHeight)
    }

    static func size(for mode: NotchMode, geometry geo: NotchGeometry,
                     recording: Bool) -> CGSize {
        switch mode {
        case .collapsed: return compactSize(for: geo, recording: recording)
        case .consent: return consentSize(for: geo)
        case .chatInput: return inputSize(for: geo)
        case .chatAnswer: return answerSize(for: geo)
        }
    }

    var body: some View {
        let shape = NotchShape()
        let scrim = AppAppearance.liquidGlass ? 0.22 : 0.42
        VStack(spacing: 0) {
            // Collapsed, the controls center in the whole visible strip (notch +
            // drop) so they sit mid-band rather than riding up in the notch itself.
            // Expanded, the row stays at notch height so the panel sits right below.
            controlRow
                .frame(height: model.mode == .collapsed
                       ? geometry.height + NotchMetrics.drop
                       : geometry.height)
            switch model.mode {
            case .collapsed:
                EmptyView()
            case .consent:
                consentBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .notchInnerPanel()
            case .chatInput:
                // Input only: the liquid-glass pill floats on the band — no inner
                // panel behind it, so there's no dark frosted slab around the field.
                chatBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .chatAnswer:
                chatBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .notchInnerPanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            // Pure Liquid Glass band — no behind-window blur here; the blur lives on
            // the inset inner panel, so the outer reads as a clean liquid outline.
            shape
                .fill(Color(nsColor: .windowBackgroundColor).opacity(scrim))
                .glassEffect(AppAppearance.glass(), in: shape)
                .overlay { shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5) }
        }
        .ignoresSafeArea()
        .onExitCommand { if model.mode != .collapsed { model.dismiss() } }
        .onChange(of: capture.isActive) { _, active in
            // Chat belongs to the live meeting; if recording stops while it's open,
            // collapse it (which re-sizes the band). Otherwise starting/stopping
            // recording while collapsed swaps between the idle and recording widths.
            if !active, model.mode == .chatInput || model.mode == .chatAnswer {
                model.dismiss()
            } else {
                NotchController.shared.syncCollapsedSize()
            }
        }
    }

    private var controlRow: some View {
        // Consent is self-contained (its own Cancel / Start), so the ears stay
        // empty then — no record toggle or close button to compete with it.
        HStack(spacing: 0) {
            if model.mode != .consent {
                NotchRecordButton(capture: capture) {
                    model.recordTapped(isRecording: capture.isActive)
                }
            }
            Spacer(minLength: geometry.width * 0.5)
            rightControl
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// The right ear swaps by state: nothing during consent; a close button while
    /// the chat panel is open; while recording the notepad plus the meeting chat
    /// (notepad left of chat); otherwise just the notepad that surfaces the app.
    @ViewBuilder private var rightControl: some View {
        switch model.mode {
        case .consent:
            EmptyView()
        case .chatInput, .chatAnswer:
            NotchChatButton(isOpen: true) { model.dismiss() }
        case .collapsed:
            if capture.isActive {
                HStack(spacing: 10) {
                    NotchNotepadButton { NotchController.shared.openMainApp() }
                    NotchChatButton(isOpen: false) { model.openChat() }
                }
            } else {
                NotchNotepadButton { NotchController.shared.openMainApp() }
            }
        }
    }

    private var consentBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Get consent from everyone")
                    .font(.system(size: 13, weight: .semibold))
                Text("Before starting, notify everyone that:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                consentLine("This meeting is being recorded for transcription.")
                consentLine("No audio is retained.")
                consentLine("The transcript is processed and stored locally on this device only.")
                consentLine("Anyone may object at any time — if they do, stop immediately.")
                Text("Users are solely responsible for ensuring compliance with applicable local laws, including obtaining necessary consents prior to recording or summarizing audio/meetings.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel") { model.dismiss() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .keyboardShortcut(.cancelAction)
                    Button("I’ve notified everyone — Start") { model.confirmConsent() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
    }

    private func consentLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chatBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.mode == .chatAnswer {
                // The sent question, right-aligned as plain text (no bubble).
                Text(model.submittedQuery)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)

                ScrollView {
                    Text(model.errorText ?? model.answer)
                        .font(.system(size: 12))
                        .foregroundStyle(model.errorText != nil
                                         ? Color(nsColor: .systemRed) : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            // Always at the bottom: the first question and every follow-up land here.
            chatInputField
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 10)
        .animation(.easeInOut(duration: 0.22), value: model.mode)
        .onAppear { chatFocused = true }
    }

    /// A Liquid Glass pill for the first question and any follow-ups; sits at the
    /// foot of the panel below the streaming answer. Carries a light adaptive tint
    /// (dark in dark mode, light in light mode) so the typed text keeps its
    /// contrast — clear glass alone left white text invisible over a light desktop.
    private var chatInputField: some View {
        TextField("Ask anything about this meeting", text: $model.query)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .focused($chatFocused)
            .onSubmit { model.submit() }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.55), in: .capsule)
            .glassEffect(AppAppearance.glass(interactive: true), in: .capsule)
            .overlay { Capsule().strokeBorder(.primary.opacity(0.18), lineWidth: 0.5) }
    }
}

/// Owns a borderless panel pinned over the menu-bar notch, drives its show/expand
/// state, and keeps it aligned as displays and settings change.
@MainActor
final class NotchController {
    static let shared = NotchController()

    let model = NotchModel()
    private var panel: NotchPanel?
    private var screenObserver: NSObjectProtocol?
    private var modeCancellable: AnyCancellable?
    private var previousApp: NSRunningApplication?
    private var wasOpen = false

    private init() {
        modeCancellable = model.$mode
            .removeDuplicates()
            .sink { [weak self] mode in self?.applyMode(mode) }
    }

    var isVisible: Bool { panel != nil }

    /// Whether a main app window exists to observe the notch's record ticks. When
    /// false (window closed), the notch drives capture directly so recording can
    /// still be started/stopped from the notch while running headless.
    var hasMainWindow: Bool {
        NSApp.windows.contains { !($0 is NotchPanel) && $0.canBecomeMain }
    }

    /// Wires the overlay to the app's live stores. Call before showing.
    func attach(capture: AudioCaptureController, engine: AskEngine, store: SessionStore) {
        model.capture = capture
        model.engine = engine
        model.store = store
        if isVisible { rehost() }
    }

    /// Shows or hides the notch to match a stored preference.
    func setEnabled(_ enabled: Bool) {
        enabled ? show() : hide()
    }

    /// Brings the main Thread window to the front from the notch's notepad button.
    /// The panel is non-activating, so we activate explicitly; if the user closed
    /// the window, re-opening the app bundle triggers the standard reopen that
    /// recreates a WindowGroup window.
    func openMainApp() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: {
            !($0 is NotchPanel) && $0.canBecomeMain
        }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                               configuration: config)
        }
    }

    /// Re-renders the hosted view so a live change to Liquid Glass / theme is
    /// reflected without tearing the panel down.
    func refresh() {
        rehost()
        reposition()
    }

    func show() {
        guard panel == nil else { reposition(); return }
        guard let geometry = NotchGeometry.current(), let capture = model.capture else { return }

        let size = NotchView.compactSize(for: geometry, recording: capture.isActive)
        let panel = NotchPanel(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered,
                               defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces,
                                    .fullScreenAuxiliary,
                                    .stationary,
                                    .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Clickable controls, but it only takes keyboard focus when chat opens.
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false

        let host = NSHostingView(rootView: NotchView(geometry: geometry,
                                                     capture: capture,
                                                     model: model))
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        self.panel = panel

        reposition()
        panel.orderFrontRegardless()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
    }

    func hide() {
        model.dismiss()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Re-hosts the SwiftUI content (after attach or an appearance change).
    private func rehost() {
        guard let panel, let geometry = NotchGeometry.current(),
              let capture = model.capture else { return }
        if let host = panel.contentView as? NSHostingView<NotchView> {
            host.rootView = NotchView(geometry: geometry, capture: capture, model: model)
        }
    }

    /// Sizes the panel for the given mode and takes/returns keyboard focus on the
    /// open/close edge so typing never steals it mid-meeting.
    ///
    /// Uses the delivered `mode`, not the model getter: `@Published` fires in
    /// `willSet`, so `model.mode` still reads its old value here.
    private func applyMode(_ mode: NotchMode) {
        guard let panel, let geometry = NotchGeometry.current() else { return }
        let recording = model.capture?.isActive ?? false
        let frame = frameFor(NotchView.size(for: mode, geometry: geometry, recording: recording),
                             on: geometry.screen)
        let open = mode != .collapsed

        if open && !wasOpen { previousApp = NSWorkspace.shared.frontmostApplication }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }

        if open && !wasOpen {
            panel.makeKeyAndOrderFront(nil)
        } else if !open && wasOpen {
            _ = previousApp?.activate()
            previousApp = nil
        }
        wasOpen = open
    }

    /// Re-measures the notch and positions the panel over it at its current size.
    private func reposition() {
        guard let panel, let geometry = NotchGeometry.current() else { return }
        let recording = model.capture?.isActive ?? false
        let size = NotchView.size(for: model.mode, geometry: geometry, recording: recording)
        panel.setFrame(frameFor(size, on: geometry.screen), display: true)
    }

    /// Re-sizes the collapsed band when recording starts or stops, since the idle
    /// and recording widths differ but both live in the `.collapsed` mode.
    func syncCollapsedSize() {
        guard model.mode == .collapsed else { return }
        applyMode(.collapsed)
    }

    private func frameFor(_ size: CGSize, on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        return NSRect(x: frame.midX - size.width / 2,
                      y: frame.maxY - size.height,
                      width: size.width,
                      height: size.height)
    }

    /// Rebuilds after a display change, since the notched screen and its size may
    /// both differ.
    private func rebuild() {
        guard isVisible else { return }
        hide()
        show()
    }
}
