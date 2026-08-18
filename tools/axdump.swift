#!/usr/bin/env swift
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
//
// axdump.swift — Accessibility tree dumper for capturing meeting mute strings.
//
// Reads the SAME attributes BrowserMeetingMuteMonitor reads (kAXRoleAttribute,
// kAXDescriptionAttribute, kAXTitleAttribute) with the same breadth-first walk,
// so what you see here is exactly what the monitor would match against.
//
// Usage (run during a LIVE meeting, toggling mute so you capture both states):
//
//   swift tools/axdump.swift                       # scans Chrome + new Teams
//   swift tools/axdump.swift com.microsoft.teams2  # scan one bundle id
//   swift tools/axdump.swift com.google.Chrome us.zoom.xos
//
// The process running this (your terminal app) needs Accessibility permission:
// System Settings › Privacy & Security › Accessibility.
//
import AppKit
import ApplicationServices

let defaultBundleIDs = ["com.google.Chrome", "com.microsoft.teams2"]
let bundleIDs = CommandLine.arguments.count > 1
    ? Array(CommandLine.arguments.dropFirst())
    : defaultBundleIDs

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data(
        ("Accessibility not granted to this terminal.\n"
         + "Grant it in System Settings › Privacy & Security › Accessibility, "
         + "then re-run.\n").utf8
    ))
    let options = [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
    ] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    exit(1)
}

func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element, attribute as CFString, &value
    ) == .success, let value else { return nil }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

func elementAttribute(
    _ element: AXUIElement, _ attribute: String
) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element, attribute as CFString, &value
    ) == .success,
          let value,
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func elementArrayAttribute(
    _ element: AXUIElement, _ attribute: String
) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        element, attribute as CFString, &value
    ) == .success, let array = value as? [AXUIElement] else { return [] }
    return array
}

// Highlight anything that looks mute/mic/audio related so it's easy to spot.
let interesting = ["mic", "mute", "audio", "sound", "camera", "unmute"]
func flag(_ text: String) -> String {
    let lower = text.lowercased()
    return interesting.contains(where: lower.contains) ? "  <<< " : "      "
}

func dumpWindow(_ root: AXUIElement, label: String) {
    print("\n=== window: \(label) ===")
    var queue: [(AXUIElement, Int)] = [(root, 0)]
    var index = 0
    var seen: [CFHashCode: [AXUIElement]] = [:]
    var printedButtons = Set<String>()
    var printedTabs = Set<String>()

    while index < queue.count, index < 6000 {
        let (element, depth) = queue[index]
        index += 1

        let identity = CFHash(element)
        if seen[identity, default: []].contains(where: { CFEqual($0, element) }) {
            continue
        }
        seen[identity, default: []].append(element)

        let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
        let desc = stringAttribute(element, kAXDescriptionAttribute as String)
        let title = stringAttribute(element, kAXTitleAttribute as String)

        if role == "AXButton" {
            let d = (desc ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !d.isEmpty || !t.isEmpty {
                let line = "AXButton  desc=\"\(d)\"  title=\"\(t)\""
                if printedButtons.insert(line).inserted {
                    print("\(flag(d + " " + t))\(line)")
                }
            }
        }

        if role == "AXRadioButton" {
            let tabText = [title, desc].compactMap { $0 }.joined(separator: " ")
            if !tabText.isEmpty, printedTabs.insert(tabText).inserted {
                print("\(flag(tabText))AXRadioButton (tab) \"\(tabText)\"")
            }
        }

        guard depth < 28 else { continue }
        for child in elementArrayAttribute(element, kAXChildrenAttribute as String) {
            queue.append((child, depth + 1))
        }
    }
}

for bundleID in bundleIDs {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    guard !apps.isEmpty else {
        print("\n### \(bundleID): not running")
        continue
    }
    for app in apps {
        print("\n########## \(bundleID) (pid \(app.processIdentifier)) ##########")
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var windows = elementArrayAttribute(root, kAXWindowsAttribute as String)
        if windows.isEmpty,
           let focused = elementAttribute(root, kAXFocusedWindowAttribute as String) {
            windows = [focused]
        }
        if windows.isEmpty {
            print("(no windows exposed)")
        }
        for (i, window) in windows.enumerated() {
            let wtitle = stringAttribute(window, kAXTitleAttribute as String) ?? "#\(i)"
            dumpWindow(window, label: wtitle)
        }
    }
}
