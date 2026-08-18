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

/// Which pane the detail area shows.
enum SessionPane: Hashable { case transcript, notes }

extension NSAttributedString.Key {
    /// Paragraph-level heading level (1...3); absent for body text.
    static let threadHeading = NSAttributedString.Key("threadHeading")
    /// Marks the block currently being streamed into by the inline collaborator,
    /// so the region can be re-located as text shifts and locked from editing.
    static let threadPendingEnhance = NSAttributedString.Key("threadPendingEnhance")
}

enum ListKind: String { case bullet, number }

// MARK: - Markdown <-> attributed string

/// Converts between the Markdown we persist and the attributed string the
/// editor shows. Inline styles (bold/italic/strikethrough/links) are parsed by
/// Foundation's Markdown support; block-level headings are handled here.
enum MarkdownNotes {
    static let bodySize: CGFloat = 14

    static func bodyFont() -> NSFont { .systemFont(ofSize: bodySize) }

    static func headingFont(_ level: Int) -> NSFont {
        let size: CGFloat = level <= 1 ? 22 : (level == 2 ? 18 : 15)
        return .systemFont(ofSize: size, weight: .bold)
    }

    private static func baseAttributes(_ font: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor]
    }

    /// Hanging-indent paragraph style so wrapped list lines align under the text,
    /// not under the marker. The marker is followed by a tab to this stop.
    static func listParagraphStyle(marker: String = "•\t") -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        // Size the indent to the actual marker width so the tab stop and the
        // hanging indent land on exactly the same x — wrapped lines then line up
        // under the text, with a small, consistent gap after the marker.
        let glyph = marker.replacingOccurrences(of: "\t", with: "")
        let markerWidth = (glyph as NSString).size(withAttributes: [.font: bodyFont()]).width
        let indent = ceil(markerWidth) + 6
        style.headIndent = indent
        style.firstLineHeadIndent = 0
        style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        style.defaultTabInterval = indent
        style.paragraphSpacing = 2
        return style
    }

    static func marker(for kind: ListKind, number: Int) -> String {
        kind == .bullet ? "•\t" : "\(number).\t"
    }

    // MARK: Markdown -> attributed

    static func attributed(from markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let paragraph: NSMutableAttributedString
            if let (kind, number, content) = listSplit(line) {
                let markerText = marker(for: kind, number: number)
                paragraph = NSMutableAttributedString(string: markerText,
                                                      attributes: baseAttributes(bodyFont()))
                paragraph.append(inlineAttributed(content, font: bodyFont()))
                let full = NSRange(location: 0, length: paragraph.length)
                paragraph.addAttribute(.paragraphStyle, value: listParagraphStyle(marker: markerText), range: full)
            } else {
                let (level, content) = headingSplit(line)
                let font = level > 0 ? headingFont(level) : bodyFont()
                paragraph = inlineAttributed(content, font: font)
                if level > 0 {
                    paragraph.addAttribute(.threadHeading, value: level,
                                           range: NSRange(location: 0, length: paragraph.length))
                }
            }
            result.append(paragraph)
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: baseAttributes(bodyFont())))
            }
        }
        if result.length == 0 {
            return NSAttributedString(string: "", attributes: baseAttributes(bodyFont()))
        }
        return result
    }

    /// Parses inline Markdown (`**bold**`, `*italic*`, `~~strike~~`, `[t](url)`)
    /// via Foundation, then maps the presentation intents onto real fonts so the
    /// text view renders them.
    private static func inlineAttributed(_ text: String, font: NSFont) -> NSMutableAttributedString {
        guard !text.isEmpty else {
            return NSMutableAttributedString(string: "", attributes: baseAttributes(font))
        }
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let parsed: NSMutableAttributedString
        if let attr = try? AttributedString(markdown: text, options: options) {
            parsed = NSMutableAttributedString(attributedString: NSAttributedString(attr))
        } else {
            parsed = NSMutableAttributedString(string: text)
        }
        let full = NSRange(location: 0, length: parsed.length)
        parsed.addAttributes(baseAttributes(font), range: full)

        parsed.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            guard let raw = (value as? NSNumber)?.uintValue else { return }
            let intent = InlinePresentationIntent(rawValue: raw)
            var traits: NSFontDescriptor.SymbolicTraits = font.fontDescriptor.symbolicTraits
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            parsed.addAttribute(.font, value: fontApplying(traits, to: font), range: range)
            if intent.contains(.strikethrough) {
                parsed.addAttribute(.strikethroughStyle,
                                    value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        return parsed
    }

    // MARK: Attributed -> Markdown

    static func markdown(from attributed: NSAttributedString) -> String {
        let string = attributed.string as NSString
        guard string.length > 0 else { return "" }
        var out: [String] = []
        var lineStart = 0
        while lineStart < string.length {
            let lineRange = string.lineRange(for: NSRange(location: lineStart, length: 0))
            var contentLength = lineRange.length
            // Drop the trailing newline from the content range.
            if contentLength > 0 {
                let last = string.character(at: lineRange.location + contentLength - 1)
                if last == 10 || last == 13 { contentLength -= 1 }
            }
            let contentRange = NSRange(location: lineRange.location, length: contentLength)
            if let (prefix, innerRange) = listPrefix(attributed, at: contentRange, base: string) {
                out.append(prefix + inlineMarkdown(attributed, range: innerRange, base: string))
            } else {
                let level = headingLevel(attributed, at: contentRange)
                let inline = inlineMarkdown(attributed, range: contentRange, base: string)
                let prefix = level > 0 ? String(repeating: "#", count: level) + " " : ""
                out.append(prefix + inline)
            }
            lineStart = NSMaxRange(lineRange)
        }
        return out.joined(separator: "\n")
    }

    private static func headingLevel(_ attributed: NSAttributedString, at range: NSRange) -> Int {
        guard range.length > 0 else { return 0 }
        let value = attributed.attribute(.threadHeading, at: range.location, effectiveRange: nil)
        return (value as? Int) ?? 0
    }

    /// Detects a rendered list marker (`•\t` or `N.\t`) at the *start* of a line's
    /// text. Returns the kind, its displayed number (0 for bullets), and the
    /// marker's length in UTF-16 units. This is the single source of truth for
    /// "is this line a list item" — keyed off visible text, never a stored
    /// attribute, so list-ness can't leak into neighbouring paragraphs.
    static func markerInfo(_ line: String) -> (kind: ListKind, number: Int, length: Int)? {
        if line.hasPrefix("•\t") { return (.bullet, 0, ("•\t" as NSString).length) }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(".\t") {
                let marker = "\(digits).\t"
                return (.number, Int(digits) ?? 1, (marker as NSString).length)
            }
        }
        return nil
    }

    /// If the line is a list item, returns its Markdown prefix (`- ` / `N. `) and
    /// the range of the content *after* the rendered "marker\t".
    private static func listPrefix(_ attributed: NSAttributedString, at range: NSRange,
                                   base: NSString) -> (String, NSRange)? {
        guard range.length > 0 else { return nil }
        let line = base.substring(with: range)
        guard let info = markerInfo(line) else { return nil }
        let innerRange = NSRange(location: range.location + info.length,
                                 length: range.length - info.length)
        switch info.kind {
        case .bullet: return ("- ", innerRange)
        case .number: return ("\(info.number). ", innerRange)
        }
    }

    private static func inlineMarkdown(_ attributed: NSAttributedString,
                                       range: NSRange, base: NSString) -> String {
        guard range.length > 0 else { return "" }
        var result = ""
        attributed.enumerateAttributes(in: range) { attrs, sub, _ in
            var text = base.substring(with: sub)
            guard !text.isEmpty else { return }
            let font = attrs[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let isBold = traits.contains(.bold)
            let isItalic = traits.contains(.italic)
            let isStrike = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0

            if let link = attrs[.link] {
                let urlString = (link as? URL)?.absoluteString ?? "\(link)"
                text = "[\(text)](\(urlString))"
            }
            // Preserve surrounding whitespace outside the emphasis markers.
            let leading = text.prefix { $0 == " " }
            let trailing = text.reversed().prefix { $0 == " " }
            let core = String(text.dropFirst(leading.count).dropLast(trailing.count))
            var wrapped = core
            if !core.isEmpty {
                if isItalic { wrapped = "*\(wrapped)*" }
                if isBold { wrapped = "**\(wrapped)**" }
                if isStrike { wrapped = "~~\(wrapped)~~" }
            }
            result += String(leading) + wrapped + String(trailing.reversed())
        }
        return result
    }

    // MARK: Helpers

    static func fontApplying(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// Detects a Markdown list line. Returns (kind, number, content).
    ///
    /// Any run of spaces after the marker is treated as the marker gap (models
    /// often emit `*   text`), so it never leaks into the content — otherwise the
    /// first line's text sits right of the hanging indent used by wrapped lines.
    private static func listSplit(_ line: String) -> (ListKind, Int, String)? {
        // Bullet: "- ", "* ", "+ "
        if let first = line.first, "-*+".contains(first) {
            let rest = line.dropFirst()
            if rest.first == " " {
                return (.bullet, 0, String(rest.drop(while: { $0 == " " })))
            }
        }
        // Numbered: "<digits>. "
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty {
            let after = line.dropFirst(digits.count)
            if after.first == ".", after.dropFirst().first == " " {
                let content = after.dropFirst().drop(while: { $0 == " " })
                return (.number, Int(digits) ?? 1, String(content))
            }
        }
        return nil
    }

    private static func headingSplit(_ line: String) -> (Int, String) {
        var count = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", count < 3 {
            count += 1; idx = line.index(after: idx)
        }
        guard count > 0, idx < line.endIndex, line[idx] == " " else { return (0, line) }
        return (count, String(line[line.index(after: idx)...]))
    }
}

// MARK: - Inline enhance drop-pin

/// A small "drop-pin" callout — a rounded pill with a downward tail and a live
/// spinner — that hovers just above the end of the block being enhanced.
private final class EnhancePinView: NSView {
    private let spinner = NSProgressIndicator()
    private let pillHeight: CGFloat = 22
    private let tailHeight: CGFloat = 12
    private let pillWidth: CGFloat = 32

    var intrinsicSize: NSSize { NSSize(width: pillWidth, height: pillHeight + tailHeight) }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Soft shadow so the pin reads as floating above the text.
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.25)
            s.shadowBlurRadius = 6
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        // Force a light spinner so it reads on the dark pill in any appearance.
        spinner.appearance = NSAppearance(named: .darkAqua)
        addSubview(spinner)
        spinner.startAnimation(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let s: CGFloat = 14
        spinner.frame = NSRect(x: (pillWidth - s) / 2, y: (pillHeight - s) / 2, width: s, height: s)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight)
        let pillPath = NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8)
        // A thin rounded stem (a "line") dropping from the pill to the text,
        // rather than a triangular tail.
        let stemWidth: CGFloat = 2.5
        let cx = pillWidth / 2
        let stem = NSRect(x: cx - stemWidth / 2, y: pillHeight - 1,
                          width: stemWidth, height: tailHeight)
        let stemPath = NSBezierPath(roundedRect: stem, xRadius: stemWidth / 2, yRadius: stemWidth / 2)
        NSColor(white: 0.17, alpha: 0.96).setFill()
        pillPath.fill()
        stemPath.fill()
    }
}

