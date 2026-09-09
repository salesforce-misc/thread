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
import ApplicationServices
import UniformTypeIdentifiers

private enum PendingRecordingStart {
    case newSession
    case append(URL)
}

struct ContentView: View {
    // Process-lifetime services, owned by `ThreadApp` and injected here, so a
    // recording keeps running when the window closes and rebinds intact when it
    // reopens (rather than being replaced by a fresh, idle instance).
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var capture: AudioCaptureController
    @EnvironmentObject private var engine: AskEngine
    @StateObject private var search = SearchController()
    @StateObject private var glossary = Glossary()
    @StateObject private var enhanceTemplates = EnhanceTemplateStore()
    @StateObject private var notesSync = NotesSyncController()
    /// Shared state for the notch overlay; observed here so its record button can
    /// drive the same consent-aware start/stop as the toolbar's.
    @ObservedObject private var notchModel = NotchController.shared.model
    @State private var selection: SidebarItem? = .liveCurrent
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var pane: SessionPane = .transcript
    /// AI (sparkles) prompt panel floating over the detail area.
    @State private var showAI = false
    @State private var pendingRecordingStart: PendingRecordingStart?
    /// Incremented to ask the visible saved session to enhance its notes.
    @State private var enhanceTick = 0
    /// Incremented by ⌘L to open and focus the note's ask bar.
    @State private var askFocusTick = 0
    /// True while an AI note enhancement is running (drives the toolbar spinner).
    @State private var isEnhancing = false
    /// Glossary corrections detected by the last enhance, awaiting the user's
    /// confirmation. Non-empty → the right-side Glossary panel is shown.
    @State private var pendingCandidates: [GlossaryCandidate] = []
    /// True when the user opened the glossary to review *all* saved terms (as
    /// opposed to the post-enhance suggestion inbox).
    @State private var showAllTerms = false
    /// True when the Enhance template builder is docked on the right. Shares that
    /// side with Ask and the glossary.
    @State private var showTemplates = false
    /// True when the open note's tasks are docked on the right. Off at launch: the
    /// chip in the note header carries the count, and opening it is a choice.
    @State private var showNoteTasks = false
    /// True right after tapping New: show the expanded blank compose view (with
    /// Start in the top-right toolbar) instead of the compact idle window.
    /// Reset once a saved note is opened, so plain app-launch idle stays compact.
    @State private var composingNew = false
    /// The note just created by typing into a blank compose view — used to
    /// autofocus its editor after it promotes into a saved note.
    @State private var justPromotedURL: URL?
    /// True when the Setup surface is open. It replaces the detail area with an
    /// (empty for now) background; the folder sidebar stays put.
    @State private var showSetup = false
    /// Selection to restore when Back closes Setup. Setup temporarily clears the
    /// sidebar selection so clicking even the previously-open note selects it
    /// again and exits Setup.
    @State private var setupReturnSelection: SidebarItem?
    /// True when the central Tasks surface is open. Like Setup, it replaces the
    /// detail area with a glass panel while the folder sidebar stays put.
    @State private var showTasks = false
    /// Selection to restore when Back closes Tasks (mirrors `setupReturnSelection`).
    @State private var tasksReturnSelection: SidebarItem?
    /// Central Tasks filter, driven by the toolbar's All | Open switcher.
    @AppStorage("thread.allTasks.filter") private var taskFilter: TaskFilter = .all
    /// The one custom Enhance template expanded for editing in the template panel.
    @State private var editingEnhanceTemplateID: UUID?
    /// Appearance: "true" Liquid Glass (clear) vs the default tinted look.
    /// Observed here so toggling it re-renders every glass surface below.
    @AppStorage(AppAppearance.liquidGlassKey) private var liquidGlass = false
    @AppStorage(AppAppearance.colorSchemeKey) private var appColorScheme = AppColorScheme.system
    /// Whether the Liquid Glass notch overlay hugging the MacBook notch is shown.
    @AppStorage(AppSettings.notchEnabledKey) private var notchEnabled = false
    /// Experimental: label turns with on-screen speaker names. Off by default;
    /// read at recording start, so flipping it applies to the next recording.
    @AppStorage(AppSettings.speakerNamesKey) private var speakerNamesEnabled = false
    /// Mirror sessions into Apple Notes for reading on your phone. Off by default;
    /// a Thread folder is created only after they pick an account and press Create Folder.
    @AppStorage(AppSettings.notesSyncEnabledKey) private var notesSyncEnabled = false
    @AppStorage(AppSettings.notesSyncAccountKey) private var notesSyncAccount = NotesAccount.iCloud.rawValue
    /// Comma-separated identity aliases used by local AI to attribute tasks and
    /// references to the note-taker.
    @AppStorage(AppSettings.yourNamesKey) private var yourNames = ""
    /// Filename template used only when creating future unnamed sessions.
    @AppStorage(AppSettings.sessionNamingTemplateKey)
    private var sessionNamingTemplate = AppSettings.defaultSessionNamingTemplate
    /// Empty means Thread's built-in Default; otherwise the UUID of a custom
    /// template from `enhanceTemplates`.
    @AppStorage(AppSettings.selectedEnhanceTemplateKey)
    private var selectedEnhanceTemplateID = ""

    /// Compact = idle on the blank live view with nothing to show. Recording,
    /// a transcript still on screen, or a saved note expands the window.
    /// Requiring `entries.isEmpty` avoids shrinking the window (and reflowing a
    /// full transcript into a tiny pane) during the async stop/teardown.
    private var isCompact: Bool {
        // Setup / Tasks replace the detail area and need the full width.
        if showSetup || showTasks { return false }
        // The AI panel needs the roomy detail area, so opening it expands.
        if showAI { return false }
        // Consent is presented over the full transcript surface.
        if pendingRecordingStart != nil { return false }
        // Glossary suggestions / all-terms, the template builder and a note's tasks
        // dock on the right, needing a wide window.
        if !pendingCandidates.isEmpty || showAllTerms || showTemplates || showNoteTasks {
            return false
        }
        if capture.isActive { return false }
        // Tapping New opens the expanded blank compose view, not the compact rail.
        if composingNew { return false }
        switch selection ?? .liveCurrent {
        case .liveCurrent: return capture.entries.isEmpty
        case .session: return false
        }
    }

    private var isViewingSaved: Bool {
        if case .session = (selection ?? .liveCurrent) { return true }
        return false
    }

    /// The note's own ask bar floats at the foot of the panes whenever there's a note
    /// to ask about and room to ask in — a saved one or the meeting being recorded,
    /// which is when "what did they just say?" gets asked. Where it shows it stands in
    /// for the toolbar's chat glyph; two doors to one conversation would only compete.
    private var showsInlineAsk: Bool {
        !isCompact && !showSetup && !showTasks
            && pendingRecordingStart == nil && engine.isAvailable
    }

    /// The saved note currently in view (drives the AI panel's `@ current note`
    /// scope); nil on the live/idle view.
    private var selectedSavedURL: URL? {
        if case .session(let url) = (selection ?? .liveCurrent) { return url }
        return nil
    }

    private var selectedEnhanceTemplate: EnhanceTemplate? {
        guard let id = UUID(uuidString: selectedEnhanceTemplateID) else { return nil }
        return enhanceTemplates.templates.first { $0.id == id }
    }

    private var selectedEnhanceTemplateName: String {
        if let template = selectedEnhanceTemplate {
            let name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Untitled Template" : name
        }
        return "Default"
    }

