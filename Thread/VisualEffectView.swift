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

enum AppEnvironment {
    #if DEBUG
    static let isDevelopment = true
    static let applicationSupportDirectoryName = "Thread Dev"
    #else
    static let isDevelopment = false
    static let applicationSupportDirectoryName = "Thread"
    #endif
}

enum AppSettings {
    static let yourNamesKey = "yourNames"
    static let selectedEnhanceTemplateKey = "selectedEnhanceTemplate"
    static let sessionNamingTemplateKey = "sessionNamingTemplate"
    static let defaultSessionNamingTemplate = "Session {date} {time}"
    // Whether the Liquid Glass notch overlay hugging the MacBook notch is shown.
    static let notchEnabledKey = "notch.enabled"
    // Experimental: label transcript turns with on-screen speaker names read from
    // the meeting window. Off by default; needs Accessibility permission.
    static let speakerNamesKey = "speakerNames.enabled"
    // Preserve the existing storage key so users already prompted for Google
    // Meet are not prompted again when Zoom Web support is added.
    static let browserMuteAccessibilityPromptedKey =
        "googleMeetMute.accessibilityPrompted"
    // One-way copy into Apple Notes for viewing. Off until they turn it on
    // and create a Thread folder.
    static let notesSyncEnabledKey = "notesSync.enabled"
    static let notesSyncAccountKey = "notesSync.account"
    static let notesSyncFolderReadyKey = "notesSync.folderReady"
}

/// Whether Thread follows the system light/dark setting or pins itself to one.
enum AppColorScheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `nil` hands the choice back to macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// App-wide appearance preferences. Backed by `UserDefaults` so any glass
/// surface can read the current style; the Setup toggle writes the same key,
/// and `ContentView` observes it via `@AppStorage` to re-render on change.
enum AppAppearance {
    static let liquidGlassKey = "liquidGlass"
    static let colorSchemeKey = "colorScheme"

    /// True → clear glass with more of the desktop visible.
    /// False → tinted glass with a stronger readability scrim.
    static var liquidGlass: Bool {
        UserDefaults.standard.bool(forKey: liquidGlassKey)
    }

    static var colorScheme: AppColorScheme {
        AppColorScheme(rawValue: UserDefaults.standard.string(forKey: colorSchemeKey) ?? "")
            ?? .system
    }

    /// Applied to `NSApplication` rather than through `preferredColorScheme` so
    /// the AppKit surfaces follow too — the notes text view, the toolbar, the
    /// visual-effect backdrops, and Sparkle's update windows.
    @MainActor
    static func applyColorScheme() {
        NSApplication.shared.appearance = colorScheme.nsAppearance
    }

    /// The glass variant to use across the app.
    static func glass(interactive: Bool = false) -> Glass {
        let base: Glass = liquidGlass ? .clear : .regular
        return interactive ? base.interactive() : base
    }
}

/// Geometry of the detail-side panel, measured off AppKit's own sidebar panel so
/// the two read as a matched pair. The sidebar insets itself and exposes no API to
/// ask, hence the constants: an 8.5pt window margin and a 15pt radius, both of
/// which the sidebar's edges fit to within half a point.
enum DetailPanel {
    static let radius: CGFloat = 15
    /// Measured from the detail column's leading edge, which already starts where
    /// the sidebar's panel ends — so one margin here puts a gutter between the two
    /// panels equal to the window's outer margin.
    static let leading: CGFloat = 8.5
    static let trailing: CGFloat = 8.5
    static let top: CGFloat = 8
    static let bottom: CGFloat = 8
    /// Width of the docked trailing column, matching the sidebar's so the note in
    /// the middle takes whatever is left between two columns of equal weight.
    static let columnWidth: CGFloat = 248
    /// Clearance between a pane's scrolling content and the panel's rounded bottom
    /// edge. Without it the last line rides over the corner and out of the surface,
    /// since the panel is a background and doesn't clip what sits on it.
    static let contentBottom: CGFloat = bottom + 8