// MARK: - NSTextView subclass with formatting commands

/// A rich-text view whose formatting actions travel the responder chain, so the
/// app's Format menu (and its ⌘ shortcuts) drive whichever notes view is focused.
final class NotesTextView: NSTextView {

    @objc func threadToggleBold(_ sender: Any?) { toggleTrait(.bold) }
    @objc func threadToggleItalic(_ sender: Any?) { toggleTrait(.italic) }

    @objc func threadToggleStrike(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage,
              shouldChangeText(in: range, replacementString: nil) else { return }
        let existing = (storage.attribute(.strikethroughStyle, at: range.location,
                                          effectiveRange: nil) as? Int) ?? 0
        storage.beginEditing()
        if existing == 0 {
            storage.addAttribute(.strikethroughStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: range)
        } else {
            storage.removeAttribute(.strikethroughStyle, range: range)
        }
        storage.endEditing()
        didChangeText()
    }

    @objc func threadHeading1(_ sender: Any?) { setHeading(1) }
    @objc func threadHeading2(_ sender: Any?) { setHeading(2) }
    @objc func threadBody(_ sender: Any?) { setHeading(0) }

    @objc func threadInsertLink(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return }
        let alert = NSAlert()
        alert.messageText = "Add Link"
        alert.informativeText = "Enter a URL for the selected text."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "https://example.com"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var urlString = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !urlString.isEmpty else { return }
        if !urlString.contains("://") { urlString = "https://" + urlString }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.addAttribute(.link, value: urlString, range: range)
        didChangeText()
    }

    // MARK: - List editing

    /// Turns a just-typed `* `/`- `/`+ ` or `N. ` at the start of a line into a
    /// rendered list item.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard (string as? String) == " " else { return }
        maybeStartList()
    }

    /// Continues a list on Return; a Return on an empty item ends the list.
    /// Whether a line is a list item is decided purely from its visible marker
    /// text, so nothing leaks onto lines the user didn't mark.
    override func insertNewline(_ sender: Any?) {
        guard let storage = textStorage else { return super.insertNewline(sender) }
        let caret = selectedRange().location
        let text = string as NSString
        guard caret > 0 else { return plainNewline(sender) }
        let paragraph = text.paragraphRange(for: NSRange(location: caret, length: 0))
        let paragraphText = trimTrailingNewline(text.substring(with: paragraph))

        guard let info = MarkdownNotes.markerInfo(paragraphText) else { return plainNewline(sender) }

        let content = String(paragraphText.dropFirst(info.length))
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Empty item -> drop the marker and exit the list on a plain line.
            let markerRange = NSRange(location: paragraph.location, length: info.length)
            guard shouldChangeText(in: markerRange, replacementString: "") else { return }
            storage.replaceCharacters(in: markerRange, with: "")
            let lineRange = (string as NSString).paragraphRange(
                for: NSRange(location: paragraph.location, length: 0))
            storage.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: lineRange)
            resetTypingToBody()
            setSelectedRange(NSRange(location: paragraph.location, length: 0))
            didChangeText()
            return
        }

        let nextNumber = info.kind == .number ? info.number + 1 : 0
        let markerText = MarkdownNotes.marker(for: info.kind, number: nextNumber)
        let insertion = "\n" + markerText
        let selection = selectedRange()
        guard shouldChangeText(in: selection, replacementString: insertion) else { return }
        storage.replaceCharacters(in: selection, with: insertion)
        let updated = string as NSString
        let newParagraph = updated.paragraphRange(for: NSRange(location: selection.location + 1, length: 0))
        storage.addAttribute(.paragraphStyle, value: MarkdownNotes.listParagraphStyle(marker: markerText), range: newParagraph)
        storage.addAttribute(.font, value: MarkdownNotes.bodyFont(), range: newParagraph)
        typingAttributes[.paragraphStyle] = MarkdownNotes.listParagraphStyle(marker: markerText)
        typingAttributes[.font] = MarkdownNotes.bodyFont()
        setSelectedRange(NSRange(location: selection.location + (insertion as NSString).length, length: 0))
        didChangeText()
    }

    /// A newline that never inherits heading/list styling — the new line starts
    /// as plain body text.
    private func plainNewline(_ sender: Any?) {
        super.insertNewline(sender)
        resetTypingToBody()
    }

    private func resetTypingToBody() {
        typingAttributes[.font] = MarkdownNotes.bodyFont()
        typingAttributes[.foregroundColor] = NSColor.labelColor
        typingAttributes[.paragraphStyle] = NSParagraphStyle.default
        typingAttributes.removeValue(forKey: .threadHeading)
    }

    private func trimTrailingNewline(_ s: String) -> String {
        var out = s
        while let last = out.last, last == "\n" || last == "\r" { out.removeLast() }
        return out
    }

    private func maybeStartList() {
        guard let storage = textStorage else { return }
        let caret = selectedRange().location
        guard caret > 0 else { return }
        let text = string as NSString
        let paragraph = text.paragraphRange(for: NSRange(location: caret - 1, length: 0))
        let prefixRange = NSRange(location: paragraph.location, length: caret - paragraph.location)
        guard prefixRange.length > 0 else { return }
        let prefix = text.substring(with: prefixRange)
        // Only the marker-plus-space should precede the caret on this line.
        guard !prefix.contains("\t") else { return }

        var kind: ListKind?
        if prefix == "* " || prefix == "- " || prefix == "+ " {
            kind = .bullet
        } else if prefix == "1. " {
            // Numbered lists may only *begin* at 1; higher numbers appear only as
            // Return-driven continuations, so "2." can't materialise on its own.
            kind = .number
        }
        guard let listKind = kind else { return }

        let markerText = MarkdownNotes.marker(for: listKind, number: 1)
        guard shouldChangeText(in: prefixRange, replacementString: markerText) else { return }
        storage.replaceCharacters(in: prefixRange, with: markerText)
        let updated = string as NSString
        let newParagraph = updated.paragraphRange(for: NSRange(location: paragraph.location, length: 0))
        storage.addAttribute(.paragraphStyle, value: MarkdownNotes.listParagraphStyle(marker: markerText), range: newParagraph)
        storage.addAttribute(.font, value: MarkdownNotes.bodyFont(), range: newParagraph)
        typingAttributes[.paragraphStyle] = MarkdownNotes.listParagraphStyle(marker: markerText)
        typingAttributes[.font] = MarkdownNotes.bodyFont()
        setSelectedRange(NSRange(location: paragraph.location + (markerText as NSString).length, length: 0))
        didChangeText()
    }

    // MARK: - Inline collaborator (hover sparkle + locked streaming regions)

    /// One in-flight block enhancement. Several can run at once; each owns its
    /// own tagged region (found by its `id`), floating pin, and clean original.
    private final class EnhanceOp {
        let id: Int
        let original: NSAttributedString
        let pin: EnhancePinView
        var task: Task<Void, Never>?
        init(id: Int, original: NSAttributedString, pin: EnhancePinView) {
            self.id = id
            self.original = original
            self.pin = pin
        }
    }

    /// Supplied by the host: given a block's Markdown and a partial callback,
    /// returns the enhanced block Markdown (or nil). This view owns locking each
    /// block, streaming the partials into it, and the single-step undo.
    var enhanceProvider: ((String, @escaping (String) -> Void) async -> String?)?

    /// True while any block is being enhanced, so the SwiftUI coordinator avoids
    /// propagating the half-streamed text to the model binding / disk.
    var isEnhancingBlock: Bool { !enhanceOps.isEmpty }

    private var sparkle: NSButton?
    private var hoverArea: NSTrackingArea?
    private var hoverBlockRange: NSRange?
    /// Active enhancements, keyed by id. Concurrency is fine because every edit
    /// runs on the main actor and each op re-locates its region by attribute.
    private var enhanceOps: [Int: EnhanceOp] = [:]
    private var nextEnhanceID = 0

    /// The light-blue highlight bar drawn behind a block while it streams.
    private static let enhanceHighlight = NSColor.systemBlue.withAlphaComponent(0.15)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateSparkle(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideSparkle()
    }

    /// Positions (or hides) the sparkle button for the block under the cursor.
    /// The sparkle stays available while other blocks stream, but never offers to
    /// enhance a block that already overlaps a pending region.
    private func updateSparkle(for event: NSEvent) {
        guard enhanceProvider != nil,
              let layoutManager, let textContainer,
              let storage = textStorage, storage.length > 0 else { hideSparkle(); return }

        let local = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let containerPoint = CGPoint(x: local.x - origin.x, y: local.y - origin.y)
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        var charIndex = layoutManager.characterIndexForGlyph(at: glyph)
        let ns = string as NSString
        if charIndex >= ns.length { charIndex = max(0, ns.length - 1) }

        let paragraph = ns.paragraphRange(for: NSRange(location: charIndex, length: 0))
        let blockText = ns.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !blockText.isEmpty else { hideSparkle(); return }
        // Don't offer the sparkle over a block that's already streaming.
        guard !allPendingRanges().contains(where: { NSIntersectionRange($0, paragraph).length > 0 }) else {
            hideSparkle(); return
        }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        // Only offer the sparkle when the cursor is actually over the line.
        guard local.y >= rect.minY - 4, local.y <= rect.maxY + 4 else { hideSparkle(); return }

        hoverBlockRange = paragraph
        let button = ensureSparkle()
        let size: CGFloat = 22
        button.frame = NSRect(
            x: max(4, bounds.width - size - 8),
            y: rect.minY + max(0, (min(rect.height, 24) - size) / 2),
            width: size, height: size
        )
        button.isHidden = false
    }

    private func ensureSparkle() -> NSButton {
        if let sparkle { return sparkle }
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.title = ""
        button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Enhance this block")
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .controlAccentColor
        button.toolTip = "Enhance this block"
        button.target = self
        button.action = #selector(sparkleTapped)
        // Bare glyph, no chip: it sits in the block's right margin, where a filled
        // square reads as a stray light patch over the note's panel.
        addSubview(button)
        sparkle = button
        return button
    }

    private func hideSparkle() { sparkle?.isHidden = true }

    @objc private func sparkleTapped() {
        guard let range = hoverBlockRange else { return }
        beginEnhance(range: range)
    }

    /// Locks the hovered block and streams a rewrite into it. Runs alongside any
    /// other in-flight blocks; only refuses if this block overlaps one already
    /// streaming.
    private func beginEnhance(range: NSRange) {
        guard let provider = enhanceProvider, let storage = textStorage,
              range.location + range.length <= storage.length else { return }
        guard !allPendingRanges().contains(where: { NSIntersectionRange($0, range).length > 0 }) else { return }

        let original = storage.attributedSubstring(from: range)
        let blockMarkdown = MarkdownNotes.markdown(from: original)
        guard !blockMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let id = nextEnhanceID
        nextEnhanceID += 1
        let pin = EnhancePinView(frame: .zero)
        addSubview(pin)
        let op = EnhanceOp(id: id, original: original, pin: pin)
        enhanceOps[id] = op
        hideSparkle()
        applyPending(to: range, id: id)

        op.task = Task { @MainActor [weak self] in
            let final = await provider(blockMarkdown) { partial in
                self?.renderPending(id: id, markdown: partial)
            }
            guard let self, !Task.isCancelled else { return }
            self.finishEnhance(op: op, final: final)
        }
    }

    /// Cancels every in-flight enhance and restores each original untouched.
    func cancelEnhance() {
        guard !enhanceOps.isEmpty else { return }
        for op in enhanceOps.values {
            op.task?.cancel()
            op.pin.removeFromSuperview()
            if let storage = textStorage, let pending = pendingRange(for: op.id) {
                storage.beginEditing()
                storage.replaceCharacters(in: pending, with: op.original)
                storage.endEditing()
            }
        }
        enhanceOps.removeAll()
    }

    /// Highlights the block with the light-blue bar and tags it pending (by id),
    /// without changing its text yet, then drops its pin at the end.
    private func applyPending(to range: NSRange, id: Int) {
        guard let storage = textStorage else { return }
        storage.beginEditing()
        storage.addAttribute(.threadPendingEnhance, value: id, range: range)
        storage.addAttribute(.backgroundColor, value: Self.enhanceHighlight, range: range)
        storage.endEditing()
        positionPin(for: id)
    }

    /// Replaces one op's pending region with its latest streamed Markdown. Done
    /// as a direct storage edit (no undo registration, no delegate notification)
    /// so concurrent edits elsewhere keep clean undo history and the half-streamed
    /// text never reaches the model binding.
    private func renderPending(id: Int, markdown: String) {
        guard enhanceOps[id] != nil, let storage = textStorage,
              let range = pendingRange(for: id) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: pendingAttributed(from: markdown, id: id))
        storage.endEditing()
        positionPin(for: id)
    }

    private func pendingAttributed(from markdown: String, id: Int) -> NSAttributedString {
        let attributed = NSMutableAttributedString(attributedString: MarkdownNotes.attributed(from: markdown))
        let full = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(.threadPendingEnhance, value: id, range: full)
        attributed.addAttribute(.backgroundColor, value: Self.enhanceHighlight, range: full)
        return attributed
    }

    // MARK: Drop-pin positioning

    /// Positions an op's pin so its tail points just above the end of its streamed
    /// text, following along as the block grows.
    private func positionPin(for id: Int) {
        guard let op = enhanceOps[id], let rect = pendingEndRect(for: id) else { return }
        let size = op.pin.intrinsicSize
        let endX = rect.maxX
        let x = min(max(2, endX - size.width / 2), max(2, bounds.width - size.width - 2))
        // Point the tail tip at the vertical middle of the line so the pin rests
        // just above the streamed text rather than a full line higher.
        let y = max(2, rect.midY - size.height)
        op.pin.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The view-space rect of the last *visible* character of an op's pending
    /// region — i.e. the end of the sentence. Trailing newlines/whitespace are
    /// skipped so the pin lands after the final word, not out at the container's
    /// right edge (a trailing newline's glyph spans the whole line fragment).
    private func pendingEndRect(for id: Int) -> CGRect? {
        guard let layoutManager, let textContainer,
              let range = pendingRange(for: id) else { return nil }
        let ns = string as NSString
        guard ns.length > 0 else { return nil }
        var end = min(range.location + range.length, ns.length)
        while end > range.location {
            let c = ns.character(at: end - 1)
            // newline, carriage return, tab, space
            if c == 10 || c == 13 || c == 9 || c == 32 { end -= 1 } else { break }
        }
        let endChar = min(max(range.location, end - 1), ns.length - 1)
        let charRange = NSRange(location: endChar, length: 1)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let origin = textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        return rect
    }

    /// The current span of one op's pending block, located by its id attribute so
    /// it survives edits (the user's, or other ops') elsewhere in the document.
    private func pendingRange(for id: Int) -> NSRange? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.threadPendingEnhance,
                                   in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if (value as? Int) == id { found = found.map { NSUnionRange($0, range) } ?? range }
        }
        return found
    }

    /// Every active pending region (one per op), used for edit-locking and to
    /// keep the sparkle off blocks that are already streaming.
    private func allPendingRanges() -> [NSRange] {
        guard !enhanceOps.isEmpty, let storage = textStorage, storage.length > 0 else { return [] }
        var byID: [Int: NSRange] = [:]
        storage.enumerateAttribute(.threadPendingEnhance,
                                   in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let id = value as? Int { byID[id] = byID[id].map { NSUnionRange($0, range) } ?? range }
        }
        return Array(byID.values)
    }

    /// Commits one op's enhancement as a single undoable edit (⌘Z restores that
    /// block). Restores the clean original first so the undo baseline is the
    /// original rather than the last streamed frame. Other ops keep streaming.
    private func finishEnhance(op: EnhanceOp, final: String?) {
        op.pin.removeFromSuperview()
        guard let storage = textStorage, let pending = pendingRange(for: op.id) else {
            enhanceOps[op.id] = nil
            return
        }
        storage.beginEditing()
        storage.replaceCharacters(in: pending, with: op.original)
        storage.endEditing()
        let restored = NSRange(location: pending.location, length: op.original.length)

        // Remove this op before the committing edit so that, once the last op
        // finishes, the coordinator's textDidChange propagates the final result.
        enhanceOps[op.id] = nil

        guard let final, !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setSelectedRange(NSRange(location: min(restored.location, (string as NSString).length), length: 0))
            // Flush to the binding if nothing else is streaming.
            if enhanceOps.isEmpty { didChangeText() }
            return
        }

        let finalAttributed = MarkdownNotes.attributed(from: final)
        guard shouldChangeText(in: restored, replacementString: finalAttributed.string) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: restored, with: finalAttributed)
        storage.endEditing()
        didChangeText()
        let caret = min(restored.location + finalAttributed.length, (string as NSString).length)
        setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// Rejects user edits that touch any locked (streaming) region while allowing
    /// edits everywhere else in the note.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if !enhanceOps.isEmpty {
            for locked in allPendingRanges() where rangeConflicts(locked: locked, edit: affectedCharRange) {
                NSSound.beep()
                return false
            }
        }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    private func rangeConflicts(locked: NSRange, edit: NSRange) -> Bool {
        if edit.length == 0 {
            // A caret insertion is only blocked strictly inside the locked region;
            // typing right at either boundary is allowed.
            return edit.location > locked.location && edit.location < locked.location + locked.length
        }
        return NSIntersectionRange(locked, edit).length > 0
    }

    private func toggleTrait(_ trait: NSFontDescriptor.SymbolicTraits) {
        let range = selectedRange()
        func toggled(_ font: NSFont) -> NSFont {
            var traits = font.fontDescriptor.symbolicTraits
            if traits.contains(trait) { traits.remove(trait) } else { traits.insert(trait) }
            return MarkdownNotes.fontApplying(traits, to: font)
        }
        guard let storage = textStorage else { return }
        if range.length == 0 {
            let current = (typingAttributes[.font] as? NSFont) ?? MarkdownNotes.bodyFont()
            typingAttributes[.font] = toggled(current)
            return
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let font = (value as? NSFont) ?? MarkdownNotes.bodyFont()
            storage.addAttribute(.font, value: toggled(font), range: sub)
        }
        storage.endEditing()
        didChangeText()
    }

    private func setHeading(_ level: Int) {
        guard let storage = textStorage else { return }
        let paragraph = (string as NSString).paragraphRange(for: selectedRange())
        guard shouldChangeText(in: paragraph, replacementString: nil) else { return }
        let font = level == 0 ? MarkdownNotes.bodyFont() : MarkdownNotes.headingFont(level)
        storage.beginEditing()
        storage.addAttribute(.font, value: font, range: paragraph)
        if level == 0 {
            storage.removeAttribute(.threadHeading, range: paragraph)
        } else {
            storage.addAttribute(.threadHeading, value: level, range: paragraph)
        }
        storage.endEditing()
        didChangeText()
    }
}

