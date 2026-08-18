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
import Sparkle

@main
struct ThreadApp: App {
    // Owns the Sparkle updater for the app's lifetime and starts it on launch.
    #if DEBUG
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    #else
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    // Owned at process lifetime, not by the window, so recording (and the note
    // it writes) survives closing the main window and keeps running headless
    // behind the notch. Reopening the window rebinds to these same instances
    // rather than spinning up a fresh, idle recorder.
    @StateObject private var store = SessionStore()
    @StateObject private var capture = AudioCaptureController()
    @StateObject private var engine = AskEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(capture)
                .environmentObject(engine)
                #if !DEBUG
                // Check on every launch (Sparkle's built-in schedule otherwise
                // only checks ~once a day). Silent: it downloads/installs in the
                // background and applies on the next relaunch.
                .task { updaterController.updater.checkForUpdatesInBackground() }
                #endif
        }
        .defaultSize(width: 820, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                #if !DEBUG
                CheckForUpdatesView(updater: updaterController.updater)
                #endif
            }
            #if DEBUG
            CommandMenu("Debug") {
                Button("Probe Meet Accessibility") {
                    MeetAccessibilityProbe.shared.probeOnce(provider: .googleMeet)
                }
                .keyboardShortcut("p", modifiers: [.command, .control, .option])
                Button("Watch Meet Speaking (30s)") {
                    MeetAccessibilityProbe.shared.watch(seconds: 30, provider: .googleMeet)
                }
                .keyboardShortcut("w", modifiers: [.command, .control, .option])
                Button("Locate Meet Speaker (30s)") {
                    MeetAccessibilityProbe.shared.locateSpeaking(seconds: 30, provider: .googleMeet)
                }
                .keyboardShortcut("l", modifiers: [.command, .control, .option])
                Button("Scan Speaker (Speaker Vision)") {
                    SpeakerVisionMonitor.shared.analyzeOnce()
                }
                .keyboardShortcut("s", modifiers: [.command, .control, .option])
                Button("Dump Zoom Desktop Candidate") {
                    SpeakerVisionMonitor.shared.debugDumpZoomDesktop()
                }
                Divider()
                Button("Probe Teams Accessibility") {
                    MeetAccessibilityProbe.shared.probeOnce(provider: .microsoftTeams)
                }
                .keyboardShortcut("p", modifiers: [.command, .control, .option, .shift])
                Button("Watch Teams Speaking (30s)") {
                    MeetAccessibilityProbe.shared.watch(seconds: 30, provider: .microsoftTeams)
                }
                .keyboardShortcut("w", modifiers: [.command, .control, .option, .shift])
                Button("Locate Teams Speaker (30s)") {
                    MeetAccessibilityProbe.shared.locateSpeaking(seconds: 30, provider: .microsoftTeams)
                }
                .keyboardShortcut("l", modifiers: [.command, .control, .option, .shift])
                Divider()
                Button("Probe Zoom Accessibility") {
                    MeetAccessibilityProbe.shared.probeOnce(provider: .zoom)
                }
                Button("Watch Zoom Speaking (30s)") {
                    MeetAccessibilityProbe.shared.watch(seconds: 30, provider: .zoom)
                }
                Button("Locate Zoom Speaker (30s)") {
                    MeetAccessibilityProbe.shared.locateSpeaking(seconds: 30, provider: .zoom)
                }
                Button("Dump All Web Areas") {
                    MeetAccessibilityProbe.shared.dumpAllWebAreas()
                }
                Divider()
                Button("Dump Zoom Desktop Tree") {
                    MeetAccessibilityProbe.shared.dumpNativeApp(bundleID: "us.zoom.xos")
                }
                Button("Watch Zoom Desktop Text (30s)") {
                    MeetAccessibilityProbe.shared.watchNativeText(seconds: 30,
                                                                  bundleID: "us.zoom.xos")
                }
                Button("Zoom: Enhanced Accessibility On") {
                    MeetAccessibilityProbe.shared.setEnhancedAccessibility(true,
                                                                          bundleID: "us.zoom.xos")
                }
                Button("Zoom: Enhanced Accessibility Off") {
                    MeetAccessibilityProbe.shared.setEnhancedAccessibility(false,
                                                                          bundleID: "us.zoom.xos")
                }
                Button("Dump Zoom Tile Attributes") {
                    MeetAccessibilityProbe.shared.dumpNativeTileAttributes(bundleID: "us.zoom.xos")
                }
                Button("Watch Zoom Desktop Tiles (30s)") {
                    MeetAccessibilityProbe.shared.watchNativeTiles(seconds: 30,
                                                                   bundleID: "us.zoom.xos")
                }
            }
            #endif
            CommandMenu("Format") {
                Button("Bold") { Self.format(#selector(NotesTextView.threadToggleBold(_:))) }
                    .keyboardShortcut("b")
                Button("Italic") { Self.format(#selector(NotesTextView.threadToggleItalic(_:))) }
                    .keyboardShortcut("i")
                Button("Strikethrough") { Self.format(#selector(NotesTextView.threadToggleStrike(_:))) }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Divider()
                Button("Heading 1") { Self.format(#selector(NotesTextView.threadHeading1(_:))) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("Heading 2") { Self.format(#selector(NotesTextView.threadHeading2(_:))) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Body") { Self.format(#selector(NotesTextView.threadBody(_:))) }
                    .keyboardShortcut("0", modifiers: [.command, .option])
                Divider()
                Button("Add Link") { Self.format(#selector(NotesTextView.threadInsertLink(_:))) }
                    .keyboardShortcut("k")
            }
        }
    }

    /// Sends a formatting action to the first responder (the focused notes
    /// editor). A no-op when no notes editor is focused.
    private static func format(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }
}

/// Tracks whether the updater is currently able to check, so the menu item
/// disables itself while an update check is already in flight.
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

/// The "Check for Updates" menu item wired to Sparkle.
struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates") { updater.checkForUpdates() }
            .disabled(!viewModel.canCheckForUpdates)
    }
}