    static var insets: EdgeInsets {
        EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing)
    }


    /// Drawn *over* the full-bleed page backdrop rather than replacing it, which is
    /// how AppKit treats the sidebar: without a backdrop underneath, the panel's
    /// margins expose unblurred desktop and read as a rendering seam. The extra
    /// scrim is what makes the panel visible, and what makes body text hold up
    /// against a busy desktop in Clear mode.
    @ViewBuilder
    static var surface: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if AppAppearance.liquidGlass {
            shape
                // Tuned by measuring mean luminance either side of the gutter until
                // the panel matched the sidebar's, which AppKit draws considerably
                // more opaque than the Clear page backdrop.
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
                .glassEffect(.clear, in: .rect(cornerRadius: radius))
        } else {
            shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.22))
        }
    }
}

extension View {
    /// Full-bleed page background governed by the appearance setting. Both
    /// choices remain glass: Clear reveals more of the desktop, while Tinted
    /// adds a stronger adaptive scrim for contrast.
    @ViewBuilder
    func pageGlassBackground() -> some View {
        if AppAppearance.liquidGlass {
            background {
                VisualEffectView(material: .underWindowBackground)
                    // Keep enough blur for legibility without turning the clear
                    // mode into an opaque frosted sheet.
                    .opacity(0.7)
                    // NSVisualEffectView supplies the desktop blur; the clear
                    // glass layer adds Liquid Glass highlights and refraction.
                    .glassEffect(.clear, in: .rect(cornerRadius: 18))
                    .ignoresSafeArea()
            }
        } else {
            background {
                VisualEffectView(material: .sidebar)
                    .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.68))
                    .ignoresSafeArea()
            }
        }
    }

    /// The detail-side counterpart: the page backdrop with a rounded panel inset on
    /// top of it, lined up with the sidebar's. Applied in both appearance modes on
    /// purpose — everywhere else the Liquid Glass toggle changes material, never
    /// layout, so the window shouldn't change shape when it's flipped.
    ///
    /// Pass `inset: false` for the compact window, where there is no sidebar panel
    /// to pair with and a floating card would just strand the content.
    @ViewBuilder
    func detailPanelBackground(inset: Bool = true) -> some View {
        if !inset {
            pageGlassBackground()
        } else {
            background {
                DetailPanel.surface
                    .padding(DetailPanel.insets)
                    // Top and bottom only. The top has to reach under the transparent
                    // toolbar, while the leading safe area is the sidebar and the
                    // trailing one is whatever panel is docked there — ignoring
                    // either would slide this panel underneath it, out of sight.
                    .ignoresSafeArea(edges: [.top, .bottom])
            }
            .pageGlassBackground()
        }
    }

    /// Confines scrolling content to the detail panel. The panel is a background, not
    /// a container, so a list left unclipped scrolls over its rounded corners and out
    /// through its margins. A mask rather than padding, so the panel's own background
    /// still lines up with the content instead of being inset twice.
    ///
    /// `topOverhang` lifts the mask that far above the view's own top edge, up over
    /// the title band to the panel's edge. Content then fills the panel and scrolls
    /// behind the toolbar, as it does in any document window — whatever sits up there
    /// needs its own backdrop, or a frost across the band, to stay readable. Left at
    /// zero the mask stops at the safe area and the band stays empty panel.
    @ViewBuilder
    func clippedToDetailPanel(_ active: Bool = true,
                              topOverhang: CGFloat = 0) -> some View {
        if active {
            mask {
                RoundedRectangle(cornerRadius: DetailPanel.radius, style: .continuous)
                    .padding(DetailPanel.insets)
                    // Outside the insets, so this is the panel margin less the band:
                    // the shape's top corners land on the panel's, not the window's.
                    .padding(.top, -topOverhang)
            }
        } else {
            self
        }
    }
}

/// Bridges `NSVisualEffectView` so the window blurs whatever is behind it
/// (the desktop / other apps) for a true Liquid Glass look.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
    }
}