// MARK: - SwiftUI wrapper

/// A Markdown-backed rich text editor. Binds to a Markdown string; edits are
/// serialized back to Markdown on change.
struct RichTextEditor: NSViewRepresentable {
    @Binding var markdown: String
    /// When true, grab keyboard focus once the view is in a window and place the
    /// caret at the end (used when a new note promotes into the saved view).
    var autofocus: Bool = false
    /// Inline collaborator hook: given a hovered block's Markdown and a streaming
    /// callback, returns the enhanced block Markdown (or nil). When nil, the
    /// hover sparkle is not offered.
    var onEnhanceBlock: ((_ block: String, _ onPartial: @escaping (String) -> Void) async -> String?)?
    /// Extra room at the end of the document, for whatever floats over the foot of the
    /// pane (the note's ask field). A content inset rather than a smaller frame: the
    /// text still draws to the pane's edge and scrolls under what floats there, it
    /// just gains enough slack to be scrolled clear of it.
    var bottomInset: CGFloat = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)

        let textView = NotesTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.drawsBackground = false
        textView.font = MarkdownNotes.bodyFont()
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 12, height: 16)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.typingAttributes = [.font: MarkdownNotes.bodyFont(),
                                     .foregroundColor: NSColor.labelColor]

        textView.textStorage?.setAttributedString(MarkdownNotes.attributed(from: markdown))
        textView.enhanceProvider = onEnhanceBlock
        context.coordinator.lastMarkdown = markdown
        context.coordinator.textView = textView

        scroll.documentView = textView

        if autofocus {
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
                let end = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if scroll.contentInsets.bottom != bottomInset {
            scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }
        guard let textView = context.coordinator.textView else { return }
        // Refresh the hook so it captures the host's latest state (transcript etc.).
        textView.enhanceProvider = onEnhanceBlock
        // Only reset when the model changed from the outside (e.g. switching
        // sessions), never from our own keystrokes — that would fight the cursor.
        guard markdown != context.coordinator.lastMarkdown else { return }
        // An external change (e.g. switching notes) supersedes any in-flight
        // block enhance; abandon it cleanly before replacing the content.
        if textView.isEnhancingBlock { textView.cancelEnhance() }
        let selected = textView.selectedRange()
        textView.textStorage?.setAttributedString(MarkdownNotes.attributed(from: markdown))
        context.coordinator.lastMarkdown = markdown
        if selected.location <= (textView.string as NSString).length {
            textView.setSelectedRange(selected)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: RichTextEditor
        weak var textView: NotesTextView?
        var lastMarkdown = ""

        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView, let storage = textView.textStorage else { return }
            // While a block is streaming, the storage holds greyed, half-finished
            // text — don't push it to the binding or persist it. The final commit
            // fires one more textDidChange with the finished result.
            guard !textView.isEnhancingBlock else { return }
            let md = MarkdownNotes.markdown(from: storage)
            lastMarkdown = md
            parent.markdown = md
        }
    }
}
