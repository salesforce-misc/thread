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

/// Picks the on-device speech model to use for a requested locale.
///
/// `SpeechTranscriber` only ships models for specific language-region pairs, so a
/// system set to a common combination such as English (Netherlands), `en-NL`, has no
/// exact model and transcription would refuse to start. This resolver falls back to
/// another model for the same language instead.
///
/// `SpeechTranscriber.supportedLocale(equivalentTo:)` is deliberately not used: on
/// macOS 27.2 it is not deterministic for these locales (`en-NL` returned `en-GB`,
/// `en-IE`, `en-NZ`, `en-SG` or `en-AU` across repeated calls), which could put the
/// microphone and system-audio transcribers on different models. Everything here is a
/// pure function of its inputs, so both always agree.
enum SpeechLocaleResolver {

    /// Regions to try, in order, when the requested region has no model. Only needed
    /// where the language's likely region (from CLDR likely subtags) is not the
    /// preferred fallback: English without a regional model uses British, then US
    /// English, rather than CLDR's US default.
    private static let preferredRegions: [String: [String]] = [
        "en": ["GB", "US"],
    ]

    /// Returns the supported locale that best matches `requested`, or `nil` when no
    /// model exists for its language at all. Order: exact language and region, then
    /// `preferredRegions`, then the language's likely region, then any supported
    /// locale with the same language and script, chosen by identifier so the result
    /// is stable.
    static func resolve(_ requested: Locale, supported: [Locale]) -> Locale? {
        guard let language = requested.language.languageCode?.identifier else { return nil }
        let script = likelyScript(of: requested.language)

        // Only models for the same language and writing system are candidates, so
        // Traditional Chinese never falls back to a Simplified Chinese model.
        let candidates = supported
            .filter { locale in
                locale.language.languageCode?.identifier == language
                    && likelyScript(of: locale.language) == script
            }
            .sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }
        guard !candidates.isEmpty else { return nil }

        func candidate(inRegion region: String?) -> Locale? {
            guard let region else { return nil }
            return candidates.first { $0.language.region?.identifier == region }
        }

        // The language's own region is the dialect; `Locale.region` can instead be a
        // formatting override such as `en_US@rg=nlzzzz`, so it is only a fallback.
        let requestedRegion = requested.language.region?.identifier ?? requested.region?.identifier
        if let exact = candidate(inRegion: requestedRegion) { return exact }
        for region in preferredRegions[language, default: []] {
            if let preferred = candidate(inRegion: region) { return preferred }
        }
        // Likely region of the language and script without the requested region: for
        // `de-NL` that is `DE` (maximizing `de-NL` itself would keep `NL`), and for
        // Traditional Chinese it is `TW`, not the `CN` of bare `zh`.
        if let likely = candidate(inRegion: likelyRegion(ofLanguage: language, script: script)) {
            return likely
        }
        return candidates.first
    }

    /// The region CLDR likely subtags assign to a language in a script, e.g. `DE` for
    /// `de` and `TW` for `zh-Hant`.
    private static func likelyRegion(ofLanguage language: String, script: String?) -> String? {
        let base = Locale.Language(
            languageCode: Locale.LanguageCode(language),
            script: script.map { Locale.Script($0) },
            region: nil
        )
        return Locale.Language(identifier: base.maximalIdentifier).region?.identifier
    }

    /// The script a language is written in, filling in the likely default when the
    /// identifier leaves it implicit (`zh-TW` is Traditional, `zh-CN` Simplified).
    private static func likelyScript(of language: Locale.Language) -> String? {
        language.script?.identifier
            ?? Locale.Language(identifier: language.maximalIdentifier).script?.identifier
    }
}
