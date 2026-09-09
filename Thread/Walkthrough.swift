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

enum WalkthroughStep: Int, CaseIterable {
    case folder
    case start
    case notesAndEnhance
    case chat
    case notch
    case appleNotes
    case setup

    var position: Int { rawValue + 1 }
}

struct WalkthroughCard: View {
    let step: WalkthroughStep
    let icon: String
    let title: String
    let message: String
    let primaryTitle: String?
    var primaryDisabled = false
    let onPrimary: () -> Void
    let onSkip: () -> Void
    var secondaryTitle: String? = nil
    var onSecondary: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .glassEffect(AppAppearance.glass(), in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(step.position) of \(WalkthroughStep.allCases.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Button("Skip", action: onSkip)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            if let secondaryTitle, let onSecondary {
                Button(secondaryTitle, action: onSecondary)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if let primaryTitle {
                Button(primaryTitle, action: onPrimary)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(primaryDisabled)
            }
        }
        .padding(14)
        .frame(maxWidth: 620)
        .glassEffect(AppAppearance.glass(interactive: true), in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 20, y: 8)
        .accessibilityElement(children: .contain)
    }
}