    private var navigationContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar(store: store,
                    search: search,
                    notesSync: notesSync,
                    selection: $selection,
                    showActions: !isCompact,
                    showInlineSearch: isCompact,
                    notesSyncEnabled: notesSyncEnabled,
                    notesSyncAccount: notesSyncAccount,
                    isRecording: capture.isActive,
                    onToggleSearch: toggleSearch,
                    onOpenSetup: openSetup,
                    onOpenTasks: openTasks,
                    // Compact's New Note is the notes-only compose, with the editor
                    // focused; expanded starts from the transcript side.
                    onNewNote: isCompact ? newNote : newSession,
                    onNoteMoved: { old, new in
                        glossary.noteMoved(from: old, to: new)
                        engine.noteConversationMoved(from: old, to: new)
                    },
                    onNoteDeleted: { url in
                        glossary.noteDeleted(url)
                        engine.forgetNoteConversation(url)
                    })
                .modifier(SidebarColumnWidth(compact: isCompact))
                // The bite in the bottom-left corner. The rows are masked to the
                // panel's shape, the sidebar's material is drawn on that same shape
                // behind them, and the page backdrop stays full-bleed underneath — so
                // the corner the panel gives up shows the base the window sits on.
                .pageGlassBackground()
                .overlay(alignment: .bottomLeading) {
                    SidebarActions(store: store,
                                   onNewNote: isCompact ? newNote : newSession,
                                   onOpenSetup: openSetup)
                }
                .allowsHitTesting(pendingRecordingStart == nil)
                .accessibilityHidden(pendingRecordingStart != nil)
                // Compact: the search button takes the toggle's spot instead.
                .modifier(RemoveSidebarToggle(active: isCompact))
        } detail: {
            detail
                // Soft-focus the transcript/notes behind the AI chat so you can
                // still see it through the glass without it competing for focus.
                .blur(radius: showAI || pendingRecordingStart != nil ? 7 : 0)
                .animation(.easeInOut(duration: 0.2), value: showAI)
                .animation(
                    .easeInOut(duration: 0.2),
                    value: pendingRecordingStart != nil
                )
                .toolbar { detailToolbar }
                .overlay {
                    if let pendingRecordingStart {
                        RecordingConsentPanel(
                            onConfirm: {
                                confirmRecordingStart(pendingRecordingStart)
                            },
                            onCancel: cancelRecordingStart
                        )
                        .transition(.opacity)
                    } else if showAI {
                        AIPanel(isPresented: $showAI, engine: engine,
                                currentNoteURL: selectedSavedURL,
                                onOpenNote: { url in
                                    selection = .session(url)
                                    showAI = false
                                })
                        .transition(.opacity)
                    }
                }
                // A docked third column rather than an overlay: as an overlay these
                // covered the note's right-hand side, so the text they are about
                // stayed hidden behind them. Inset, the note reflows into what's
                // left and the panel reads as the third of three columns.
                .safeAreaInset(edge: .trailing, spacing: 0) { dockedColumn }
        }
    }

    /// The trailing column: the template builder, or the glossary's suggestions and
    /// all-terms list. One at a time — `openTemplates` / `openGlossary` / `askAI`
    /// close each other, since they all want this same slot.
    @ViewBuilder private var dockedColumn: some View {
        if dockedColumnWidth > 0 {
            dockedColumnContent
                // Full height, level with the sidebar's panel and the note's, which
                // puts this column's header row up under the transparent title bar.
                // Its title can live there because text needs no clicks; the close
                // button cannot, so it is a toolbar item instead — up there the
                // window's drag region swallows anything of ours.
                .ignoresSafeArea(edges: .top)
                .background {
                    DetailPanel.surface
                        .padding(.vertical, DetailPanel.top)
                        .padding(.trailing, DetailPanel.trailing)
                        .ignoresSafeArea(edges: [.top, .bottom])
                }
        }
    }

    @ViewBuilder private var dockedColumnContent: some View {
        Group {
            if showNoteTasks, let url = selectedSavedURL {
                NoteTasksPanel(url: url, store: store, onClose: closeNoteTasks)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if showTemplates {
                EnhanceTemplatePanel(
                    templates: enhanceTemplates,
                    selectedID: $selectedEnhanceTemplateID,
                    editingID: $editingEnhanceTemplateID,
                    onClose: closeTemplates)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if showAllTerms || !pendingCandidates.isEmpty {
                GlossaryPanel(mode: showAllTerms ? .allTerms : .suggestions,
                              candidates: $pendingCandidates,
                              glossary: glossary,
                              currentNoteURL: selectedSavedURL,
                              onClose: closeGlossary)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    /// Width the docked column takes, gutter included. The toolbar lays its items out
    /// across the whole window, so the ones that belong to the note shift by this to
    /// stay over the note rather than stranded above the panel.
    private var dockedColumnWidth: CGFloat {
        // Tasks belong to a note, so the column goes with it: Setup, Tasks and the
        // live view have none, and an empty column would be left behind.
        if showNoteTasks && selectedSavedURL != nil {
            return NoteTasksPanel.width + DetailPanel.trailing
        }
        if showTemplates { return EnhanceTemplatePanel.width + DetailPanel.trailing }
        if showAllTerms || !pendingCandidates.isEmpty {
            return GlossaryPanel.width + DetailPanel.trailing
        }
        return 0
    }

    private var presentedContent: some View {
        navigationContent
            .toolbarBackground(.hidden, for: .windowToolbar)
            .background(WindowConfigurator())
            // Compact also pins the height so the idle window always returns to the
            // same shape; expanded keeps whatever height the user dragged it to.
            .background(WindowSizer(targetWidth: isCompact ? 300 : 1000,
                                    targetHeight: isCompact ? 560 : nil))
            .background(SidebarToggleBezel(hidden: liquidGlass,
                                           visibility: columnVisibility))
            // Enforce a readable width floor (compact rail may stay narrow). This
            // drives the window minimum via `.windowResizability(.contentMinSize)`.
            .frame(minWidth: isCompact ? 300 : 500, maxWidth: .infinity,
                   maxHeight: .infinity)
            // Hidden ⌘F trigger.
            .background(
                Button("", action: activateSearch)
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            )
            // Hidden ⌘L trigger: opens and focuses the note's ask bar.
            .background(
                Button("") { askFocusTick += 1 }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(!showsInlineAsk)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            )
    }

    var body: some View {
        presentedContent
        .onChange(of: appColorScheme) { _, _ in
            AppAppearance.applyColorScheme()
            NotchController.shared.refresh()
        }
        .onChange(of: notchEnabled) { _, enabled in
            NotchController.shared.setEnabled(enabled)
        }
        .onChange(of: speakerNamesEnabled) { _, enabled in
            if enabled { requestSpeakerAccessibilityIfNeeded() }
        }
        .onChange(of: liquidGlass) { _, _ in
            NotchController.shared.refresh()
        }
        .onChange(of: notchModel.recordToggleTick) { _, _ in
            if capture.isActive { capture.stop() }
        }
        .onChange(of: notchModel.confirmRecordTick) { _, _ in
            // Consent was given in the notch, so start directly rather than
            // presenting the main-window consent again.
            selection = .liveCurrent
            pane = .transcript
            confirmRecordingStart(.newSession)
        }
        .onChange(of: isCompact) { _, compact in
            if compact { columnVisibility = .all }
        }
        .onChange(of: selection) { _, newValue in
            // Glossary suggestions belong to the note that produced them. Close
            // the inbox before a different note can become the apply/dismiss target.
            // The all-terms list stays: it belongs to no note, and closing Setup
            // restores a selection, which would otherwise shut it as it opened.
            pendingCandidates = []
            notesSync.lastError = nil
            // Opening a saved note ends the "new note" compose state, so a later
            // return to idle collapses to the compact window as usual.
            if case .session = newValue {
                composingNew = false
                showSetup = false
                setupReturnSelection = nil
                showTasks = false
                tasksReturnSelection = nil
            }
            // Drop the autofocus flag once the user moves to a different note.
            if case .session(let u) = newValue, u != justPromotedURL { justPromotedURL = nil }
        }
        .onChange(of: capture.notes) { _, newValue in
            promoteIfNeeded(newValue)
        }
        .onChange(of: search.isActive) { _, active in
            // Search filters the sidebar list, so make sure it's visible, and
            // refresh the index the moment search opens.
            if active {
                columnVisibility = .all
                search.rebuild(from: indexFiles)
            }
        }
        .onReceive(store.$groups) { _ in
            if search.isActive { search.rebuild(from: indexFiles) }
            if showAI { engine.rebuild(from: indexFiles) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .threadSessionDidPersist)) { note in
            guard notesSyncEnabled, notesSync.folderReady else { return }
            guard let url = note.object as? URL else { return }
            notesSync.scheduleUpsert(at: url, store: store, account: notesSyncAccount)
        }
        .onChange(of: showAI) { _, open in
            // Opening Ask: make sure the embedding index is current and re-check
            // whether the on-device model is available.
            if open {
                engine.refreshAvailability()
                engine.rebuild(from: indexFiles)
                engine.prewarm()
            }
        }
        // Warm the model when a saved note opens so hitting Enhance isn't a cold
        // start.
        .onChange(of: isViewingSaved) { _, saved in
            if saved { engine.prewarm() }
        }
        .onAppear(perform: configureApp)
    }

    /// Explains the Accessibility requirement once, when the user first turns on
    /// experimental speaker names, then hands off to macOS's own prompt. Declining
    /// just leaves names unresolved — transcription is unaffected.
    private func requestSpeakerAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Identify speakers"
        alert.informativeText =
            "Allow Accessibility so Thread can read the meeting window (Zoom, "
            + "Google Meet, Microsoft Teams) to label who's speaking. Thread only "
            + "reads names and never clicks anything. This feature is experimental "
            + "and may miss or mislabel speakers."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func configureApp() {
        AppAppearance.applyColorScheme()
        NotchController.shared.attach(capture: capture, engine: engine, store: store)
        NotchController.shared.setEnabled(notchEnabled)
        engine.prewarm()
        // Live spelling correction: learned glossary terms self-correct in the
        // transcript as it streams in.
        capture.correct = { glossary.correct($0) }
        capture.onFinish = { title, entries, notes in
            // Appending into an existing session: rebuild that file as
            // existing + a new timed segment. No new file, and no auto-enhance
            // (the user re-enhances manually so edited notes aren't clobbered).
            if let target = capture.appendTarget {
                store.appendSegment(to: target,
                                    base: capture.appendBaseTranscript ?? "",
                                    entries: entries,
                                    start: capture.startedAt ?? Date(),
                                    end: Date())
                store.applyTextTransform({ glossary.correct($0) }, to: target)
                NotificationCenter.default.post(name: .threadSessionDidPersist, object: target)
                return
            }
            let started = capture.startedAt
            guard let url = store.finishLive(title: title, entries: entries, notes: notes,
                                             start: started, end: Date()) else { return }
            // Clean the freshly-stored transcript with everything learned so
            // far, so the saved record (not just the summary) reads correctly.
            store.applyTextTransform({ glossary.correct($0) }, to: url)
            // Auto-enhance the just-finished session's notes in the background.
            let rawTranscript = entries
                .map { entry -> String in
                    if let n = entry.speakerName,
                       !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return "\(n): \(entry.text)"
                    }
                    return "\(entry.speaker.rawValue): \(entry.text)"
                }
                .joined(separator: "\n")
            let transcript = glossary.correct(rawTranscript)
            let templateInstructions = selectedEnhanceTemplate?.instructions
            Task { @MainActor in
                if let enhanced = await engine.enhance(
                    notes: notes,
                    transcript: transcript,
                    customInstructions: templateInstructions
                ) {
                    let split = SessionStore.splitActionItems(from: enhanced.notesMarkdown)
                    let extracted = enhanced.actionItems ?? []
                    let tasks = SessionStore.mergeTasks(
                        new: split.tasks + extracted,
                        existing: []
                    )
                    store.saveNotesAndTasks(url, notes: split.notes, tasks: tasks)
                }
            }
        }
        capture.onAutosave = { title, entries, notes in
            // Crash-safety autosave. For an append, rewrite the target file as
            // base + the in-progress segment (end unknown → nil) each tick.
            if let target = capture.appendTarget {
                store.appendSegment(to: target,
                                    base: capture.appendBaseTranscript ?? "",
                                    entries: entries,
                                    start: capture.startedAt ?? Date(),
                                    end: nil)
            } else {
                store.autosaveLive(title: title, entries: entries, notes: notes,
                                   start: capture.startedAt, end: nil)
            }
        }
        notesSync.refreshLinkedOnOpen(store: store, account: notesSyncAccount,
                                      isRecording: capture.isActive)
    }

    /// Flattened file list handed to the search index.
    private var indexFiles: [(url: URL, folder: String, date: Date)] {
        store.groups.flatMap { group in
            group.files.map { (url: $0.url, folder: group.name, date: $0.modified) }
        }
    }

    private func activateSearch() {
        columnVisibility = .all
        search.rebuild(from: indexFiles)
        search.activate()
    }

    /// Toggle search from a button: opening always reveals the sidebar (so the
    /// search bar is visible even when the sidebar was collapsed) and rebuilds
    /// the index; closing just deactivates.
    private func toggleSearch() {
        if search.isActive {
            search.deactivate()
        } else {
            activateSearch()
        }
    }

    @ViewBuilder private var detail: some View {
        if showTasks {
            tasksDetail
        } else if showSetup {
            setupDetail
        } else {
            sessionDetail
        }
    }

    /// The central Tasks surface — all tasks across every note, grouped by
    /// folder → note. Styled like Setup: a scrollable `.detailPanelBackground()`
    /// panel with a back chevron in the toolbar.
    private var tasksDetail: some View {
        AllTasksView(store: store,
                     hideCompleted: taskFilter == .open,
                     onOpenNote: openNoteFromTasks)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clippedToDetailPanel()
            .detailPanelBackground()
            .navigationTitle("")
            .onExitCommand(perform: closeTasks)
    }

    /// The Setup surface — a liquid-glass panel styled like the Glossary panel:
    /// a `.glassEffect(.regular)` card at corner radius 20 with a 12px margin.
    /// The backdrop keeps the surrounding margin from showing through. Empty
    /// content for now.
    private var setupDetail: some View {
        ScrollView {
            setupContent
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .clippedToDetailPanel()
        .detailPanelBackground()
        .navigationTitle("")
        .onExitCommand(perform: closeSetup)
    }

    @ViewBuilder private var setupContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Appearance")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Liquid Glass")
                        .font(.system(size: 13, weight: .semibold))
                    Text(liquidGlass
                         ? "Clearer, more fluid surfaces that reveal the blurred desktop."
                         : "Tinted glass with stronger contrast and readability.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("Liquid Glass", isOn: $liquidGlass)
                    .labelsHidden()
                    .toggleStyle(SetupToggleStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassEffect(AppAppearance.glass(), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notch")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Show a Liquid Glass panel that hugs your MacBook's notch.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("Notch", isOn: $notchEnabled)
                    .labelsHidden()
                    .toggleStyle(SetupToggleStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassEffect(AppAppearance.glass(), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Speaker names")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Experimental")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: .capsule)
                    }
                    Text("Detect who's speaking from the meeting window (Zoom, Google Meet, Microsoft Teams). Still rough — names can be missed or mislabeled.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("Speaker names", isOn: $speakerNamesEnabled)
                    .labelsHidden()
                    .toggleStyle(SetupToggleStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassEffect(AppAppearance.glass(), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Theme")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Follow your Mac's light or dark setting, or keep Thread on one of them.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Picker("Theme", selection: $appColorScheme) {
                    ForEach(AppColorScheme.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassEffect(AppAppearance.glass(), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
            }

            Text("Bring Your Own Keys")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            BringYourOwnLLMSettings()

            Text("Apple Notes")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            notesSyncSettings

            Text("Context")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 8) {
                Text("Your Names")
                    .font(.system(size: 13, weight: .semibold))
                TextField("e.g. James, Jim", text: $yourNames)
                    .textFieldStyle(.roundedBorder)
                Text("Names people may use for you. Thread uses them to recognize your action items and understand when a conversation refers to you.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassEffect(AppAppearance.glass(), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
            }

            Text("Session Naming")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 8) {
                Text("Automatic Name")
                    .font(.system(size: 13, weight: .semibold))
                TextField(
                    AppSettings.defaultSessionNamingTemplate,
                    text: $sessionNamingTemplate
                )
                .textFieldStyle(.roundedBorder)
                Text("Names future sessions automatically. Use {date} and {time}; you can still rename any session later.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Preview: \(SessionStore.sessionNamePreview(template: sessionNamingTemplate))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassEffect(AppAppearance.glass(), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
            }

            Text("Glossary")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            glossarySettings

            Text("Enhance Templates")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            enhanceTemplateSettings
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var notesSyncSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: NotesSyncController.uploadSymbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Apple Notes")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text("View sessions in Apple Notes. Thread copies them into a Thread folder so you can read them on your phone. Notes is a viewer, not a second editor.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Recording does not send. When you Stop, or save a summary or tasks, Thread creates that Note or updates it if it still lives in the folder. Anything you type in Notes is overwritten on the next copy.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Toggle("Copy to Notes", isOn: $notesSyncEnabled)
                    .labelsHidden()
                    .toggleStyle(SetupToggleStyle())
            }

            if notesSyncEnabled {
                Divider().opacity(0.35)

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Folder location")
                            .font(.system(size: 13, weight: .semibold))
                        Text("iCloud appears on your iPhone. On My Mac stays on this computer.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    Picker("Notes account", selection: $notesSyncAccount) {
                        Text(NotesAccount.iCloud.label).tag(NotesAccount.iCloud.rawValue)
                        Text(NotesAccount.onMyMac.label).tag(NotesAccount.onMyMac.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: notesSyncAccount) { _, _ in
                        notesSync.accountChanged()
                    }
                }

                HStack {
                    if notesSync.folderReady {
                        Label("Folder ready", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                    } else {
                        Button(notesSync.isBusy ? "Creating…" : "Create Folder") {
                            notesSync.ensureFolder(account: notesSyncAccount,
                                                   store: store,
                                                   isRecording: capture.isActive)
                        }
                        .controlSize(.small)
                        .disabled(notesSync.isBusy)
                    }
                    Spacer()
                }

                if notesSync.folderReady {
                    Text("Sessions copy automatically when they save, when Thread opens, and when you create the folder. Right-click a session to copy it again.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = notesSync.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(AppAppearance.glass(), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
        }
    }

    /// A summary and a way in, like the templates section below: terms are reviewed
    /// in the right-side panel, which is also where a post-enhance suggestion is
    /// accepted. Listing them here as well left two editors over the same data.
    private var glossarySettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Learned Terms")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(glossary.terms.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Text("Approved corrections Thread applies to live transcripts and notes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider().opacity(0.35)

            HStack {
                if glossary.terms.isEmpty {
                    Text("Corrections you approve will appear here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Review Terms") {
                    closeSetup()
                    openGlossary()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(AppAppearance.glass(), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
        }
    }

    /// Deliberately just a summary and a way in: templates are authored in the
    /// right-side panel, beside the note whose wording they shape. Two editors over
    /// the same data would drift.
    private var enhanceTemplateSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Templates")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(enhanceTemplates.templates.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                Text("Your own instructions, layered onto Thread's built-in Enhance rules.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider().opacity(0.35)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("In use")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(selectedEnhanceTemplateName)
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                Button("Edit Templates") {
                    closeSetup()
                    openTemplates(creatingNew: false)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(AppAppearance.glass(), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
        }
    }

    @ViewBuilder private var sessionDetail: some View {
        switch selection ?? .liveCurrent {
        case .liveCurrent:
            SessionDetailView(capture: capture,
                              engine: engine,
                              pane: pane,
                              showStartOverlay: isCompact,
                              onStart: startCapture,
                              onSearch: nil,
                              onAI: isCompact ? askAI : nil,
                              onGlossary: nil,
                              onTasks: isCompact ? openTasks : nil,
                              autofocusNotes: composingNew,
                              askURL: store.liveURL,
                              showsAsk: showsInlineAsk,
                              askFocusRequest: askFocusTick)
        case .session(let url):
            SavedSessionView(url: url, store: store, pane: pane,
                             capture: capture,
                             engine: engine,
                             glossary: glossary,
                             enhanceTrigger: enhanceTick,
                             enhanceTemplateInstructions: selectedEnhanceTemplate?.instructions,
                             enhanceTemplates: enhanceTemplates,
                             selectedEnhanceTemplateID: $selectedEnhanceTemplateID,
                             enhanceTemplateName: selectedEnhanceTemplateName,
                             insetPanel: !isCompact,
                             isEnhancing: $isEnhancing,
                             autofocusNotes: justPromotedURL == url,
                             onEnhance: triggerEnhance,
                             onOpenTemplates: { creatingNew in openTemplates(creatingNew: creatingNew) },
                             tasksOpen: showNoteTasks,
                             onToggleTasks: toggleNoteTasks,
                             showsAsk: showsInlineAsk,
                             askFocusRequest: askFocusTick,
                             onRename: { newURL in selection = .session(newURL) },
                             onCandidates: { found in
                                 guard !found.isEmpty else { return }
                                 withAnimation(.easeInOut(duration: 0.25)) {
                                     showAI = false
                                     pendingCandidates = found
                                 }
                             })
                .id(url)
        }
    }

    // Compact idle keeps the toolbar *present but empty* (so the traffic lights
    // stay); Start lives as a glass overlay in the detail. Expanding restores the
    // real items.
    @ToolbarContentBuilder private var detailToolbar: some ToolbarContent {
        if showSetup && pendingRecordingStart == nil {
            ToolbarItem(placement: .navigation) {
                Button(action: closeSetup) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(
                    AppAppearance.glass(interactive: true),
                    in: .circle
                )
                .help("Back to session")
                .accessibilityLabel("Back to session")
            }
            .sharedBackgroundVisibility(.hidden)
        }

        if showTasks && pendingRecordingStart == nil {
            ToolbarItem(placement: .navigation) {
                Button(action: closeTasks) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(
                    AppAppearance.glass(interactive: true),
                    in: .circle
                )
                .help("Back to session")
                .accessibilityLabel("Back to session")
            }
            .sharedBackgroundVisibility(.hidden)

            // Centered All / Open filter, mirroring the Transcript / Notes switcher.
            ToolbarItem(placement: .principal) {
                Picker("Filter", selection: $taskFilter) {
                    Text("All").tag(TaskFilter.all)
                    Text("Open").tag(TaskFilter.open)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .offset(y: toolbarGlyphDrop)
            }
            .sharedBackgroundVisibility(toolbarPillVisibility)
        }

        // In Setup / Tasks we hide the record button, the Transcript/Notes
        // switcher, and the enhance + chat buttons — the panel owns the surface.
        if !showSetup
            && !showTasks
            && !isCompact
            && pendingRecordingStart == nil {
            // Centered Transcript / Notes switcher. Half the column, since centring
            // is relative to the whole window: half of what the column takes puts it
            // back in the middle of the note.
            ToolbarItem(placement: .principal) {
                paneSwitcher
                    .offset(x: -dockedColumnWidth / 2, y: toolbarGlyphDrop)
            }
            // Own chrome so light mode still has a capsule; the system pill
            // washes out against a light toolbar.
            .sharedBackgroundVisibility(.hidden)
            // Enhance is not here: the template it will use and the button that runs
            // it live under the note's title, in `EnhanceBar`.
            //
            // Chat (Ask AI). Declared before Record so it sits to its left. Only
            // when the note isn't carrying its own ask bar at the foot of the panes.
            if !showsInlineAsk {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: askAI) {
                        Image(systemName: "message")
                    }
                    .offset(x: -dockedColumnWidth, y: toolbarGlyphDrop)
                    .help("Ask AI")
                }
                .sharedBackgroundVisibility(toolbarPillVisibility)
            }
            // Record owns the trailing edge in every state: on a saved note it
            // appends a new segment to that session, on a live/new note it starts
            // the first one. New Note lives in the sidebar, so the button under
            // the cursor here never changes meaning.
            ToolbarItem(placement: .primaryAction) {
                Group {
                    if isViewingSaved, let saved = selectedSavedURL {
                        RecordButton(capture: capture, onStart: { startAppend(to: saved) })
                    } else {
                        RecordButton(capture: capture, onStart: startCapture)
                    }
                }
                .offset(x: -dockedColumnWidth, y: toolbarGlyphDrop)
            }
            .sharedBackgroundVisibility(toolbarPillVisibility)
        }

        // The docked column's close button. Its title sits in the column itself,
        // but that top row is under the title bar, where only the toolbar can be
        // clicked — so this half of the header lives here, above the column's
        // trailing edge, on the same line as the title it belongs to.
        if dockedColumnWidth > 0 {
            ToolbarItem(placement: .primaryAction) {
                Button(action: closeDockedColumn) {
                    // Smaller than the toolbar's own glyphs: it reads as part of the
                    // column's header rather than another action of the note's.
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .offset(y: toolbarGlyphDrop)
                .help("Close panel")
            }
            .sharedBackgroundVisibility(toolbarPillVisibility)
        }
    }

    private func closeDockedColumn() {
        if showNoteTasks {
            closeNoteTasks()
        } else if showTemplates {
            closeTemplates()
        } else {
            closeGlossary()
        }
    }

    /// Transcript / Notes, hand-rolled rather than a segmented `Picker`: that style
    /// takes only a bare `Text` or `Image` per segment on macOS, so a `Label` arrives
    /// stripped of its icon and an `HStack` splits into two segments of its own.
    ///
    /// `doc.text` is the note glyph the Tasks list already uses, and the bubble echoes
    /// the transcript's own speech turns.
    @ViewBuilder private var paneSwitcher: some View {
        let options = HStack(spacing: 2) {
            paneOption(.transcript, "Transcript", "text.bubble")
            paneOption(.notes, "Notes", "doc.text")
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
        // Clear glass hides the toolbar's own pills, which suits a lone glyph but
        // leaves this pair of labels on the transcript itself. Tinted in light
        // mode has the same problem: the system pill is there and invisible.
        // A capsule of our own is the chrome in every appearance.
        if liquidGlass {
            options.glassEffect(AppAppearance.glass(), in: .capsule)
        } else {
            options
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .overlay {
                    Capsule().strokeBorder(.primary.opacity(0.14), lineWidth: 1)
                }
        }
    }

    private func paneOption(_ target: SessionPane,
                            _ title: String,
                            _ icon: String) -> some View {
        let selected = pane == target
        return Button { pane = target } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if selected { Capsule().fill(Color.primary.opacity(0.12)) }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Clear glass leaves the toolbar buttons bare, so the icons sit directly on the
    /// note's panel; Tinted keeps the system's glass pills, which need the contrast.
    private var toolbarPillVisibility: Visibility {
        liquidGlass ? .hidden : .automatic
    }

    /// Toolbar items centre themselves in the 52pt title band, which reads high now
    /// that the note's panel starts 8pt down: this drops everything sitting over the
    /// panel to the centre of the panel's top strip instead. The sidebar's own run
    /// keeps the band's centre, where it lines up with the traffic lights.
    ///
    /// Only in Clear glass, and only because the pills are hidden there. A shared
    /// background belongs to the toolbar item, not to the view inside it, so it stays
    /// where it is while the content shifts — Tinted keeps its pills, so it has to
    /// keep the band's centre with them.
    private var toolbarGlyphDrop: CGFloat {
        liquidGlass ? 4 : 0
    }

    // MARK: - Actions

    private func triggerEnhance() {
        enhanceTick += 1
    }

    private func startCapture() {
        selection = .liveCurrent
        pane = .transcript
        presentRecordingConsent(for: .newSession)
    }

    /// Records a new segment into an existing saved session. Stays on that
    /// session's view (which shows the existing transcript plus the live lines),
    /// and on Stop the new segment is appended to its file.
    private func startAppend(to url: URL) {
        pane = .transcript
        presentRecordingConsent(for: .append(url))
    }

    private func presentRecordingConsent(
        for request: PendingRecordingStart
    ) {
        withAnimation(.easeInOut(duration: 0.2)) {
            showAI = false
            pendingCandidates = []
            showAllTerms = false
            pendingRecordingStart = request
        }
    }

    private func confirmRecordingStart(_ request: PendingRecordingStart) {
        switch request {
        case .newSession:
            // A normal live recording never appends into an existing file.
            capture.appendTarget = nil
            capture.appendBaseTranscript = nil
        case .append(let url):
            capture.appendTarget = url
            capture.appendBaseTranscript = store.rawTranscript(of: url)
        }
        // Enter the starting state before dismissing consent so compact-window
        // logic never observes an idle gap and begins shrinking.
        capture.start()
        withAnimation(.easeInOut(duration: 0.16)) {
            pendingRecordingStart = nil
        }
    }

    private func cancelRecordingStart() {
        withAnimation(.easeInOut(duration: 0.16)) {
            pendingRecordingStart = nil
        }
    }

    private func openSetup() {
        if showSetup {
            closeSetup()
            return
        }
        setupReturnSelection = selection
        // Setup pulls the compact window out to full width, so this runs on the window
        // resize's own animation rather than a shorter one of its own.
        withAnimation(WindowSizer.contentAnimation) {
            showAI = false
            selection = nil
            showTasks = false
            tasksReturnSelection = nil
            showSetup = true
        }
    }

    private func closeSetup() {
        let previous = setupReturnSelection
        setupReturnSelection = nil
        withAnimation(WindowSizer.contentAnimation) {
            showSetup = false
            if selection == nil { selection = previous }
        }
    }

    private func openTasks() {
        if showTasks {
            closeTasks()
            return
        }
        tasksReturnSelection = selection
        withAnimation(WindowSizer.contentAnimation) {
            showAI = false
            selection = nil
            showSetup = false
            setupReturnSelection = nil
            showTasks = true
        }
    }

    private func closeTasks() {
        let previous = tasksReturnSelection
        tasksReturnSelection = nil
        withAnimation(WindowSizer.contentAnimation) {
            showTasks = false
            if selection == nil { selection = previous }
        }
    }

    /// Jumps from the central Tasks surface to a note's Notes pane.
    private func openNoteFromTasks(_ url: URL) {
        tasksReturnSelection = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            showTasks = false
            pane = .notes
            selection = .session(url)
        }
    }

    private func newSession() {
        showSetup = false
        setupReturnSelection = nil
        showTasks = false
        tasksReturnSelection = nil
        capture.newSession()
        selection = .liveCurrent
        pane = .transcript
        composingNew = true
    }

    /// Compact "New Note": expands into a blank, notes-only compose view with the
    /// editor focused. The notes-only promotion saves it on the first keystroke.
    private func newNote() {
        showTasks = false
        tasksReturnSelection = nil
        capture.newSession()
        selection = .liveCurrent
        pane = .notes
        composingNew = true
    }

    /// Notes-only flow: the moment a blank compose view has typed notes (and no
    /// recording), persist it as a real saved note and switch into it, so it
    /// appears in the sidebar and edits autosave from then on.
    private func promoteIfNeeded(_ notes: String) {
        guard (selection ?? .liveCurrent) == .liveCurrent,
              !capture.isActive,
              capture.entries.isEmpty,
              !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let url = store.finishLive(title: capture.currentTitle, entries: [], notes: notes) else { return }
        pane = .notes
        justPromotedURL = url
        selection = .session(url)
        // Reset the live buffer so a later New (or recording) starts clean and
        // never writes back into this now-independent note.
        DispatchQueue.main.async { capture.newSession() }
    }

    /// Toggle the AI prompt panel. Opening expands the window (via `isCompact`)
    /// and floats the panel over whatever the detail area is showing.
    private func askAI() {
        withAnimation(.easeInOut(duration: 0.2)) {
            // Ask, the glossary and the template builder share the right side —
            // only one at a time.
            if !showAI {
                pendingCandidates = []
                showAllTerms = false
                showTemplates = false
                showNoteTasks = false
            }
            showAI.toggle()
        }
    }

    /// Toggle the all-terms glossary panel. Shares the right side with Ask, the
    /// suggestion inbox and the template builder, so opening it closes those.
    private func openGlossary() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if showAllTerms {
                showAllTerms = false
            } else {
                showAI = false
                showTemplates = false
                showNoteTasks = false
                pendingCandidates = []
                showAllTerms = true
            }
        }
    }

    private func closeGlossary() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if showAllTerms {
                showAllTerms = false
            } else {
                pendingCandidates = []
            }
        }
    }

    /// Docks the Enhance template builder on the right. `creatingNew` adds a
    /// template first and opens it expanded, so "New Template" needs one click.
    private func openTemplates(creatingNew: Bool) {
        if creatingNew {
            let id = enhanceTemplates.add()
            selectedEnhanceTemplateID = id.uuidString
            editingEnhanceTemplateID = id
        } else {
            editingEnhanceTemplateID = nil
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            showAI = false
            showAllTerms = false
            showNoteTasks = false
            pendingCandidates = []
            showTemplates = true
        }
    }

    private func closeTemplates() {
        editingEnhanceTemplateID = nil
        withAnimation(.easeInOut(duration: 0.2)) { showTemplates = false }
    }

    /// Shows or hides the open note's tasks, driven by the chip beside the enhance
    /// bar. One control for both directions: the chip is where the count lives, so
    /// it is also where you go to put the list away.
    private func toggleNoteTasks() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if showNoteTasks {
                showNoteTasks = false
            } else {
                showAI = false
                showTemplates = false
                showAllTerms = false
                pendingCandidates = []
                showNoteTasks = true
            }
        }
    }

    private func closeNoteTasks() {
        withAnimation(.easeInOut(duration: 0.2)) { showNoteTasks = false }
    }
}

/// Removes the automatic sidebar-toggle toolbar item when `active` (compact).
/// Sizes the sidebar column. Expanded needs a *minimum*: a plain ideal width loses
/// to AppKit's autosaved divider position, and too narrow a column pushes the
/// sidebar's toolbar buttons into the window's overflow menu. Compact must not have
/// one — the window is only 300pt wide there, and a minimum it can't honour makes
/// AppKit squeeze the column to ~140pt, stranding a dead strip beside the list.
private struct SidebarColumnWidth: ViewModifier {
    let compact: Bool

    // Compact floats the sidebar over a full-width detail, and in that mode the column
    // modifier is ignored — without a saved divider the panel lands at ~140pt.
    // Constraining the content is what actually sizes it. 232 leaves a ~68pt strip in
    // the 300pt window, enough that the detail's glass button column clears the
    // sidebar's rounded trailing edge instead of being overlapped by it.
    //
    // 248 is the floor for the sidebar's toolbar run when expanded: traffic lights
    // (~78) plus All Tasks, Search and the sidebar toggle (~137) leaves no slack at
    // 216, and Search gets evicted into the window's >> menu.
    private var width: CGFloat { compact ? 232 : 248 }

    func body(content: Content) -> some View {
        // Both sizes go through the same two modifiers. Switching between two different
        // sets of them changed the view tree mid-resize, which made AppKit rebuild the
        // split view while the window was still growing.
        content
            .frame(minWidth: width)
            .navigationSplitViewColumnWidth(min: width, ideal: width,
                                            max: compact ? width : 420)
    }
}

private struct RemoveSidebarToggle: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

// MARK: - Sidebar

enum SidebarItem: Hashable {
    case liveCurrent
    case session(URL)
}

/// The central Tasks surface filter: all tasks, or only open (incomplete) ones.
enum TaskFilter: String {
    case all
    case open
}

/// The library actions, top to bottom: New Note, Add Folder, Setup. They act on the
/// library rather than on the open note, so they belong with the list rather than in
/// the toolbar's cramped run beside the traffic lights — and they sit in the notch
/// bitten out of the panel's bottom-left corner, drawn by the column outside the
/// mask that cuts it.
private struct SidebarActions: View {
    @ObservedObject var store: SessionStore
    var onNewNote: () -> Void
    var onOpenSetup: () -> Void

    @Environment(\.colorScheme) private var scheme

    /// Room the list leaves for these, gaps included. Three 28pt glyphs in a row, plus
    /// clearance from the window's bottom edge.
    static let footprint = CGSize(width: 98, height: 44)

    var body: some View {
        HStack(spacing: 2) {
            // Shown in compact too: New Note belongs with the library actions in
            // every window size, and the compact window's own copy over the detail
            // only made it look absent from the place it lives.
            button(systemName: "gearshape",
                   help: "Setup",
                   action: onOpenSetup)
            button(systemName: "folder.badge.plus",
                   help: "Add Folder",
                   action: store.addFolder)
            button(systemName: "square.and.pencil",
                   disabled: store.needsFolder,
                   help: store.needsFolder
                       ? "Add a folder before creating notes"
                       : "New Note",
                   action: onNewNote)
        }
        // Bare, like the toolbar's glyphs at the top of the window. Nothing is drawn
        // behind a window's bottom edge the way macOS blurs behind its title bar, so any
        // surface here has to be painted by us — and every one tried read as a slab on
        // the panel. The row is short enough that the reserved space below the list keeps
        // the glyphs clear of it at rest.
        .padding(.leading, 10)
        .padding(.bottom, 8)
    }

    private func button(systemName: String,
                        disabled: Bool = false,
                        help: String,
                        pulsing: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(glyph)
                .symbolEffect(.pulse, options: .repeating, isActive: pulsing)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    /// Full white rather than secondary, which read as grey against the panel. Light mode
    /// takes dark grey for the same reason the compact glyphs do: white disappears into a
    /// pale panel.
    private var glyph: Color {
        scheme == .dark ? .white : Color(white: 0.25)
    }
}

private struct Sidebar: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var search: SearchController
    @ObservedObject var notesSync: NotesSyncController
    @Binding var selection: SidebarItem?
    let showActions: Bool
    /// In compact mode the toolbar (and its search glass) is hidden, so the
    /// pill is shown inline at the sidebar's top-right instead.
    let showInlineSearch: Bool
    let notesSyncEnabled: Bool
    let notesSyncAccount: String
    let isRecording: Bool
    /// Opens/closes search; opening also reveals the sidebar.
    var onToggleSearch: () -> Void = {}
    /// Opens the Setup surface (Glossary, prompts, and related preferences).
    var onOpenSetup: () -> Void = {}
    /// Opens the central All Tasks surface. Like search, it acts on the whole
    /// library rather than the open note, so it lives above the list.
    var onOpenTasks: () -> Void = {}
    /// Starts a new note. It lives with the library actions rather than the
    /// detail toolbar because it creates a list item instead of acting on the
    /// note that's open.
    var onNewNote: () -> Void = {}
    var onNoteMoved: (URL, URL) -> Void = { _, _ in }
    var onNoteDeleted: (URL) -> Void = { _ in }

    @State private var editingURL: URL?
    @State private var editText = ""
    @FocusState private var editingFocused: Bool

    /// Persisted set of collapsed folder paths (survives launches).
    @AppStorage("thread.collapsedFolders") private var collapsedStore = ""
    /// Observed for the same reason the detail toolbar observes it: Clear glass wants
    /// these glyphs bare.
    @AppStorage(AppAppearance.liquidGlassKey) private var liquidGlass = false

    private var collapsedFolders: Set<String> {
        Set(collapsedStore.split(separator: "\n").map(String.init))
    }
    private func isCollapsed(_ group: SessionGroup) -> Bool {
        collapsedFolders.contains(group.folderURL.path)
    }
    private func setCollapsed(_ group: SessionGroup, _ collapsed: Bool) {
        var set = collapsedFolders
        let key = group.folderURL.path
        if collapsed { set.insert(key) } else { set.remove(key) }
        collapsedStore = set.sorted().joined(separator: "\n")
    }
    /// Expanded/collapsed binding for a folder's DisclosureGroup, backed by the
    /// persisted collapse set.
    private func expandedBinding(_ group: SessionGroup) -> Binding<Bool> {
        Binding(get: { !isCollapsed(group) },
                set: { expanded in setCollapsed(group, !expanded) })
    }

    var body: some View {
        content
            // Rows dissolve into the sidebar's foot rather than running through the
            // library actions. A mask on the list, so only its rows fade — the panel's
            // own material is untouched, which is what every surface tried behind those
            // glyphs failed at.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    // Spread over a longer run, and clear only just above the window's
                    // edge: reaching clear well before the glyphs made rows vanish
                    // partway down the panel, which read as the list being cut short.
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .clear, location: 0.9),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: SidebarActions.footprint.height + 28)
                }
                .ignoresSafeArea()
            }
            // Float a full-width search bar just under the toolbar (both compact
            // and expanded) so it never pushes the list down or overflows.
            .overlay(alignment: .top) {
                if search.isActive {
                    SearchPill(controller: search, fillWidth: true)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }
            }
            // Room for the library actions, which are drawn by the column itself:
            // the panel's notch is cut with a mask, and anything inside the mask
            // would be cut away with it.
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: SidebarActions.footprint.height)
            }
            .toolbar {
            // A flexible spacer forces the buttons to the trailing (top-right) edge;
            // without it a single item left-aligns next to the traffic lights.
            ToolbarSpacer(.flexible, placement: .primaryAction)
            // All Tasks and Search, left to right, with the sidebar toggle after
            // them. New Note, Add Folder and Setup are stacked at the sidebar's
            // bottom-left instead: this run has to share its width with the traffic
            // lights, and anything more gets pushed into the window's >> menu.
            // Compact has its own All Tasks button over the detail area.
            //
            // The pills are hidden under Clear glass like the detail side's. Over the
            // sidebar's own panel the shared background never showed, but collapse the
            // sidebar and this run slides over the note, where it read as a black slab
            // around the glyphs.
            //
            // These stay as separate items, and the toggle stays the system's. Both a
            // grouped `ToolbarItemGroup` and our own toggle in place of the system one
            // cost the run its layout: AppKit evicted the toggle into the window's >>
            // menu and squeezed the sidebar column to ~160pt.
            if showActions {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onOpenTasks) {
                        Image(systemName: "checklist")
                    }
                    .help("All Tasks")
                }
                .sharedBackgroundVisibility(liquidGlass ? .hidden : .automatic)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: onToggleSearch) {
                    Image(systemName: "magnifyingglass")
                }
                .help("Search notes")
            }
            .sharedBackgroundVisibility(liquidGlass ? .hidden : .automatic)
        }
    }


    /// When search is running, the sidebar becomes a flat ranked result list;
    /// otherwise it's the normal folder tree (or the empty state).
    @ViewBuilder private var content: some View {
        if store.groups.isEmpty && !isSearching {
            emptyState
        } else {
            list
        }
    }

    /// Search is filtering the sidebar (open with a non-empty query).
    private var isSearching: Bool { search.isActive && !search.query.isEmpty }

    /// A single `List` for both the folder tree and search results. Swapping
    /// between two separate `List`s stole first-responder from the search field
    /// after the first keystroke, so we keep one list and change its rows.
    private var list: some View {
        List(selection: $selection) {
            if isSearching {
                if search.results.isEmpty {
                    Text("No results")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(search.results) { result in
                        SearchResultRow(result: result)
                            .tag(SidebarItem.session(result.url))
                    }
                }
            } else {
                ForEach(store.groups) { group in
                    DisclosureGroup(isExpanded: expandedBinding(group)) {
                        ForEach(group.files) { file in
                            row(file)
                                .tag(SidebarItem.session(file.url))
                        }
                    } label: {
                        folderLabel(group)
                    }
                }
                .onMove { from, to in store.moveFolders(from: from, to: to) }
            }
        }
        // Make room for the floating search bar so it never overlaps rows.
        .safeAreaInset(edge: .top) {
            if search.isActive { Color.clear.frame(height: 48) }
        }
        .scrollContentBackground(.hidden)
    }

    /// A folder header row: clicking the disclosure triangle collapses/expands
    /// its sessions; the row is also the native drag handle for reordering.
    @ViewBuilder private func folderLabel(_ group: SessionGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text(group.name)
            Spacer(minLength: 8)
            Text("\(group.files.count)")
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.trailing, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") { store.reveal(group.folderURL) }
            Button("Remove from Sidebar", role: .destructive) {
                store.removeFolder(group.folderURL)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.secondary)
            Text("Start with a folder")
                .font(.headline)
            Text("Pick where Thread saves your transcripts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Add Folder", action: store.addFolder)
                .controlSize(.small)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func row(_ file: SessionFile) -> some View {
        if editingURL == file.url {
            TextField("Title", text: $editText)
                .textFieldStyle(.roundedBorder)
                .focused($editingFocused)
                .onSubmit { commitEdit(file) }
                .onExitCommand { editingURL = nil }
        } else {
            Text(file.title)
                .lineLimit(1)
                .contextMenu {
                Button("Rename") { beginEdit(file) }
                let others = store.folders.filter { $0 != file.url.deletingLastPathComponent() }
                if !others.isEmpty {
                    Menu("Move to") {
                        ForEach(others, id: \.self) { folder in
                            Button(folder.lastPathComponent) { move(file, to: folder) }
                        }
                    }
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                }
                if notesSyncEnabled && notesSync.folderReady {
                    Button(file.notesSynced ? "Resync to Notes" : "Send to Notes") {
                        syncNotes(file.url)
                    }
                    .disabled(notesSync.isBusy || isRecording)
                }
                Button("Delete", role: .destructive) { delete(file) }
            }
        }
    }

    private func syncNotes(_ url: URL) {
        if isRecording || notesSync.isBusy { return }
        notesSync.syncSession(at: url, store: store, account: notesSyncAccount)
    }

    private func beginEdit(_ file: SessionFile) {
        editText = file.title
        editingURL = file.url
        DispatchQueue.main.async { editingFocused = true }
    }

    private func commitEdit(_ file: SessionFile) {
        if let newURL = store.rename(file, to: editText) {
            onNoteMoved(file.url, newURL)
            if selection == .session(file.url) { selection = .session(newURL) }
        }
        editingURL = nil
    }

    private func delete(_ file: SessionFile) {
        if selection == .session(file.url) { selection = .liveCurrent }
        onNoteDeleted(file.url)
        store.delete(file)
    }

    private func move(_ file: SessionFile, to folder: URL) {
        if let dest = store.move(file.url, to: folder) {
            onNoteMoved(file.url, dest)
            if selection == .session(file.url) { selection = .session(dest) }
        }
    }
}