/// Makes the hosting window fully transparent (no opaque backing, no titlebar
/// fill) so the blur reads as edge-to-edge Liquid Glass.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { configure(window) }
    }

    private func configure(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 220, height: 420)
        // Don't let macOS restore a stale frame; WindowSizer owns the width.
        window.isRestorable = false
        disableSplitViewAutosave(in: window)
        // Keep the traffic lights even when the toolbar is hidden (compact idle).
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        // Lock the toolbar to icon-only and drop the right-click customization
        // menu (the "Icon and Text / Icon Only" toggle). Text labels don't fit
        // our narrow, icon-first layout and pushed items into the overflow menu.
        if let toolbar = window.toolbar {
            toolbar.allowsUserCustomization = false
            toolbar.displayMode = .iconOnly
        }
    }

    /// AppKit autosaves the split divider into user defaults, and that saved width
    /// outranks the column width set in code — a plain `navigationSplitViewColumnWidth`
    /// is simply ignored once a value exists. This window switches between a 300pt
    /// compact rail and a 1000pt expanded layout but gets one shared divider, so the
    /// remembered width is always wrong for whichever mode didn't write it. Dropping
    /// the autosave leaves the widths deterministic; dragging still works for the
    /// session, it just isn't persisted across launches.
    private func disableSplitViewAutosave(in window: NSWindow) {
        guard !SplitViewAutosave.isDisabled,
              let split = window.contentView?.firstDescendant(ofType: NSSplitView.self)
        else { return }
        split.autosaveName = nil
        SplitViewAutosave.isDisabled = true
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("NSSplitView Subview Frames") {
            defaults.removeObject(forKey: key)
        }
    }
}

private enum SplitViewAutosave {
    static var isDisabled = false
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let match = self as? T { return match }
        for subview in subviews {
            if let match = subview.firstDescendant(ofType: type) { return match }
        }
        return nil
    }
}

/// Animates the hosting window as the app moves between compact and expanded
/// layouts, anchored at its top-left corner. Width always tracks the layout;
/// height only when the caller asks for one, so the height the user dragged
/// survives wherever the layout doesn't depend on it.
/// Clears the bezel AppKit draws behind the system's sidebar-toggle toolbar item.
/// Under Clear glass the rest of that run is bare, so once the sidebar collapses and
/// the run slides over the note, the toggle reads as a dark circle beside two loose
/// glyphs.
///
/// Reached through AppKit because the item belongs to the system: SwiftUI's
/// `sharedBackgroundVisibility` only governs items we declare, and substituting our own
/// toggle costs the run its layout — AppKit evicts it into the window's overflow menu
/// and squeezes the sidebar column to ~160pt.
struct SidebarToggleBezel: NSViewRepresentable {
    /// False leaves the bezel alone; Tinted glass keeps its pills.
    var hidden: Bool
    /// Here so collapsing re-runs the update: AppKit remakes the item around then.
    var visibility: NavigationSplitViewVisibility

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let toolbar = nsView?.window?.toolbar else { return }
            for item in toolbar.items
            where item.itemIdentifier.rawValue.localizedCaseInsensitiveContains("sidebar") {
                item.isBordered = !hidden
                let button = item.view as? NSButton
                    ?? item.view?.firstDescendant(ofType: NSButton.self)
                guard let button else { continue }
                button.isBordered = !hidden
                button.wantsLayer = true
                if hidden { button.layer?.backgroundColor = nil }
            }
        }
    }
}

struct WindowSizer: NSViewRepresentable {
    var targetWidth: CGFloat
    /// `nil` leaves the height as the user left it.
    var targetHeight: CGFloat?

    /// The window and the views inside it have to move on one clock. They used to run
    /// at 0.28 and 0.2 respectively, so the layout settled while the window was still
    /// growing and the compact→expanded switch read as two separate lurches.
    static let duration: Double = 0.26
    static var contentAnimation: Animation { .easeInOut(duration: duration) }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            var frame = window.frame
            frame.size.width = targetWidth // origin.x unchanged -> left edge fixed
            if let targetHeight {
                // Cocoa frames grow upward from the origin, so the origin has to
                // move by the delta or the title bar slides instead of staying put.
                frame.origin.y -= targetHeight - frame.size.height
                frame.size.height = targetHeight
            }
            guard abs(frame.width - window.frame.width) > 1
                    || abs(frame.height - window.frame.height) > 1 else { return }
            // Animate via Core Animation (window.animator) rather than
            // setFrame(animate: true): the latter runs a synchronous run-loop
            // that stalls input, this stays smooth and non-blocking.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                window.animator().setFrame(frame, display: true)
            }
        }
    }
}