// MARK: - Live detail

private struct SessionDetailView: View {
    @ObservedObject var capture: AudioCaptureController
    @ObservedObject var engine: AskEngine
    var pane: SessionPane = .transcript
    var showStartOverlay: Bool = false
    var onStart: () -> Void = {}
    /// When non-nil (compact idle), a search glass sits above Start; tapping it
    /// opens the pill inside the sidebar.
    var onSearch: (() -> Void)? = nil
    /// When non-nil (compact idle), an AI (sparkles) button sits under Start.
    var onAI: (() -> Void)? = nil
    /// When non-nil (compact idle, and the glossary has terms), a glossary button
    /// sits under the AI button.
    var onGlossary: (() -> Void)? = nil
    /// When non-nil (compact idle), an All Tasks button sits under Start.
    var onTasks: (() -> Void)? = nil
    /// Focus the notes editor on appear (used by the compact "New Note" compose).
    var autofocusNotes: Bool = false
    /// The file autosave is writing this session into, once it exists. The ask field
    /// keys its conversation to it; `finishLive` reuses the same file, so a question
    /// asked mid-meeting isn't cut off when the recording stops.
    var askURL: URL? = nil
    var showsAsk: Bool = false
    var askFocusRequest: Int = 0
    @Environment(\.colorScheme) private var scheme
    @State private var askThreadOpen = false
    /// Depth of the title band this view's safe area steps over. Both the clip that
    /// lets the panes fill the panel and the frost that covers them up there are cut
    /// to it, so it's measured rather than assumed — see `titleBandProbe`.
    @State private var titleBand: CGFloat = SessionDetailView.titleBandFallback

    var body: some View {
        VStack(spacing: 0) {
            if pane == .notes {
                RichTextEditor(markdown: $capture.notes, autofocus: autofocusNotes,
                               onEnhanceBlock: engine.isAvailable ? enhanceBlock : nil,
                               bottomInset: showsAsk ? NoteAskBar.clearance : 0)
            } else {
                TranscriptView(capture: capture,
                               bottomInset: showsAsk ? NoteAskBar.clearance : 0)
            }
        }
        .padding(.bottom, showStartOverlay ? 0 : DetailPanel.contentBottom)
        // The panel is a background, not a container, so the panes were free to
        // scroll out through its rounded top and into the window's margin — a whole
        // line of transcript sat above the panel, on bare glass. Blur alone can't
        // help: it softens what's inside the band, not what escapes past it.
        //
        // Cut at the panel's own top edge rather than at the safe area, so the
        // transcript fills the panel and passes under the toolbar instead of stopping
        // short of it and leaving the top strip empty.
        .clippedToDetailPanel(!showStartOverlay,
                              topOverhang: titleBand - DetailPanel.top)
        // A recording has no title block to stop the transcript, so lines ran up
        // into the title bar and over the Transcript/Notes switcher.
        //
        // `scrollEdgeEffectStyle(.soft:)` is the system's answer to this, but it's
        // drawn by the bar, and this window hides its toolbar background and paints
        // its own glass — with no bar surface, the modifier renders nothing. Hence
        // our own band, which blurs whatever is behind it in the window rather than
        // blurring a second copy of the transcript: the panes update on every
        // recognized token, and rendering them twice for a 20pt strip isn't worth it.
        .overlay(alignment: .top) { topBlur }
        .background(alignment: .top) { titleBandProbe }
        // Same treatment as a saved note: the meeting softens behind an open thread.
        // Asked for even mid-recording — reading an answer over a transcript that's
        // still scrolling is harder than losing sight of it for a moment.
        .blur(radius: showsAsk && askThreadOpen ? 14 : 0)
        .animation(.easeInOut(duration: 0.2), value: askThreadOpen)
        .overlay(alignment: .bottom) { askBar }
        .navigationTitle("")
        .detailPanelBackground(inset: !showStartOverlay)
        // Only in the compact idle window (toolbar hidden): a glass Search button
        // above a glass Start button, both top-right. Recording expands the
        // window and Start/Stop moves to the toolbar (RecordButton).
        //
        // NOTE: these sit *below* the title-bar band on purpose. Pushing them up
        // into the title bar (ignoresSafeArea) put them inside the window-drag
        // region, which swallowed the click.
        .overlay(alignment: .topTrailing) {
            if showStartOverlay {
                VStack(spacing: 10) {
                    if let onSearch {
                        glassButton(systemName: "magnifyingglass", help: "Search notes", action: onSearch)
                    }
                    glassButton(systemName: "waveform.badge.mic", help: "Start",
                                emphasized: true, action: onStart)
                    if let onTasks {
                        glassButton(systemName: "checklist", help: "All Tasks", action: onTasks)
                    }
                    if let onAI {
                        glassButton(systemName: "message", help: "Ask AI", action: onAI)
                    }
                    if let onGlossary {
                        glassButton(systemName: "textformat.abc", help: "Glossary", action: onGlossary)
                    }
                }
                .padding(.trailing, 13)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }

    @ViewBuilder private var askBar: some View {
        if showsAsk {
            NoteAskBar(url: askURL, engine: engine,
                       evidence: askEvidence,
                       focusRequest: askFocusRequest, threadOpen: $askThreadOpen)
                .clipShape(RoundedRectangle(cornerRadius: DetailPanel.radius,
                                            style: .continuous))
                .padding(showStartOverlay ? EdgeInsets() : DetailPanel.insets)
        }
    }

    /// How far the frost carries on past the toolbar before it clears. A visual
    /// effect view blurs at a fixed radius, so only its opacity can ramp: full
    /// strength meeting none in 20pt reads as a line drawn across the note however
    /// smooth the gradient between them, which is why this is most of the band.
    private static let topBlurFalloff: CGFloat = 56

    /// Stands in until the probe reports, and if it never does. Toolbar items centre
    /// themselves in a 52pt band, which is the figure the rest of the toolbar's
    /// offsets are tuned against.
    private static let titleBandFallback: CGFloat = 52

    /// A toolbar's safe area isn't published anywhere, so this steps out of it and
    /// asks: inside a view that ignores the top inset, the proxy reports how deep it
    /// was. Zero is discarded rather than trusted — a band of no depth would cut the
    /// panes above the panel, which is the failure this whole treatment exists to fix.
    private var titleBandProbe: some View {
        Color.clear
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { inset in
                if inset > 0 { titleBand = inset }
            }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }

    /// Solid over the toolbar, then eased rather than linear away from it — most of
    /// the depth goes to the last, faintest stretch, which is where a straight ramp
    /// gives itself away.
    private static func topBlurRamp(hold: CGFloat) -> Gradient {
        let rest = 1 - hold
        return Gradient(stops: [
            .init(color: .black, location: 0),
            .init(color: .black, location: hold),
            .init(color: .black.opacity(0.72), location: hold + rest * 0.22),
            .init(color: .black.opacity(0.42), location: hold + rest * 0.44),
            .init(color: .black.opacity(0.18), location: hold + rest * 0.66),
            .init(color: .black.opacity(0.05), location: hold + rest * 0.85),
            .init(color: .clear, location: 1)
        ])
    }

    /// Frosts the strip the transcript passes through on its way out of view, so a
    /// line thins away under the toolbar rather than crossing it sharply.
    /// `withinWindow` blending blurs the panes already drawn beneath it, which keeps
    /// this to one rendering of content that changes on every recognized token.
    @ViewBuilder private var topBlur: some View {
        if !showStartOverlay {
            // Solid across the band the toolbar occupies, then falling off below it.
            let hold = titleBand - DetailPanel.top
            let height = hold + Self.topBlurFalloff
            VisualEffectView(material: .fullScreenUI, blendingMode: .withinWindow)
                .frame(height: height)
                // Shape and ramp in one mask, sized to the band itself — the insets
                // below are applied outside it, so the corners land on the panel's
                // edges rather than the window's. Square, full-width frost read as a
                // stripe laid over the gutters and the panel's rounded top.
                .mask {
                    UnevenRoundedRectangle(topLeadingRadius: DetailPanel.radius,
                                           bottomLeadingRadius: 0,
                                           bottomTrailingRadius: 0,
                                           topTrailingRadius: DetailPanel.radius,
                                           style: .continuous)
                        .fill(
                            LinearGradient(gradient: Self.topBlurRamp(hold: hold / height),
                                           startPoint: .top, endPoint: .bottom)
                        )
                }
                // The same margins the clip uses, so the band's edges and top corners
                // sit exactly on the cut rather than near it.
                .padding(.horizontal, DetailPanel.leading)
                .padding(.top, DetailPanel.top)
                // Up over the title band, where the panes now scroll.
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }

    /// What the ask field answers from during a recording: nothing is on disk yet
    /// worth reading, so it's the live transcript plus whatever has been typed.
    private func askEvidence() -> AskEngine.NoteEvidence {
        let live = capture.entries
            .map { entry -> String in
                if let name = entry.speakerName,
                   !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "\(name): \(entry.text)"
                }
                return "\(entry.speaker.rawValue): \(entry.text)"
            }
            .joined(separator: "\n")
        return AskEngine.NoteEvidence(
            title: askURL?.deletingPathExtension().lastPathComponent ?? "This meeting",
            notes: capture.notes,
            transcript: live,
            pending: capture.isActive ? SavedSessionView.spokenNow(capture) : "",
            isRecording: capture.isActive
        )
    }

    /// Inline collaborator hook for the live session's notes: enhances a hovered
    /// block grounded in the recording captured so far (committed lines only, no
    /// still-changing volatile partials). Notes live in `capture.notes`, so the
    /// commit routes through the same source the recorder autosaves.
    private func enhanceBlock(_ block: String,
                              onPartial: @escaping (String) -> Void) async -> String? {
        let live = capture.entries
            .map { entry -> String in
                if let n = entry.speakerName,
                   !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "\(n): \(entry.text)"
                }
                return "\(entry.speaker.rawValue): \(entry.text)"
            }
            .joined(separator: "\n")
        return await engine.enhanceBlock(block, transcript: live) { partial in
            onPartial(partial)
        }
    }

    /// `emphasized` is Start: it keeps the accent glyph so the one button that begins a
    /// recording still reads as the primary action, and gets a pale disc to carry it,
    /// since accent-on-dark is exactly what the white glyphs were moved away from.
    private func glassButton(systemName: String, help: String, emphasized: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(emphasized ? AnyShapeStyle(Color.accentColor)
                                            : AnyShapeStyle(plainGlyph))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .background {
            if emphasized {
                Circle().fill(.white.opacity(0.75))
            } else if let scrim = compactButtonScrim {
                Circle().fill(scrim)
            }
        }
        .glassEffect(AppAppearance.glass(interactive: true), in: .circle)
        .help(help)
    }

    /// White carries these over the dark scrim, but in light mode the scrim is pale and
    /// white glyphs all but disappeared into it — dark grey is what reads there.
    private var plainGlyph: Color {
        scheme == .dark ? .white : Color(white: 0.25)
    }

    /// The compact window has no panel behind these, so under Clear glass they float
    /// on whatever the window is over and the accent glyphs have to fight it. Layering
    /// the note panel's scrim over the glass — the same trick `detailPanelBackground`
    /// uses — gives them a surface of their own; tinting the glass instead barely
    /// darkened it. Tinted's regular glass is opaque enough on its own.
    private var compactButtonScrim: Color? {
        AppAppearance.liquidGlass
            ? Color(nsColor: .windowBackgroundColor).opacity(0.6)
            : nil
    }
}

// MARK: - Recording consent

private struct RecordingConsentPanel: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        ZStack {
            // Block the transcript and toolbar surface until the user makes a
            // deliberate choice. Unlike Ask, clicking outside does not accept
            // or dismiss this compliance reminder.
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())

            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Get consent from everyone")
                            .font(.system(size: 18, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($headingFocused)
                        Text("Before starting, notify everyone that:")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        consentLine(
                            "This meeting is being recorded for transcription."
                        )
                        consentLine("No audio is retained.")
                        consentLine(
                            "Thread processes and stores the transcript locally "
                                + "on this device only."
                        )
                        consentLine(
                            "Anyone may object at any time. If they do, you are "
                                + "responsible for stopping the transcription "
                                + "immediately."
                        )
                    }

                    Text(
                        "Users are solely responsible for ensuring compliance "
                            + "with applicable local laws, including obtaining "
                            + "necessary consents prior to recording or "
                            + "summarizing audio/meetings."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 9) {
                        Spacer()
                        Button("Cancel", action: onCancel)
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .keyboardShortcut(.cancelAction)
                        Button(
                            "I’ve notified everyone — Start",
                            action: onConfirm
                        )
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    }
                    .padding(20)
                    .frame(maxWidth: 500, alignment: .leading)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: geometry.size.height
                    )
                }
                .scrollIndicators(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(
                AppAppearance.glass(),
                in: .rect(cornerRadius: 20)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
            }
            .padding(12)
        }
        .accessibilityAddTraits(.isModal)
        .onExitCommand(perform: onCancel)
        .onAppear { headingFocused = true }
    }

    private func consentLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - The note's own chat

/// This note's conversation: one text field floating at the foot of the transcript
/// and notes panes, always ready to type in, which grows a thread above itself once
/// you send.
///
/// Floating rather than docked because an inset bar would take ~40pt out of every
/// note and put the panes back in the rounded-corner clearance fight; the panes pad
/// their content by `clearance` instead, so the last line can still be scrolled
/// clear of the field.
///
/// Everything asked here is scoped to this one note, which is what lets the surface
/// stay this small: no scope chip to reason about, and no citations to follow, since
/// every source would be the note already on screen.
private struct NoteAskBar: View {
    /// The note's file, which the conversation is keyed to. Nil for the first
    /// seconds of a new recording, before anything has been said or typed for
    /// autosave to write a file — the conversation moves onto it when it appears.
    let url: URL?
    @ObservedObject var engine: AskEngine
    /// What the question is answered from, gathered by the host view: it's the one
    /// that knows about the note's segments and any recording feeding them.
    var evidence: () -> AskEngine.NoteEvidence
    /// Bumped by ⌘L to focus the field without reaching for the mouse.
    var focusRequest: Int
    /// True while the thread is open. Owned by the parent because what it does is
    /// blur the panes, and the panes aren't ours to blur from in here.
    @Binding var threadOpen: Bool

    /// What the panes leave clear at the bottom for the field.
    static let clearance: CGFloat = 46
    /// Narrow enough to read as a field at the foot of the note rather than a second
    /// pane.
    private static let width: CGFloat = 380
    /// The conversation gets more room than the field it's typed into: it has to hold
    /// answers, and it has no card around it to keep tidy.
    private static let threadWidth: CGFloat = 620
    /// Past this the conversation scrolls rather than climbing the note.
    private static let threadHeight: CGFloat = 340
    private static let topFade: CGFloat = 26
    private static let bottomFade: CGFloat = 16

    @Environment(\.colorScheme) private var scheme
    @State private var query = ""
    @State private var turns: [Turn] = []
    @State private var focusTick = 0
    @State private var streamTask: Task<Void, Never>?
    @State private var contentHeight: CGFloat = 0

    private struct Turn: Identifiable {
        enum Role { case you, ai }
        let id = UUID()
        var role: Role
        var text: String
        var isThinking = false
    }

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            dismissCatcher
            content
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
        .onChange(of: focusRequest) { _, _ in focusTick += 1 }
        .onChange(of: url) { old, new in
            // A new recording's file appears a few seconds in; the conversation
            // started before it moves onto that file, so stopping the recording
            // doesn't interrupt it mid-thread.
            if old == nil, let new {
                engine.noteConversationMoved(from: Self.draftKey, to: new)
            } else if old != new {
                discard(old)
            }
        }
        .onDisappear {
            streamTask?.cancel()
            discard(url)
        }
    }

    /// Where a conversation is keyed until the note has a file of its own.
    private static let draftKey = URL(fileURLWithPath: "/thread/live-draft")

    private var conversationKey: URL { url ?? Self.draftKey }

    /// Asking is a one-off: nothing is written to the note or anywhere else, and
    /// leaving the note ends the conversation. The model's memory of it goes at the
    /// same moment as the turns on screen — a session that outlived the visible
    /// thread would answer follow-ups about a conversation the user can't see.
    private func discard(_ key: URL?) {
        engine.forgetNoteConversation(key ?? Self.draftKey)
        turns = []
        threadOpen = false
    }

    /// Clicking the blurred note closes the thread but keeps it, so glancing back at
    /// what you were asking about costs nothing.
    private var dismissCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .allowsHitTesting(threadOpen)
            .onTapGesture(perform: close)
    }

    /// No card around the conversation: the blur behind it is what separates it from
    /// the note, and a card only added an empty rectangle whenever the answers were
    /// shorter than it was.
    @ViewBuilder private var content: some View {
        if threadOpen && !turns.isEmpty {
            VStack(spacing: 8) {
                thread
                inputBar.frame(maxWidth: Self.width)
            }
            .frame(maxWidth: Self.threadWidth)
            .onExitCommand(perform: close)
        } else {
            inputBar.frame(maxWidth: Self.width)
        }
    }

    /// Measured off the conversation instead of asked for with `ViewThatFits`, which
    /// took the scrolling branch even for two lines and left them stranded at the top of
    /// a 340pt box. Sized to the turns, a short thread sits just above the field; past
    /// the cap it scrolls, anchored to the bottom so it opens on the latest answer.
    private var thread: some View {
        ScrollView {
            turnList
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    contentHeight = $0
                }
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.hidden)
        .frame(height: min(max(contentHeight, 1), Self.threadHeight))
        .mask { threadFade }
    }

    private var turnList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(turns) { turnView($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Keeps the ends of the conversation out of the fades, so a short answer is
        // never dimmed for sitting where it fits.
        .padding(.top, Self.topFade)
        .padding(.bottom, Self.bottomFade)
    }

    /// A long answer dissolves at both ends instead of being sliced: a hard edge
    /// through the middle of a sentence reads as a rendering fault, where a fade
    /// reads as more to scroll to.
    private var threadFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.topFade)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.bottomFade)
        }
    }

    /// The answer and its thinking dots, drawn on the blurred note behind them. White
    /// carries over a dark note, but over a light one it dissolved into the page — dark
    /// grey is what reads there, and it matches the glyph treatment in compact mode.
    private var answerTint: Color {
        scheme == .dark ? .white : Color(white: 0.25)
    }

    @ViewBuilder private func turnView(_ turn: Turn) -> some View {
        if turn.role == .you {
            Text(turn.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        } else if turn.isThinking && turn.text.isEmpty {
            ThinkingDots(tint: answerTint)
        } else {
            AnswerText(
                text: turn.text,
                tint: turn.text == CloudLLM.setupHint
                    ? Color(nsColor: .systemRed) : answerTint,
                bold: true
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            leadingActions
            AIInputField(text: $query,
                         placeholder: "Ask anything",
                         focusTick: focusTick,
                         onSubmit: send,
                         onBackspaceEmpty: {})
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(trimmed.isEmpty)
            .opacity(trimmed.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // The same bare glass as the panel's ask field, with no scrim of its own: a
        // darkening one turned this into a slab laid on the note, and the two fields
        // should read as the same control wherever it appears.
        .glassEffect(AppAppearance.glass(interactive: true), in: .capsule)
        // Over a light note the glass alone left no edge to aim at, so the field was
        // easy to miss until you clicked into it.
        .overlay {
            Capsule().strokeBorder(.primary.opacity(scheme == .dark ? 0.12 : 0.18),
                                   lineWidth: 1)
        }
        .onExitCommand(perform: close)
    }

    /// Closing sits in the field rather than over the conversation: it's where the hand
    /// already is, and above a short thread it floated halfway up the note. Closed, the
    /// field carries nothing but the question — the thread comes back with the next
    /// answer.
    @ViewBuilder private var leadingActions: some View {
        if threadOpen {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    /// Keeps the thread and any half-typed question — closing is a glance back at the
    /// note, not a dismissal.
    private func close() {
        withAnimation(.easeInOut(duration: 0.2)) { threadOpen = false }
    }

    private func send() {
        let text = trimmed
        guard !text.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.2)) { threadOpen = true }
        turns.append(Turn(role: .you, text: text))
        turns.append(Turn(role: .ai, text: "", isThinking: true))
        let answer = turns.count - 1
        query = ""
        focusTick += 1

        streamTask?.cancel()
        let events = engine.askNote(text, note: conversationKey, evidence: evidence())
        streamTask = Task { @MainActor in
            for await event in events {
                guard answer < turns.count else { break }
                switch event {
                case .sources:
                    break // Always this note, so there is nothing to cite.
                case .answer(let text):
                    turns[answer].text = text
                    turns[answer].isThinking = false
                case .failed(let reason):
                    turns[answer].text = reason
                    turns[answer].isThinking = false
                }
            }
            if answer < turns.count, turns[answer].isThinking {
                turns[answer].isThinking = false
                if turns[answer].text.isEmpty {
                    turns[answer].text = "I couldn't find an answer in this note."
                }
            }
        }
    }
}

// MARK: - AI prompt panel

private struct AIMessage: Identifiable {
    enum Role { case you, ai }
    let id = UUID()
    let role: Role
    var text: String
    var isThinking: Bool = false
    var sources: [AskSource] = []
}

/// Floating "Ask AI" surface. Starts as a lone glass pill centered in the
/// detail area; after the first send it grows into a glass card whose bottom
/// wraps around the same input pill (Granola-style). UI only for now — sending
/// echoes the query and shows a placeholder response.
private struct AIPanel: View {
    @Binding var isPresented: Bool
    @ObservedObject var engine: AskEngine
    /// The saved note in view, if any. Present → the `@ current note` chip is
    /// offered and scopes the query to that file; nil → scope is all notes.
    let currentNoteURL: URL?
    /// Opens a note (from a citation / source chip) in the main window.
    let onOpenNote: (URL) -> Void
    @State private var query = ""
    @State private var messages: [AIMessage] = []
    @State private var hasScope: Bool
    @State private var hoveringChip = false
    @State private var focusTick = 0
    @State private var streamTask: Task<Void, Never>?

    init(isPresented: Binding<Bool>, engine: AskEngine, currentNoteURL: URL?,
         onOpenNote: @escaping (URL) -> Void) {
        _isPresented = isPresented
        self.engine = engine
        self.currentNoteURL = currentNoteURL
        self.onOpenNote = onOpenNote
        _hasScope = State(initialValue: currentNoteURL != nil)
    }

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            // Invisible tap-catcher (the actual soft-focus is a real blur applied
            // to the transcript/notes behind this panel). Tapping outside the
            // card dismisses.
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                panel
                    .frame(maxWidth: 434)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onExitCommand(perform: close)
        .onAppear { focusTick += 1 }
        .onDisappear { streamTask?.cancel() }
    }

    // The input is always rendered with the same interior padding so it sits at
    // the same spot whether it's alone or docked at the bottom of the card —
    // sending never shifts the field.
    @ViewBuilder private var panel: some View {
        if messages.isEmpty {
            inputBar.padding(6)
        } else {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { messageView($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 340)
                inputBar.padding(6)
            }
            .glassEffect(AppAppearance.glass(), in: RoundedRectangle(cornerRadius: 22))
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            if hasScope { scopeChip }
            AIInputField(text: $query,
                         placeholder: "Ask anything",
                         focusTick: focusTick,
                         onSubmit: send,
                         onBackspaceEmpty: {
                             if hasScope { hasScope = false }
                         })
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(trimmed.isEmpty)
            .opacity(trimmed.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(AppAppearance.glass(interactive: true), in: .capsule)
    }

    // Hovering swaps the leading "@" for an "x"; clicking (or backspace on an
    // empty field) removes it.
    private var scopeChip: some View {
        Button { hasScope = false } label: {
            HStack(spacing: 3) {
                Image(systemName: hoveringChip ? "xmark" : "at")
                    .font(.system(size: 10, weight: .semibold))
                Text("current note")
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.quaternary))
        }
        .buttonStyle(.plain)
        .onHover { hoveringChip = $0 }
    }

    @ViewBuilder private func messageView(_ message: AIMessage) -> some View {
        if message.role == .you {
            Text(message.text)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        } else {
            VStack(alignment: .leading, spacing: 5) {
                if message.isThinking && message.text.isEmpty {
                    ThinkingDots()
                } else {
                    AnswerText(
                        text: message.text,
                        tint: message.text == CloudLLM.setupHint
                            ? Color(nsColor: .systemRed) : .blue
                    )
                }
                if !message.sources.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(Array(message.sources.enumerated()), id: \.element.id) { index, source in
                            Button { onOpenNote(source.url) } label: {
                                HStack(spacing: 4) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color.blue)
                                    Text(source.title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(.quaternary))
                            }
                            .buttonStyle(.plain)
                            .help("Open \(source.title)")
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func send() {
        let text = trimmed
        guard !text.isEmpty else { return }
        let scope: AskScope = (hasScope && currentNoteURL != nil)
            ? .currentNote(currentNoteURL!) : .allNotes

        messages.append(AIMessage(role: .you, text: text))
        messages.append(AIMessage(role: .ai, text: "", isThinking: true))
        let aiIndex = messages.count - 1
        query = ""
        focusTick += 1

        streamTask?.cancel()
        let events = engine.ask(text, scope: scope)
        streamTask = Task { @MainActor in
            for await event in events {
                guard aiIndex < messages.count else { break }
                switch event {
                case .sources(let sources):
                    messages[aiIndex].sources = sources
                case .answer(let answer):
                    messages[aiIndex].text = answer
                    messages[aiIndex].isThinking = false
                case .failed(let reason):
                    messages[aiIndex].text = reason
                    messages[aiIndex].isThinking = false
                }
            }
            if aiIndex < messages.count, messages[aiIndex].isThinking {
                messages[aiIndex].isThinking = false
                if messages[aiIndex].text.isEmpty {
                    messages[aiIndex].text = "I couldn't find an answer in your notes."
                }
            }
        }
    }

    private func close() {
        isPresented = false
    }
}

/// The central Tasks surface: every note's action items in one place, grouped
/// by folder → note. Toggling a box persists back to that note's file (and
/// notifies any open editor); tapping a task jumps to its note.
private struct AllTasksView: View {
    @ObservedObject var store: SessionStore
    /// Driven by the toolbar's All | Open switcher (Open == hide completed).
    let hideCompleted: Bool
    let onOpenNote: (URL) -> Void

    /// One note's tasks, keyed by its file URL.
    private struct NoteTasks: Identifiable {
        let url: URL
        let title: String
        var tasks: [TaskItem]
        var id: URL { url }
    }
    /// One library folder and the notes under it that have tasks.
    private struct FolderTasks: Identifiable {
        let folderURL: URL
        let name: String
        var notes: [NoteTasks]
        var id: URL { folderURL }
    }

    @State private var folders: [FolderTasks] = []

    private var totalRemaining: Int {
        folders.reduce(0) { sum, folder in
            sum + folder.notes.reduce(0) { $0 + $1.tasks.filter { !$0.done }.count }
        }
    }

    /// Notes to display after applying the hide-completed filter. A note with
    /// only completed tasks disappears entirely when completed are hidden.
    private func visibleNotes(_ folder: FolderTasks) -> [NoteTasks] {
        guard hideCompleted else { return folder.notes }
        return folder.notes.compactMap { note in
            let open = note.tasks.filter { !$0.done }
            return open.isEmpty ? nil : NoteTasks(url: note.url, title: note.title, tasks: open)
        }
    }

    private func visibleFolders() -> [FolderTasks] {
        folders.compactMap { folder in
            let notes = visibleNotes(folder)
            return notes.isEmpty ? nil : FolderTasks(folderURL: folder.folderURL,
                                                     name: folder.name, notes: notes)
        }
    }

    /// Renders inline Markdown (e.g. `**bold**`) in a task's text.
    private static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                let shown = visibleFolders()
                if shown.isEmpty {
                    emptyState
                } else {
                    ForEach(shown) { folder in
                        folderSection(folder)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear(perform: rebuild)
        .onReceive(store.$groups) { _ in rebuild() }
        .onReceive(NotificationCenter.default.publisher(for: .threadTasksDidChange)) { _ in
            rebuild()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Tasks")
                .font(.system(size: 22, weight: .bold))
            Text(totalRemaining == 0
                 ? "You're all caught up"
                 : "\(totalRemaining) open across your notes")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checklist")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.tertiary)
            Text(hideCompleted ? "No open tasks" : "No tasks yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(hideCompleted
                 ? "Everything with a task is complete."
                 : "Tasks you add in a note — or that Enhance extracts — show up here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    private func folderSection(_ folder: FolderTasks) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(folder.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(folder.notes) { note in
                noteCard(note)
            }
        }
    }

    private func noteCard(_ note: NoteTasks) -> some View {
        let remaining = note.tasks.filter { !$0.done }.count
        return VStack(alignment: .leading, spacing: 8) {
            Button { onOpenNote(note.url) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(note.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(remaining) left")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open note")

            ForEach(note.tasks) { task in
                Button { toggle(note.url, task) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(task.done ? Color.accentColor : Color.secondary)
                        Text(Self.rendered(task.text))
                            .font(.body)
                            .strikethrough(task.done, color: .secondary)
                            .foregroundStyle(task.done ? .secondary : .primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(AppAppearance.glass(), in: .rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
        }
    }

    /// Reads every note's tasks fresh, keeping only notes that have at least one.
    private func rebuild() {
        folders = store.groups.compactMap { group in
            let notes = group.files.compactMap { file -> NoteTasks? in
                let tasks = store.loadTasks(file.url)
                guard !tasks.isEmpty else { return nil }
                return NoteTasks(url: file.url, title: file.title, tasks: tasks)
            }
            return notes.isEmpty ? nil : FolderTasks(folderURL: group.folderURL,
                                                     name: group.name, notes: notes)
        }
    }

    /// Flips a task's done-state and writes the note's full list back to disk,
    /// then notifies any open editor for that note to reload its strip.
    private func toggle(_ url: URL, _ task: TaskItem) {
        guard let fi = folders.firstIndex(where: { $0.notes.contains { $0.url == url } }),
              let ni = folders[fi].notes.firstIndex(where: { $0.url == url }),
              let ti = folders[fi].notes[ni].tasks.firstIndex(where: { $0.id == task.id })
        else { return }
        folders[fi].notes[ni].tasks[ti].done.toggle()
        store.saveTasks(url, tasks: folders[fi].notes[ni].tasks)
        NotificationCenter.default.post(name: .threadTasksDidChange, object: url)
    }
}

/// Renders an AI answer's lightweight Markdown — paragraphs, bullet and
/// numbered lists, inline bold/italic — in blue, with `[n]` citation markers
/// shown as small raised superscripts.
private struct AnswerText: View {
    let text: String
    /// Accent blue on the panel's card; the note's own chat overrides it, since it
    /// renders straight onto a blurred note where thin blue text doesn't hold up.
    var tint: Color = .blue
    var bold = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.parse(text)) { block in
                switch block.kind {
                case .heading:
                    Text(block.content).font(.headline)
                case .paragraph:
                    Text(block.content).font(.body)
                case .bullet:
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                        Text(block.content)
                        Spacer(minLength: 0)
                    }
                    .font(.body)
                case .numbered(let n):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(n).")
                        Text(block.content)
                        Spacer(minLength: 0)
                    }
                    .font(.body)
                }
            }
        }
        .foregroundStyle(tint)
        .fontWeight(bold ? .bold : nil)
        .multilineTextAlignment(.leading)
    }

    private struct Block: Identifiable {
        enum Kind: Equatable { case heading, paragraph, bullet, numbered(Int) }
        let id: Int
        let kind: Kind
        let content: AttributedString
    }

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var idx = 0
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            defer { idx += 1 }

            if line.hasPrefix("#") {
                let t = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(Block(id: idx, kind: .heading, content: inline(t)))
                continue
            }
            // Numbered lists accept either a period or closing parenthesis marker.
            // Require a space/end after the mark
            // so decimals like "3.5" aren't mistaken for a list).
            if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }),
               dot != line.startIndex,
               line[line.startIndex..<dot].allSatisfy(\.isNumber),
               let n = Int(line[line.startIndex..<dot]) {
                let after = line.index(after: dot)
                if after == line.endIndex || line[after] == " " {
                    let rest = line[after...].trimmingCharacters(in: .whitespaces)
                    blocks.append(Block(id: idx, kind: .numbered(n), content: inline(rest)))
                    continue
                }
            }
            if let first = line.first, "-*•".contains(first) {
                let rest = line.dropFirst().trimmingCharacters(in: .whitespaces)
                blocks.append(Block(id: idx, kind: .bullet, content: inline(rest)))
                continue
            }
            blocks.append(Block(id: idx, kind: .paragraph, content: inline(line)))
        }
        return blocks
    }

    /// Parses inline Markdown (bold/italic) and raises `[n]` citations.
    private static func inline(_ s: String) -> AttributedString {
        var attr = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        let rendered = String(attr.characters)
        if let regex = try? NSRegularExpression(pattern: "\\[\\d+\\]") {
            let ns = rendered as NSString
            for match in regex.matches(in: rendered, range: NSRange(location: 0, length: ns.length)) {
                let start = attr.index(attr.startIndex, offsetByCharacters: match.range.location)
                let end = attr.index(start, offsetByCharacters: match.range.length)
                attr[start..<end].font = .system(size: 9, weight: .bold)
                attr[start..<end].baselineOffset = 5
            }
        }
        return attr
    }
}

/// A simple wrapping layout (left-to-right, wrapping to new rows) for the
/// citation source chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Three dots that fill in sequence and loop — the Ask "thinking" indicator.
private struct ThinkingDots: View {
    /// Matches whatever the answer it precedes will be drawn in.
    var tint: Color = .blue
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.35, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(tint)
                    // Filled once the sweep reaches this dot; empties on wrap.
                    .opacity(i <= phase ? 1 : 0.18)
                    .frame(width: 7, height: 7)
                    .animation(.easeInOut(duration: 0.25), value: phase)
            }
        }
        .frame(height: 18)
        .onReceive(timer) { _ in
            // 0,1,2 fill one by one, then a blank beat before repeating.
            phase = phase >= 3 ? 0 : phase + 1
        }
    }
}

/// AppKit-backed single-line field: reliably reports Return (submit) and
/// backspace-on-empty (which SwiftUI's TextField swallows), and refocuses when
/// `focusTick` changes.
/// A switch for the Setup cards whose off state stays a clearly visible gray.
/// The system `.switch` draws its off track nearly white, which washed out over
/// the translucent glass cards in light mode; this draws its own track so both
/// states read at a glance in either appearance.
struct SetupToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return Capsule()
            .fill(on ? Color.accentColor : Color(nsColor: .systemGray).opacity(0.6))
            .frame(width: 38, height: 22)
            .overlay(alignment: on ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
                    .padding(2)
            }
            .overlay { Capsule().strokeBorder(.black.opacity(0.08), lineWidth: 0.5) }
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) { configuration.isOn.toggle() }
            }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
    }
}

private struct AIInputField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusTick: Int
    var onSubmit: () -> Void
    var onBackspaceEmpty: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.placeholderString = placeholder
        if context.coordinator.lastFocusTick != focusTick {
            context.coordinator.lastFocusTick = focusTick
            DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AIInputField
        var lastFocusTick = -1
        init(_ parent: AIInputField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.deleteBackward(_:)):
                if control.stringValue.isEmpty {
                    parent.onBackspaceEmpty()
                    return true
                }
                return false
            default:
                return false
            }
        }
    }
}

/// Which template Enhance will use and the button that runs it, as one capsule under
/// the note's title: the name reads as a caption on the note it belongs to, and the
/// action sits at the end of the sentence it describes.
///
/// Was a toolbar item, where the name had to be capped hard enough to keep the whole
/// trailing run out of the window's >> overflow menu. Here it only has to share a
/// line with the title.
private struct EnhanceBar: View {
    @ObservedObject var templates: EnhanceTemplateStore
    /// Empty selects Thread's built-in Default; otherwise a template's UUID string.
    @Binding var selectedID: String
    /// Display name for `selectedID`, resolved by the parent (which needs it for the
    /// Setup row too).
    var name: String
    var isEnhancing: Bool
    var isAvailable: Bool
    var unavailableReason: String?
    var onEnhance: () -> Void = {}
    var onOpenTemplates: (Bool) -> Void = { _ in }

    @State private var hoveringName = false
    @State private var hoveringRun = false
    @Environment(\.colorScheme) private var scheme

    private var canEnhance: Bool { !isEnhancing && isAvailable }

    /// Full white on hover, a shade back at rest, and dimmed when there is nothing
    /// to run — the disc carries the button's state now that it has no glyph colour.
    private var discOpacity: Double {
        guard canEnhance else { return 0.4 }
        return hoveringRun ? 1 : 0.88
    }

    var body: some View {
        // Enough of a gap that a faded name reads as running out of room rather than
        // as sliding under the button.
        HStack(spacing: 8) {
            cappedTemplateMenu
            runButton
        }
        .padding(.leading, 4)
        .padding(.trailing, 3)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    /// The cap sits out here, around the menu, because a `Menu` lays its label out
    /// itself and discards a width applied inside it.
    @ViewBuilder private var cappedTemplateMenu: some View {
        if Self.nameWidth(name) + Self.labelChrome > Self.labelCap {
            templateMenu
                // Let the menu lay out at its full width first, then clip the box
                // around it. Constrained directly it ellipsises its own label, and
                // the fade never gets anything to act on.
                .fixedSize()
                .frame(width: Self.labelCap, alignment: .leading)
                .clipped()
                // Fade rather than ellipsise: an ellipsis reads as a clipped button
                // title, the fade as a name that runs on.
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black,
                                  location: (Self.labelCap - 30) / Self.labelCap),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing)
                }
        } else {
            templateMenu
        }
    }

    private var templateMenu: some View {
        Menu {
            Picker("Template", selection: $selectedID) {
                Text("Default").tag("")
                ForEach(templates.templates) { template in
                    Text(template.name.isEmpty ? "Untitled Template" : template.name)
                        .tag(template.id.uuidString)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button { onOpenTemplates(true) } label: {
                Label("New", systemImage: "plus")
            }
            Button { onOpenTemplates(false) } label: {
                Label("Edit", systemImage: "pencil")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                if hoveringName { Capsule().fill(Color.primary.opacity(0.08)) }
            }
            .contentShape(Capsule())
        }
        // The name itself is the control; a chevron beside it would read as a
        // separate button inside the capsule.
        .menuIndicator(.hidden)
        // Left native, a menu draws its own dark hover slab, which reads as a black
        // box on the note.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .onHover { hoveringName = $0 }
        .accessibilityLabel("Enhance template")
        .help("Enhance template: \(name)")
    }

    /// Runs the enhance, circular and at the capsule's trailing end: the name says
    /// what will happen, this starts it.
    private var runButton: some View {
        Button(action: onEnhance) {
            ZStack {
                if isEnhancing {
                    ProgressView().controlSize(.small)
                } else if scheme == .light {
                    // A white disc has nothing to stand out from on a light capsule,
                    // so here the glyph carries the button: accent blue, over a tint
                    // that appears on hover.
                    if hoveringRun && canEnhance {
                        Circle().fill(Color.accentColor.opacity(0.15))
                    }
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor.opacity(canEnhance ? 1 : 0.4))
                } else {
                    // The disc is the glyph: sparkles knocked out of it, so the
                    // capsule's own dark fill reads through the cut.
                    Circle()
                        .fill(.white.opacity(discOpacity))
                        .overlay {
                            Image(systemName: "sparkles")
                                .font(.system(size: 12, weight: .semibold))
                                .blendMode(.destinationOut)
                        }
                        // The knockout is scoped to this group; without it the cut
                        // punches through the note behind the capsule as well.
                        .compositingGroup()
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringRun = $0 }
        .disabled(!canEnhance)
        .accessibilityLabel("Enhance notes")
        .accessibilityValue(isEnhancing ? "In progress" : "\(name) template")
        .help(isAvailable
              ? "Enhance notes with \(name)"
              : (unavailableReason ?? "AI is unavailable"))
    }

    /// Names are user-authored and unbounded; past this the label fades out.
    private static let labelCap: CGFloat = 260

    /// The glyph, its spacing, and the label's own horizontal insets.
    private static let labelChrome: CGFloat = 32

    private static func nameWidth(_ name: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        return ceil((name as NSString).size(withAttributes: [.font: font]).width) + 1
    }
}

/// Start/Stop toolbar button. While recording it shows an animated red waveform
/// (instead of a static stop glyph); idle it shows the mic-waveform to start.
private struct RecordButton: View {
    @ObservedObject var capture: AudioCaptureController
    let onStart: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            if capture.isActive { capture.stop() } else { onStart() }
        } label: {
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
            // Matches the compact window's discs, and leaves the waveform clear of the
            // edge — at 24 the glyph ran right up against it.
            .frame(width: 26, height: 26)
            // Dark mode only, and the same pale disc the compact window already puts
            // under this button: a coloured glyph on a dark toolbar is thin, and it's
            // the one control here that should read as primary. In light mode the
            // toolbar is already pale, so a white disc would only blur its edges.
            .background {
                if scheme == .dark { Circle().fill(.white.opacity(0.75)) }
            }
        }
        .help(capture.isActive ? "Stop" : "Start")
    }
}

private struct TranscriptView: View {
    @ObservedObject var capture: AudioCaptureController
    /// Room at the foot for the floating ask field, so the newest line can still be
    /// scrolled clear of it.
    var bottomInset: CGFloat = 0

    // Committed (finalized) lines. Only changes when a result finalizes, so the
    // heavy grouped view below is rebuilt rarely — not on every draft token.
    private var committedItems: [TranscriptItem] {
        // Order by when each turn's audio *started*, not when it finalized: the
        // mic ("You") and system-audio ("Meeting") recognizers finalize
        // independently, so finalize-order can differ from spoken order.
        capture.entries
            .sorted { $0.startedAt < $1.startedAt }
            .map {
                TranscriptItem(id: $0.id.uuidString, speaker: $0.speaker, text: $0.text,
                               isLive: false, speakerName: $0.speakerName)
            }
    }

    // Live (volatile) lines — the still-changing draft, shown lighter.
    private var liveItems: [TranscriptItem] {
        var result: [TranscriptItem] = []
        if !capture.youVolatile.isEmpty {
            result.append(TranscriptItem(id: "live-you", speaker: .you, text: capture.youVolatile,
                                         isLive: true, speakerName: capture.localUserName))
        }
        if !capture.meetingVolatile.isEmpty {
            result.append(TranscriptItem(id: "live-meeting", speaker: .meeting, text: capture.meetingVolatile,
                                         isLive: true, speakerName: capture.meetingVolatileSpeaker))
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if committedItems.isEmpty && liveItems.isEmpty {
                        EmptyState()
                            .padding(.top, 60)
                    } else {
                        VStack(spacing: 14) {
                            // `.equatable()` lets SwiftUI skip re-rendering (and
                            // re-grouping) the whole committed transcript when
                            // only the live draft changed.
                            GroupedTranscript(items: committedItems)
                                .equatable()
                            if !liveItems.isEmpty {
                                GroupedTranscript(items: liveItems)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(20)
            }
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
            // Animate only when a new bubble lands; draft tokens scroll instantly
            // (continuous animation on every token caused jank that grew with
            // transcript length).
            .onChange(of: capture.entries.count) { _, _ in scrollToBottom(proxy, animated: true) }
            .onChange(of: capture.youVolatile) { _, _ in scrollToBottom(proxy, animated: false) }
            .onChange(of: capture.meetingVolatile) { _, _ in scrollToBottom(proxy, animated: false) }
        }
        .background(TranscriptRenderProbe(revision: capture.transcriptRevision))
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}

private struct TranscriptRenderProbe: NSViewRepresentable {
    let revision: Int

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        TranscriptionDiagnostics.shared.recordRendered(revision: revision)
    }
}

// MARK: - Glossary panel

enum GlossaryPanelMode {
    /// Post-enhance inbox of proposed corrections to accept or dismiss.
    case suggestions
    /// The full list of learned terms, each removable.
    case allTerms
}

/// Right-docked glass panel. In `.suggestions` mode it shows mis-heard proper
/// nouns turned up by an enhance (accept teaches the glossary + fixes the note);
/// in `.allTerms` mode it lists every saved term with a delete action.
private struct GlossaryPanel: View {
    var mode: GlossaryPanelMode = .suggestions
    @Binding var candidates: [GlossaryCandidate]
    @ObservedObject var glossary: Glossary
    /// The note in view — accepted corrections are applied to it in place.
    var currentNoteURL: URL?
    var onClose: () -> Void = {}
    @State private var expandedCandidateIDs: Set<UUID> = []

    static let width: CGFloat = DetailPanel.columnWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch mode {
            case .suggestions: suggestionsBody
            case .allTerms: allTermsBody
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // Content insets only; the surface behind all of this belongs to
        // `dockedColumn`, which has to reach further up than the content may.
        .padding(.vertical, DetailPanel.top)
        .padding(.trailing, DetailPanel.trailing)
        .onExitCommand(perform: onClose)
        .onChange(of: candidates) { _, updated in
            expandedCandidateIDs.formIntersection(Set(updated.map(\.id)))
        }
    }

    // MARK: Suggestions mode

    private var suggestionsBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(candidates) { row($0) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            if candidates.count > 1 {
                Divider().opacity(0.35)
                Button(action: acceptAll) {
                    Text("Add all")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: All-terms mode

    private var allTermsBody: some View {
        Group {
            if glossary.terms.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "textformat.abc")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("No terms yet")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Corrections you accept will show up here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(glossary.terms.sorted { $0.canonical.localizedCaseInsensitiveCompare($1.canonical) == .orderedAscending }) { termRow($0) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private func termRow(_ term: GlossaryTerm) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(term.canonical)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if !term.variants.isEmpty {
                    Text("also heard: " + term.variants.joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Button { glossary.remove(term) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(term.canonical)")
            .help("Delete term")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Glossary")
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var subtitle: LocalizedStringKey {
        switch mode {
        case .suggestions: return "^[\(candidates.count) suggestion](inflect: true)"
        case .allTerms: return "^[\(glossary.terms.count) term](inflect: true)"
        }
    }

    private func row(_ c: GlossaryCandidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    guard !c.contexts.isEmpty else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if expandedCandidateIDs.contains(c.id) {
                            expandedCandidateIDs.remove(c.id)
                        } else {
                            expandedCandidateIDs.insert(c.id)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(c.variant)
                                .foregroundStyle(.secondary)
                                .strikethrough(true, color: .secondary.opacity(0.6))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(c.canonical)
                                .fontWeight(.semibold)
                        }
                        .font(.system(size: 12))
                        .lineLimit(1)
                        if !c.contexts.isEmpty {
                            HStack(spacing: 4) {
                                Text(c.count == 1 ? "heard once" : "heard \(c.count)×")
                                Image(systemName: expandedCandidateIDs.contains(c.id)
                                      ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityLabel("\(c.variant), suggested correction \(c.canonical), heard \(c.count) times")
                .accessibilityHint(c.contexts.isEmpty ? "" : "Shows the sentences where it was heard")

                Button { dismiss(c) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Dismiss for this note")
                .accessibilityLabel("Dismiss for this note")
                Button { accept(c) } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .glassEffect(AppAppearance.glass(interactive: true), in: .circle)
                .help("Add to glossary")
                .accessibilityLabel("Add \(c.canonical) to glossary")
            }

            if expandedCandidateIDs.contains(c.id), !c.contexts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(c.contexts.enumerated()), id: \.offset) { _, context in
                        Text(highlightedContext(context, term: c.variant))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
    }

    private func highlightedContext(_ context: String, term: String) -> AttributedString {
        let result = NSMutableAttributedString(string: context)
        let pattern = Glossary.matchingPattern(for: term)
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let fullRange = NSRange(location: 0, length: (context as NSString).length)
            for match in regex.matches(in: context, range: fullRange) {
                result.addAttribute(
                    .font,
                    value: NSFont.boldSystemFont(ofSize: 10),
                    range: match.range
                )
            }
        }
        return AttributedString(result)
    }

    private func accept(_ c: GlossaryCandidate) {
        glossary.accept(c)
        applyInPlace(c)
        remove(c)
    }

    private func dismiss(_ c: GlossaryCandidate) {
        if let currentNoteURL {
            glossary.dismiss(c, for: currentNoteURL)
        }
        remove(c)
    }

    private func acceptAll() {
        for c in candidates {
            glossary.accept(c)
            applyInPlace(c)
        }
        onClose()
    }

    /// Corrects the currently-open note's text immediately so accepting a
    /// suggestion visibly fixes the note (not just future enhances).
    private func applyInPlace(_ c: GlossaryCandidate) {
        guard let url = currentNoteURL else { return }
        NotificationCenter.default.post(
            name: .threadApplyCorrection,
            object: CorrectionRequest(url: url, variant: c.variant, canonical: c.canonical))
    }

    private func remove(_ c: GlossaryCandidate) {
        expandedCandidateIDs.remove(c.id)
        withAnimation(.easeInOut(duration: 0.2)) {
            candidates.removeAll { $0.id == c.id }
        }
    }
}

// MARK: - Enhance template panel

/// Right-side dock for choosing and writing Enhance templates. It lives here
/// rather than in Setup because a template is a prompt aimed at the note you're
/// looking at: docked, you can enhance, read the result, reword the instructions
/// and run it again without ever leaving the note.
private struct EnhanceTemplatePanel: View {
    @ObservedObject var templates: EnhanceTemplateStore
    /// Empty selects Thread's built-in Default; otherwise a template's UUID string.
    @Binding var selectedID: String
    /// The one template expanded for editing. Owned by the parent so opening the
    /// panel with "New Template" can land straight in the new row's editor.
    @Binding var editingID: UUID?
    var onClose: () -> Void = {}

    static let width: CGFloat = DetailPanel.columnWidth

    @FocusState private var focusedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 8) {
                    defaultRow
                    ForEach($templates.templates) { $template in
                        if editingID == template.id {
                            editor($template)
                        } else {
                            summary(template)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            // Matches the tasks column's Add row: same glyph, weight and inset, so
            // the foot of either column reads as the same kind of invitation.
            Button(action: addTemplate) {
                HStack(spacing: 9) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 14))
                    Text("New Template")
                        .font(.system(size: 12))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // Content insets only; see `GlossaryPanel`.
        .padding(.vertical, DetailPanel.top)
        .padding(.trailing, DetailPanel.trailing)
        .onExitCommand(perform: onClose)
        .onAppear { focus(editingID) }
        .onChange(of: editingID) { _, id in focus(id) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Enhance Templates")
                    .font(.system(size: 13, weight: .semibold))
                Text("^[\(templates.templates.count) template](inflect: true)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// Thread's built-in instructions: selectable like any other row, but not
    /// editable — it keeps improving through app updates.
    private var defaultRow: some View {
        row(isSelected: selectedID.isEmpty, select: { selectedID = "" }) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Default")
                    .font(.system(size: 12, weight: .semibold))
                Text("Built into Thread and improved through app updates.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func summary(_ template: EnhanceTemplate) -> some View {
        row(isSelected: selectedID == template.id.uuidString,
            select: { selectedID = template.id.uuidString }) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(template))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(template.instructions.isEmpty
                         ? "No custom instructions"
                         : template.instructions)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Button { beginEditing(template.id) } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(displayName(template))")
                .help("Edit template")
            }
        }
    }

    private func editor(_ template: Binding<EnhanceTemplate>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Template name", text: template.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .focused($focusedID, equals: template.wrappedValue.id)
                    .onSubmit(endEditing)
                Button("Done", action: endEditing)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Button(role: .destructive) {
                    delete(template.wrappedValue)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(displayName(template.wrappedValue))")
                .help("Delete template")
            }

            TextEditor(text: template.instructions)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 140)
                .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 9))

            Text("Added to Thread's protected grounding and formatting rules.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
        }
    }

    /// Shared chrome for a selectable row: click anywhere to make it the active
    /// template, with a checkmark marking the current one.
    private func row<Content: View>(isSelected: Bool,
                                    select: @escaping () -> Void,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
            Spacer(minLength: 4)
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.accentColor)
                .opacity(isSelected ? 1 : 0)
                .accessibilityHidden(!isSelected)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(isSelected ? 0.6 : 0.4), in: .rect(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }

    private func displayName(_ template: EnhanceTemplate) -> String {
        let name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled Template" : name
    }

    private func addTemplate() {
        let id = templates.add()
        selectedID = id.uuidString
        beginEditing(id)
    }

    private func beginEditing(_ id: UUID) {
        withAnimation(.easeInOut(duration: 0.15)) { editingID = id }
    }

    private func endEditing() {
        editingID = nil
        focusedID = nil
    }

    private func focus(_ id: UUID?) {
        guard let id else { return }
        DispatchQueue.main.async { focusedID = id }
    }

    private func delete(_ template: EnhanceTemplate) {
        if selectedID == template.id.uuidString { selectedID = "" }
        if editingID == template.id { endEditing() }
        // Let SwiftUI tear down the row's TextField/TextEditor bindings before
        // removing the array element they read from.
        DispatchQueue.main.async { templates.remove(template) }
    }
}

// MARK: - Note tasks panel

/// Right-side dock for the open note's checklist, opened by the chip beside the
/// enhance bar. It replaced a strip pinned under the editor, which spent a slice
/// of every note's height on tasks whether or not the note had any, and could not
/// be put away.
private struct NoteTasksPanel: View {
    let url: URL
    @ObservedObject var store: SessionStore
    var onClose: () -> Void = {}

    static let width: CGFloat = DetailPanel.columnWidth

    @State private var tasks: [TaskItem] = []
    @State private var newTask = ""
    @State private var hovered: TaskItem.ID?

    private var remaining: Int { tasks.filter { !$0.done }.count }

    /// Renders inline Markdown (e.g. `**bold**`) in a task's text.
    private static func rendered(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if tasks.isEmpty { emptyState } else { list }
            addRow
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        // Content insets only; see `GlossaryPanel`.
        .padding(.vertical, DetailPanel.top)
        .padding(.trailing, DetailPanel.trailing)
        .onExitCommand(perform: onClose)
        .onAppear { tasks = store.loadTasks(url) }
        .onChange(of: url) { _, moved in tasks = store.loadTasks(moved) }
        .onReceive(NotificationCenter.default.publisher(for: .threadTasksDidChange)) { note in
            // An enhance, the AI, or the global Tasks view rewrote this file.
            if (note.object as? URL) == url { tasks = store.loadTasks(url) }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Tasks")
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var subtitle: String {
        if tasks.isEmpty { return "Nothing yet" }
        if remaining == 0 { return "All done" }
        return "\(remaining) left"
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(tasks) { row($0) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checklist")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No tasks yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Add one below, or let Enhance pull the action items out of the transcript.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }

    private func row(_ task: TaskItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Button { toggle(task) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(task.done ? Color.accentColor : Color.secondary)
                    Text(Self.rendered(task.text))
                        .font(.system(size: 12))
                        .strikethrough(task.done, color: .secondary)
                        .foregroundStyle(task.done ? .secondary : .primary)
                        .multilineTextAlignment(.leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            Button { remove(task) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(hovered == task.id ? 1 : 0)
            .accessibilityLabel("Delete task")
            .help("Delete task")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 12))
        .onHover { hovered = $0 ? task.id : (hovered == task.id ? nil : hovered) }
    }

    private var addRow: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            TextField("Add task", text: $newTask)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(add)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func toggle(_ task: TaskItem) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[i].done.toggle()
        save()
    }

    private func remove(_ task: TaskItem) {
        tasks.removeAll { $0.id == task.id }
        save()
    }

    private func add() {
        let trimmed = newTask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tasks.append(TaskItem(text: trimmed, done: false))
        newTask = ""
        save()
    }

    /// The note's own view keeps a copy of the list for the chip's count, and the
    /// global Tasks view reads the files — the notification is what keeps both true.
    private func save() {
        store.saveTasks(url, tasks: tasks)
        NotificationCenter.default.post(name: .threadTasksDidChange, object: url)
    }
}

// MARK: - Saved (read-only) detail

private struct SavedSessionView: View {
    let url: URL
    @ObservedObject var store: SessionStore
    var pane: SessionPane = .transcript
    @ObservedObject var capture: AudioCaptureController
    @ObservedObject var engine: AskEngine
    @ObservedObject var glossary: Glossary
    /// Bumped by the toolbar's Enhance button to trigger a rewrite.
    var enhanceTrigger: Int = 0
    /// Optional user-authored preferences layered onto Thread's protected
    /// Enhance instructions. Nil uses the built-in Default.
    var enhanceTemplateInstructions: String?
    @ObservedObject var enhanceTemplates: EnhanceTemplateStore
    /// Empty selects Thread's built-in Default; otherwise a template's UUID string.
    @Binding var selectedEnhanceTemplateID: String
    /// Display name for the selected template, resolved by the parent.
    var enhanceTemplateName: String
    /// False in the compact window, where the note fills the frame instead of
    /// sitting in a panel paired with the sidebar's.
    var insetPanel: Bool = true
    @Binding var isEnhancing: Bool
    /// When true (a just-promoted notes-only note), focus the notes editor on
    /// appear so the user can keep typing without clicking.
    var autofocusNotes: Bool = false
    /// Runs the enhance through the parent rather than calling `enhance()` here.
    var onEnhance: () -> Void = {}
    var onOpenTemplates: (Bool) -> Void = { _ in }
    /// True while this note's tasks are docked on the right, so the chip that opens
    /// them can read as pressed and offer to close them again.
    var tasksOpen: Bool = false
    var onToggleTasks: () -> Void = {}
    /// True when the ask bar should float over the panes; the parent decides, since
    /// the toolbar's chat glyph stands in wherever this bar has no room.
    var showsAsk: Bool = false
    /// Bumped by ⌘L to open and focus the ask bar.
    var askFocusRequest: Int = 0
    /// Called after a rename changes the file URL, so the parent can re-select it.
    var onRename: (URL) -> Void = { _ in }
    /// Reports glossary corrections detected during an enhance, for the panel.
    var onCandidates: ([GlossaryCandidate]) -> Void = { _ in }
    @State private var segments: [TranscriptSegment] = []
    @State private var lines: [ParsedLine] = []
    @State private var notes = ""
    @State private var loadedNotes = ""
    @State private var tasks: [TaskItem] = []
    @State private var saveTask: Task<Void, Never>?
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var hoveringTasks = false
    /// True while this note's chat thread is open, which soft-focuses the panes
    /// behind it the way the old floating Ask panel did.
    @State private var askThreadOpen = false
    @FocusState private var titleFocused: Bool
    /// True once an append recording targeting *this* file has begun, so a later
    /// Stop reloads the newly-written segments from disk.
    @State private var didAppendHere = false
    @State private var enhanceError: String?

    /// A recording is in progress and it's appending into this session.
    private var isAppendingHere: Bool {
        capture.isActive && capture.appendTarget == url
    }

    private var items: [TranscriptItem] {
        lines.map { TranscriptItem(id: $0.id.uuidString, speaker: $0.speaker, text: $0.text,
                                   isLive: false, speakerName: $0.speakerName) }
    }

    /// Committed live entries while appending into this session.
    private var liveCommitted: [TranscriptItem] {
        capture.entries.map {
            TranscriptItem(id: $0.id.uuidString, speaker: $0.speaker, text: $0.text,
                           isLive: false, speakerName: $0.speakerName)
        }
    }

    /// Still-changing draft (volatile) live lines while appending.
    private var liveVolatile: [TranscriptItem] {
        var result: [TranscriptItem] = []
        if !capture.youVolatile.isEmpty {
            result.append(TranscriptItem(id: "live-you", speaker: .you, text: capture.youVolatile,
                                         isLive: true, speakerName: capture.localUserName))
        }
        if !capture.meetingVolatile.isEmpty {
            result.append(TranscriptItem(id: "live-meeting", speaker: .meeting, text: capture.meetingVolatile,
                                         isLive: true, speakerName: capture.meetingVolatileSpeaker))
        }
        return result
    }

    var body: some View {
        Group {
            if pane == .notes {
                // The editor gets the whole pane: tasks live in the docked column
                // the header's chip opens, not in a strip below this.
                RichTextEditor(markdown: $notes, autofocus: autofocusNotes,
                               onEnhanceBlock: engine.isAvailable ? enhanceBlock : nil,
                               bottomInset: showsAsk ? NoteAskBar.clearance : 0)
                    .onChange(of: notes) { _, newValue in scheduleSave(newValue) }
            } else {
                transcript
            }
        }
        .mask { paneFade }
        // No room reserved for the ask field: shrinking the panes for it left a dead
        // band across the foot of the note and sliced the last line in half. The panes
        // run full height and the field floats over them, with the room it needs added
        // to each pane's scrollable content instead.
        .padding(.bottom, insetPanel ? DetailPanel.contentBottom : 0)
        // Pinned below the toolbar rather than inside it: as a toolbar item the
        // title shared a glass pill with its neighbour, and its width dragged the
        // centred Transcript/Notes switcher off centre.
        .safeAreaInset(edge: .top) { header }
        // The note itself, title included, softens behind an open chat thread. Twice
        // the old Ask panel's radius: that one sat on a card, this text sits directly
        // on the note and needs the page pushed further back to read cleanly.
        .blur(radius: showsAsk && askThreadOpen ? 14 : 0)
        .animation(.easeInOut(duration: 0.2), value: askThreadOpen)
        .overlay(alignment: .bottom) { askBar }
        .navigationTitle("")
        .detailPanelBackground(inset: insetPanel)
        .onAppear { load(url) }
        .onChange(of: url) { _, newURL in flushSave(); editingTitle = false; load(newURL) }
        .onChange(of: enhanceTrigger) { _, _ in enhance() }
        .onChange(of: capture.isActive) { _, active in
            if active {
                if capture.appendTarget == url { didAppendHere = true }
            } else if didAppendHere {
                // The appended segment just finished writing — reload from disk so
                // the transcript shows both segments with dividers.
                didAppendHere = false
                reloadTranscript()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .threadTasksDidChange)) { note in
            // The AI (or another view) changed this file's tasks — reload them.
            if (note.object as? URL) == url { tasks = store.loadTasks(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .threadApplyCorrection)) { note in
            guard let req = note.object as? CorrectionRequest, req.url == url else { return }
            applyCorrection(variant: req.variant, canonical: req.canonical)
        }
        .onReceive(NotificationCenter.default.publisher(for: .threadFlushNotes)) { note in
            if note.object == nil || (note.object as? URL) == url { flushSave() }
        }
        .onDisappear { flushSave() }
    }

    /// This note's chat. Clipped and inset to the panel so the dim it draws stops at
    /// the panel's rounded edge rather than bleeding into the gutters either side.
    @ViewBuilder private var askBar: some View {
        if showsAsk {
            NoteAskBar(url: url, engine: engine,
                       evidence: askEvidence,
                       focusRequest: askFocusRequest, threadOpen: $askThreadOpen)
                .clipShape(RoundedRectangle(cornerRadius: DetailPanel.radius,
                                            style: .continuous))
                .padding(insetPanel ? DetailPanel.insets : EdgeInsets())
        }
    }

    /// Scrolling content dissolves at the header instead of being sliced by it: the
    /// panes stop where the title block ends, and a hard edge there reads as a
    /// half-cut line of text rather than as more to scroll to.
    private var paneFade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: 20)
            Color.black
        }
    }

    /// Note title, date, and (on the notes side) the enhance bar, pinned just below
    /// the toolbar. Aligned to the 20pt margin the transcript and notes content
    /// already use. Double-click to rename.
    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            if editingTitle {
                TextField("Title", text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                    .focused($titleFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { editingTitle = false }
            } else {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: beginRename)
                    .help(url.deletingPathExtension().lastPathComponent)
            }
            Text(store.createdAt(of: url).formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            // Only on the notes side: on the transcript there is nothing to enhance.
            if pane == .notes {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        EnhanceBar(templates: enhanceTemplates,
                                   selectedID: $selectedEnhanceTemplateID,
                                   name: enhanceTemplateName,
                                   isEnhancing: isEnhancing,
                                   isAvailable: engine.isAvailable,
                                   unavailableReason: engine.unavailableReason,
                                   onEnhance: onEnhance,
                                   onOpenTemplates: onOpenTemplates)
                        tasksChip
                    }
                    if let enhanceError {
                        Text(enhanceError)
                            .font(.system(size: 11))
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    /// Opens or closes the tasks column. The count is what's still outstanding, so
    /// the chip alone answers "is there anything left on this note" without the list
    /// having to be on screen.
    private var tasksChip: some View {
        Button(action: onToggleTasks) {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(tasksChipLabel)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(Color.primary.opacity(
                    tasksOpen ? 0.14 : (hoveringTasks ? 0.11 : 0.07)))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hoveringTasks = $0 }
        .accessibilityLabel(tasksOpen ? "Hide tasks" : "Show tasks")
        .help(tasksOpen ? "Hide tasks" : "Show tasks")
    }

    private var tasksChipLabel: String {
        let open = tasks.filter { !$0.done }.count
        if tasks.isEmpty { return "Tasks" }
        if open == 0 { return "All done" }
        return open == 1 ? "1 task" : "\(open) tasks"
    }

    private func beginRename() {
        titleDraft = url.deletingPathExtension().lastPathComponent
        editingTitle = true
        DispatchQueue.main.async { titleFocused = true }
    }

    private func commitRename() {
        editingTitle = false
        // Persist pending editor changes before moving the backing file; otherwise
        // onDisappear could recreate the old path with the unsaved draft.
        flushSave()
        if let newURL = store.rename(url, to: titleDraft) {
            glossary.noteMoved(from: url, to: newURL)
            engine.noteConversationMoved(from: url, to: newURL)
            onRename(newURL)
        }
    }

    /// Rewrites the notes into clean, structured meeting notes using the current
    /// notes as anchors plus the transcript. Updates the editor in place and
    /// persists the result.
    private func enhance() {
        guard !isEnhancing, engine.isAvailable else { return }
        isEnhancing = true
        enhanceError = nil
        // Clean the stored transcript with already-learned terms and refresh the
        // displayed segments, so both the transcript pane and the summary read right.
        if store.applyTextTransform({ glossary.correct($0) }, to: url) {
            reloadTranscript()
        }
        let anchors = Self.anchors(notes: notes, tasks: tasks)
        let existing = tasks
        // Glossary: apply *confirmed* terms so the summary reads correctly, and
        // separately detect new corrections (from the user's notes) to suggest.
        // New detections aren't auto-applied — a phonetic match can be wrong, so
        // the user confirms them in the panel; once saved they apply next time.
        // Detection scans the full transcript (all segments) so nothing is missed.
        let fullRaw = lines
            .map { "\($0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
        let candidates = glossary.detectCandidates(notes: anchors,
                                                   transcript: glossary.correct(fullRaw),
                                                   noteURL: url)
        let target = url
        saveTask?.cancel()
        Task { @MainActor in
            defer { isEnhancing = false }
            // For multi-segment sessions, cache a mini-summary of each older
            // segment once, so enhance reuses those instead of re-reading the
            // whole history every time. Only the latest recording is read raw.
            var segs = segments
            let latest = segs.count - 1
            if latest > 0 {
                var newlyCached: [Int: String] = [:]
                for i in 0..<latest where (segs[i].summary?.isEmpty ?? true) {
                    if Task.isCancelled { break }
                    let segText = segs[i].lines
                        .map { "\($0.speakerName ?? $0.speaker.rawValue): \($0.text)" }
                        .joined(separator: "\n")
                    if let s = await engine.summarizeSegment(segText) { newlyCached[i] = s }
                }
                if !newlyCached.isEmpty {
                    store.cacheSegmentSummaries(to: target, newlyCached)
                    guard target == url else { return }
                    reloadTranscript()
                    segs = segments
                }
            }
            // Cached summaries for older segments + raw latest. `engine.enhance`
            // condenses internally if the latest recording is very long.
            let transcript = glossary.correct(Self.enhanceEvidence(segs))
            // Stream the model output straight into the editor so the notes fill
            // in live. `scheduleSave` is suppressed while enhancing, so these
            // partial writes never touch disk.
            let enhanced = await engine.enhance(
                notes: anchors,
                transcript: transcript,
                customInstructions: enhanceTemplateInstructions
            ) { partial in
                guard target == url else { return }
                notes = partial
            }
            guard let enhanced, target == url else {
                // Nothing came back — restore what the editor had before streaming.
                notes = loadedNotes
                if LLMRouting.usesCloud {
                    enhanceError = CloudLLM.setupHint
                }
                return
            }
            enhanceError = nil
            let split = SessionStore.splitActionItems(from: enhanced.notesMarkdown)
            let extracted = enhanced.actionItems ?? []
            let merged = SessionStore.mergeTasks(
                new: split.tasks + extracted,
                existing: existing
            )
            notes = split.notes
            tasks = merged
            store.saveNotesAndTasks(target, notes: split.notes, tasks: merged)
            loadedNotes = split.notes
            // Surface any detected corrections for the user to save to the glossary.
            onCandidates(candidates)
        }
    }

    /// What the ask field answers from. The same evidence inline enhance reads —
    /// this note's segments plus the in-progress recording when one is feeding it —
    /// with two differences: the notes the user has typed are included, since a
    /// question can be about those, and the sentence still being spoken comes along
    /// too. Enhance leaves that out because it writes the words into the document;
    /// asking only reads them, and "what did they just say" is usually about exactly
    /// that sentence.
    private func askEvidence() -> AskEngine.NoteEvidence {
        var parts = [Self.enhanceEvidence(segments)]
        var pending = ""
        if isAppendingHere {
            let live = capture.entries
                .map { entry -> String in
                    if let name = entry.speakerName,
                       !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return "\(name): \(entry.text)"
                    }
                    return "\(entry.speaker.rawValue): \(entry.text)"
                }
                .joined(separator: "\n")
            if !live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("Latest recording (in progress):\n" + live)
            }
            pending = Self.spokenNow(capture)
        }
        let transcript = glossary.correct(
            parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
        )
        return AskEngine.NoteEvidence(
            title: url.deletingPathExtension().lastPathComponent,
            notes: Self.anchors(notes: notes, tasks: tasks),
            transcript: transcript,
            pending: pending,
            isRecording: isAppendingHere
        )
    }

    /// The volatile lines: whatever the recognizer currently thinks is being said.
    static func spokenNow(_ capture: AudioCaptureController) -> String {
        var lines: [String] = []
        if !capture.youVolatile.isEmpty {
            lines.append("\(capture.localUserName ?? "You"): \(capture.youVolatile)")
        }
        if !capture.meetingVolatile.isEmpty {
            lines.append("\(capture.meetingVolatileSpeaker ?? "Meeting"): \(capture.meetingVolatile)")
        }
        return lines.joined(separator: "\n")
    }

    /// Inline collaborator hook for the notes editor: enhances a single hovered
    /// block in place, grounded in this session's transcript (glossary-corrected,
    /// with cached summaries for older segments). Streams partials back into the
    /// editor and returns the finished block Markdown, or nil to leave it as-is.
    private func enhanceBlock(_ block: String,
                              onPartial: @escaping (String) -> Void) async -> String? {
        var parts = [Self.enhanceEvidence(segments)]
        // While a recording is appending into this note, fold in the in-progress
        // transcript (committed lines only — skip the still-changing volatile
        // partials) so a mid-meeting enhance is grounded on what was just said.
        if isAppendingHere {
            let live = capture.entries
                .map { "\($0.speaker.rawValue): \($0.text)" }
                .joined(separator: "\n")
            if !live.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("Latest recording (in progress):\n" + live)
            }
        }
        let evidence = glossary.correct(
            parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
        )
        let result = await engine.enhanceBlock(block, transcript: evidence) { partial in
            onPartial(partial)
        }
        if result == nil, LLMRouting.usesCloud {
            enhanceError = CloudLLM.setupHint
        }
        return result
    }

    /// Applies an accepted glossary correction to this note in place — notes,
    /// tasks, AND the stored transcript (whole-word, case-insensitive) — then
    /// reloads so every pane reflects the fix immediately.
    private func applyCorrection(variant: String, canonical: String) {
        flushSave()
        if store.applyCorrection(to: url, variant: variant, canonical: canonical) {
            load(url)
        }
    }

    /// Grounds a re-enhance on the existing summary plus the current task list
    /// (with completion state) so it builds on them rather than the raw
    /// transcript alone.
    static func anchors(notes: String, tasks: [TaskItem]) -> String {
        guard !tasks.isEmpty else { return notes }
        let list = SessionStore.tasksMarkdown(tasks)
        let base = notes.isEmpty ? "" : notes + "\n\n"
        return base + "Current tasks:\n" + list
    }

    /// Builds the transcript the enhancer reads: cached mini-summaries for older
    /// recordings plus the latest recording in full. Falls back to raw text for
    /// any older segment that has no cached summary yet.
    static func enhanceEvidence(_ segs: [TranscriptSegment]) -> String {
        guard !segs.isEmpty else { return "" }
        let latest = segs.count - 1
        var parts: [String] = []
        for i in 0..<latest {
            if let s = segs[i].summary, !s.isEmpty {
                parts.append("Earlier recording \(i + 1) summary:\n\(s)")
            } else {
                let raw = segs[i].lines
                    .map { "\($0.speakerName ?? $0.speaker.rawValue): \($0.text)" }
                    .joined(separator: "\n")
                if !raw.isEmpty { parts.append("Earlier recording \(i + 1):\n\(raw)") }
            }
        }
        let latestRaw = segs[latest].lines
            .map { "\($0.speakerName ?? $0.speaker.rawValue): \($0.text)" }
            .joined(separator: "\n")
        if !latestRaw.isEmpty {
            parts.append(latest == 0 ? latestRaw : "Latest recording:\n\(latestRaw)")
        }
        return parts.joined(separator: "\n\n")
    }

    /// Dividers appear only once there are 2+ segments (a lone recording reads
    /// as one clean block). While appending, the in-progress live run counts as
    /// an extra segment, so a divider appears above the existing content too.
    private var showDividers: Bool {
        (segments.count + (isAppendingHere ? 1 : 0)) >= 2
    }

    private var transcript: some View {
        Group {
            if segments.isEmpty && !isAppendingHere {
                Color.clear
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(segments) { seg in
                                if showDividers {
                                    SegmentDivider(start: seg.start ?? store.createdAt(of: url),
                                                   end: seg.end, live: false)
                                }
                                GroupedTranscript(items: seg.lines.map {
                                    TranscriptItem(id: $0.id.uuidString, speaker: $0.speaker,
                                                   text: $0.text, isLive: false,
                                                   speakerName: $0.speakerName)
                                }).equatable()
                            }
                            if isAppendingHere {
                                if showDividers {
                                    SegmentDivider(start: capture.startedAt ?? Date(),
                                                   end: nil, live: true)
                                }
                                GroupedTranscript(items: liveCommitted).equatable()
                                if !liveVolatile.isEmpty {
                                    GroupedTranscript(items: liveVolatile)
                                }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(20)
                    }
                    .scrollContentBackground(.hidden)
                    // Lets the last bubble be scrolled clear of the floating ask
                    // field while the transcript still runs to the pane's edge.
                    .contentMargins(.bottom, showsAsk ? NoteAskBar.clearance : 0,
                                    for: .scrollContent)
                    .onChange(of: capture.entries.count) { _, _ in
                        if isAppendingHere {
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        }
                    }
                    .onChange(of: capture.youVolatile) { _, _ in
                        if isAppendingHere { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: capture.meetingVolatile) { _, _ in
                        if isAppendingHere { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
    }

    private func load(_ url: URL) {
        segments = store.loadSegments(url)
        lines = segments.flatMap { $0.lines }
        notes = store.loadNotes(url)
        loadedNotes = notes
        tasks = store.loadTasks(url)
    }

    /// Reloads only the transcript segments (used after an append finishes) so the
    /// notes editor / tasks aren't disturbed.
    private func reloadTranscript() {
        segments = store.loadSegments(url)
        lines = segments.flatMap { $0.lines }
    }

    /// Debounced write so we don't hit disk on every keystroke.
    private func scheduleSave(_ value: String) {
        // Don't persist the partial text streamed in while enhancing — the final
        // split result is saved explicitly when enhance completes.
        guard !isEnhancing else { return }
        guard value != loadedNotes else { return }
        saveTask?.cancel()
        let target = url
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            store.saveNotes(target, notes: value)
            loadedNotes = value
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        guard notes != loadedNotes else { return }
        store.saveNotes(url, notes: notes)
        loadedNotes = notes
    }
}

// MARK: - Shared components

private struct TranscriptItem: Identifiable {
    let id: String
    let speaker: Speaker
    let text: String
    let isLive: Bool
    var speakerName: String? = nil
}

/// A subtle centered separator between transcript segments, showing the
/// recording's time range (`start – end`), start-only for a legacy/unknown end,
/// or `start – recording` while a segment is being captured.
private struct SegmentDivider: View {
    let start: Date
    let end: Date?
    var live: Bool = false

    private var label: String {
        let day = start.formatted(.dateTime.month(.abbreviated).day().year())
        let startT = start.formatted(date: .omitted, time: .shortened)
        if live { return "\(day) · \(startT) – recording" }
        if let end { return "\(day) · \(startT) – \(end.formatted(date: .omitted, time: .shortened))" }
        return "\(day) · \(startT)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(.secondary.opacity(0.25)).frame(height: 1)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(.secondary.opacity(0.25)).frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}

/// Renders transcript items with consecutive same-speaker messages grouped
/// under a single speaker label.
private struct GroupedTranscript: View, Equatable {
    let items: [TranscriptItem]

    // Equal when the same lines with the same text are present, so SwiftUI can
    // skip rebuilding the committed transcript on unrelated (draft) updates.
    static func == (lhs: GroupedTranscript, rhs: GroupedTranscript) -> Bool {
        guard lhs.items.count == rhs.items.count else { return false }
        for (a, b) in zip(lhs.items, rhs.items)
        where a.id != b.id || a.text != b.text || a.isLive != b.isLive || a.speakerName != b.speakerName {
            return false
        }
        return true
    }

    private struct Group: Identifiable {
        let id: String
        let speaker: Speaker
        let speakerName: String?
        var lines: [TranscriptItem]
    }

    private var groups: [Group] {
        var result: [Group] = []
        for item in items {
            // Break the group when the speaker OR the resolved name changes, so
            // two people talking in turn read as two attributed bubbles.
            if let last = result.last, last.speaker == item.speaker,
               last.speakerName == item.speakerName {
                result[result.count - 1].lines.append(item)
            } else {
                result.append(Group(id: item.id, speaker: item.speaker,
                                    speakerName: item.speakerName, lines: [item]))
            }
        }
        return result
    }

    var body: some View {
        LazyVStack(spacing: 14) {
            ForEach(groups) { group in
                groupView(group).id(group.id)
            }
        }
    }

    @ViewBuilder private func groupView(_ group: Group) -> some View {
        let isYou = group.speaker == .you
        HStack {
            if isYou { Spacer(minLength: 64) }
            VStack(alignment: isYou ? .trailing : .leading, spacing: 3) {
                // Inline speaker name for identified turns (yours on the right,
                // meeting participants on the left).
                if let name = group.speakerName, !name.isEmpty {
                    Text(name)
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(isYou ? .trailing : .leading, 14)
                        .padding(.bottom, 1)
                }
                ForEach(group.lines) { line in
                    BubbleLine(text: line.text, isYou: isYou, isLive: line.isLive)
                        .id(line.id)
                }
            }
            if !isYou { Spacer(minLength: 64) }
        }
    }
}

private struct BubbleLine: View {
    let text: String
    let isYou: Bool
    let isLive: Bool

    var body: some View {
        let line = Text(text)
            .font(.body)
            .foregroundStyle(isLive ? .secondary : .primary)
            .multilineTextAlignment(isYou ? .trailing : .leading)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        // Under Clear glass the note's panel already supplies the reading surface, so
        // an edge is enough — a filled bubble there is just a darker slab on a dark
        // panel. Tinted has no such panel scrim, so it keeps the glass fill.
        if AppAppearance.liquidGlass {
            line.overlay {
                shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            }
        } else {
            line.glassEffect(.regular, in: shape)
        }
    }

    // Each speaker's bubble is sharp on its own bottom corner (You: bottom-right,
    // Meeting: bottom-left) so it "points" toward its side; the rest is rounded.
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 16,
            bottomLeadingRadius: isYou ? 16 : 0,
            bottomTrailingRadius: isYou ? 0 : 16,
            topTrailingRadius: 16
        )
    }
}

private struct Caption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
    }
}

private struct EmptyState: View {
    var body: some View {
        Color.clear
    }
}

#Preview {
    ContentView()
        .environmentObject(SessionStore())
        .environmentObject(AudioCaptureController())
        .environmentObject(AskEngine())
}
