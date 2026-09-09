# Thread

![Thread running a local meeting transcript on macOS](assets/thread-app.gif)

Thread is a private meeting companion for macOS. Start it before a call and it listens, transcribes the conversation live, and helps you turn it into clean notes, summaries, and follow-ups — without anything ever leaving your Mac.

Everything runs locally on your device. There's no account, no sign-up, and no cloud: your meetings, notes, and transcripts stay entirely on your Mac, even offline.

Sessions are plain Markdown files in folders you choose, so your notes stay readable, greppable, and yours.

## Download

**[⬇︎ Download the latest version](https://github.com/salesforce-misc/thread/releases/latest/download/Thread.dmg)**

[See all releases](https://github.com/salesforce-misc/thread/releases)

Open the `.dmg` and drag **Thread** to your Applications folder. The build is notarized, so it opens without a Gatekeeper warning, and it keeps itself up to date automatically after that.

## Features

- **Live transcription** — Captures both your voice and everyone else on the call, transcribed in real time as you talk.
- **Private & offline** — 100% on-device. No account, no internet required, and nothing is ever uploaded.
- **Rich notes** — Take formatted notes right next to the transcript, with the keyboard shortcuts you already know.
- **AI Enhance** — Turns rough notes into a clean, structured summary — overview, key points, decisions, and action items — automatically when you stop recording, or any time you ask.
- **Ask your notes** — Chat with your meetings. Ask questions across everything you've captured and get answers drawn from your own notes and transcripts.
- **Notch** — Optional Liquid Glass strip on the MacBook notch: start or stop recording, see the timer, open the notepad, and chat while a call is going. Recording keeps running if you close the main window.
- **Named speakers (experimental)** — Opt-in; off by default. Transcript lines can show participants' names instead of just `You` and `Meeting`. Reads Zoom, Google Meet, and Microsoft Teams, and can miss or mislabel people.
- **Tasks** — Action items become a simple checklist you can tick off, edit, or add to.
- **Smart term correction** — Thread learns the names and terms you use, so they come out spelled right.
- **Fast search** — Instantly search across every note, transcript, and title.
- **Multiple recordings per session** — Add more recordings to an existing note; each one is timestamped so the timeline stays clear.
- **Organized your way** — Keep notes in folders you choose, collapse and reorder them, and rename anything with a double-click.
- **Auto-save** — Your transcript and notes save as you go, so nothing is lost.
- **Apple Notes** — Optional. Send a saved session into Apple Notes (iCloud or On My Mac) so you can read it there. Thread still keeps the Markdown file on disk; Notes gets a copy.

## How it works

**Live transcription of both sides.** The microphone is captured through `AVAudioEngine` and the far end through `ScreenCaptureKit` system-audio capture, each fed to its own on-device transcriber. Entries are labelled `You` or `Meeting`, and audio is converted into 20 ms chunks on an explicit timeline to get lower-latency partial results than macOS's default ~100 ms mic buffers.

**Automatic meeting detection.** `MeetingDetector` polls Chrome's tabs via AppleScript for a real Meet room URL, distinguishes the lobby from a joined call by watching the tab title, and derives a human meeting name to offer one-tap recording.

**Mute-aware capture.** `GoogleMeetMuteMonitor` reads Meet's mute state from the accessibility tree and gates microphone transcription accordingly, so muting yourself in the call stops you being transcribed.

**Speaker attribution.** Off by default as an experimental Setup toggle; without it, transcript lines stay `You` or `Meeting`. When enabled, `SpeakerVisionMonitor` finds the active speaker in the host app's accessibility tree and attributes lines to named participants. Google Meet, Microsoft Teams on the web and in the desktop app, and Zoom on the web are all read from a class marker on the speaking tile. Zoom's desktop app publishes no speaking indicator at all, so it attributes by elimination instead: when exactly one remote participant is unmuted, they are the speaker. Names can be missed or mislabeled.

**Enhance.** Rewrites your rough notes into clean Markdown using the meeting transcript as evidence, and extracts action items with owners — only naming someone when the name appears verbatim, never guessing. Ships with a built-in default prompt, plus your own reusable templates.

**Ask.** A chat over your notes, scoped to one note or your whole library. Notes are chunked and embedded with `NLEmbedding` for semantic retrieval, and the model has tools to search passages, read or summarise a specific note, summarise a topic across many notes, and list or tick off tasks. Answers cite the notes they came from. Asking about a single note is a one-off conversation held in memory — only the transcript and your notes are written to the `.md` file.

**Learned glossary.** When Enhance sees that your notes spell a name or term differently from the transcript, it proposes a correction. Accepted terms persist per-user in Application Support and are applied to future transcripts, so Thread learns your jargon and your colleagues' names.

**Rich text notes.** A Markdown-backed editor with headings, bold/italic/strikethrough, links, bullet and numbered lists, and checkbox tasks, driven by the Format menu and the usual shortcuts.

**Full-library search.** An in-memory index over every note's title, notes, and transcript, rebuilt off the main thread and filtered live as you type.

**Apple Notes.** Optional, one-way copy from Thread into Apple Notes. Setup chooses iCloud or On My Mac; Thread does not treat Notes as the source of truth, and turning this on requires Automation access to Notes.

## Requirements

- **macOS 26 (Tahoe) or later.** Thread is built on frameworks that ship with macOS 26: `FoundationModels` for the on-device LLM, `SpeechAnalyzer`/`SpeechTranscriber` for streaming speech recognition, and Liquid Glass for the UI.
- **An Apple Intelligence–capable Mac** (Apple silicon, M1 or later). Note enhancement and Ask depend on the system language model; transcription and note-taking work without it.
- **Xcode 26** with a Developer ID certificate if you intend to build signed releases.
- **Google Chrome** for automatic meeting detection. Recording works from any source, but detection reads Chrome's tabs.

## Building

```bash
brew install xcodegen        # only needed if you change project.yml
xcodegen generate            # regenerates Thread.xcodeproj from project.yml
open Thread.xcodeproj
```

Then build and run the `Thread` scheme. Debug builds install as a separate app (`com.thread.app.dev`, "Thread Dev") so you can run them next to a release install, and they skip Sparkle entirely.

`Thread.xcodeproj` is committed, so you can open it directly without XcodeGen — but `project.yml` is the source of truth. Edit it and regenerate rather than changing build settings in Xcode.

### Permissions

macOS will prompt on first use. Each is requested only when the corresponding feature runs:

| Permission | Why |
| --- | --- |
| Microphone | Transcribing your own speech |
| Screen Recording | `ScreenCaptureKit` system-audio capture of the other participants |
| Automation (Chrome) | Reading tab URLs to detect an active Meet call |
| Automation (Notes) | Optional copy of a saved session into Apple Notes |
| Accessibility | Reading mute state and the active speaker from the meeting's UI |

Thread is intentionally **not** sandboxed (`ENABLE_APP_SANDBOX: NO`) because accessibility inspection of another app's UI is incompatible with the sandbox. Hardened runtime is on, and the entitlements grant only audio input, Apple Events, and user-selected file access.

### Where notes live

You pick one or more library folders; each becomes a section in the sidebar. If you haven't chosen one, Thread creates `~/Desktop/Thread` on demand so recording never blocks on setup. Folder access persists across launches via security-scoped bookmarks. Each session is one `.md` file, and the files are the source of truth — edit or delete them outside the app and the sidebar follows.

## Project layout

| Path | Contents |
| --- | --- |
| `Thread/AudioCaptureController.swift` | Mic + system-audio capture, transcriber lifecycle, watchdogs |
| `Thread/MeetingTranscriber.swift` | One on-device `SpeechAnalyzer` pipeline per audio stream |
| `Thread/MeetingDetector.swift` | Chrome tab polling and Meet room detection |
| `Thread/GoogleMeetMuteMonitor.swift` | Mute-state gating of mic transcription |
| `Thread/SpeakerVisionMonitor.swift` | Active-speaker attribution from the accessibility tree |
| `Thread/MeetAccessibilityProbe.swift` | DEBUG-only accessibility-tree dumper for finding each provider's markup |
| `Thread/AIEngine.swift` | Enhance, Ask, embeddings, and the model's tools |
| `Thread/Glossary.swift` | Learned vocabulary and transcript correction |
| `Thread/SessionStore.swift` | Library folders, Markdown read/write, autosave |
| `Thread/NotesSync.swift` | Optional one-way copy of a session into Apple Notes |
| `Thread/RichTextNotes.swift` | Markdown ↔ attributed string, the notes editor |
| `Thread/Search.swift` | Library-wide search index |
| `Thread/ContentView.swift` | The app UI |
| `Thread/TranscriptionDiagnostics.swift` | Timing instrumentation; no-ops in release builds |
| `tools/axdump.swift` | Standalone accessibility-tree dump utility |
| `updates/` | Sparkle feed: `appcast.xml`, DMGs, delta patches |
| `THIRD-PARTY-NOTICES.md` | Licenses for Sparkle and the libraries vendored inside it |
| `LICENSE.txt` | Apache License 2.0, the terms this project is released under |

The Debug menu exposes the accessibility probes — dump a provider's tree, watch speaking state, scan the speaker — for each of Meet, Teams, and Zoom. Run them during a live call when a provider changes its markup and speaker detection breaks. They only read; they never click or mutate anything.

## Updates

This repository also hosts the [Sparkle](https://sparkle-project.org) auto-update feed:

- `updates/appcast.xml` — the update manifest Thread checks
- `updates/Thread-*.dmg` — notarized release builds

## Releasing

`./release.sh` builds it and `./publish.sh` ships it.

```bash
# 1. Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml, then
#    xcodegen generate
./release.sh                 # build, sign, notarize, DMG, appcast
./release.sh --no-notarize   # skip notarization; Gatekeeper will warn
# 2. Write user-facing notes at release-notes/<version>.md
./publish.sh                 # push the feed, tag, attach the DMG to a Release
```

`release.sh` builds Release, signs with Developer ID, re-signs Sparkle's nested XPC helpers inside-out (xcodebuild doesn't, and notarization rejects them otherwise), notarizes and staples both the app and the DMG, then regenerates `updates/appcast.xml` with `generate_appcast`.

A release reaches people two different ways, and only doing one of them is the easy mistake. Sparkle reads `updates/appcast.xml`, so **installed copies** update as soon as that folder is pushed — which is why `updates/` is deliberately not gitignored. The README's download button points at `/releases/latest/download/Thread.dmg`, which is **GitHub Releases**, a separate system that a push doesn't touch; skip it and new downloaders get whatever the last tagged release was. `publish.sh` does both, and is safe to re-run: it skips the push when the feed already matches and leaves an existing release alone.

Old DMGs are kept so Sparkle can build delta patches against them. If you rebuild a version that has already shipped, delete its delta files so `generate_appcast` rebuilds them against the new DMG rather than leaving stale patches in the feed — a stale delta patches users up to the wrong binary.

One-time setup. Copy `release.config.sh.example` to `release.config.sh` (gitignored) and fill in your Developer ID certificate hash, Apple team ID, and the public URL your `updates/` folder is served from — `release.sh` refuses to run without them. Install Sparkle's tools into `.sparkle-tools/bin` (also gitignored), and store a notarization credential under the `thread-notary` keychain profile:

```bash
xcrun notarytool store-credentials "thread-notary" \
  --apple-id "you@example.com" --team-id "YOUR_TEAM_ID" --password "app-specific-password"
```

The EdDSA private key that signs each update lives in your keychain and is never in this repo. `SUPublicEDKey` in `Info.plist` is its public half. Auto-updates need a publicly reachable feed: `SUFeedURL` and `DOWNLOAD_URL_PREFIX` both point at `raw.githubusercontent.com`, which serves this repository's `updates/` folder directly.

## Privacy

Everything runs locally. Speech recognition uses on-device models, note enhancement and Ask use Apple's on-device foundation model, and embeddings come from `NaturalLanguage`. The app contains no networking code of its own.

Two things do reach the network, neither carrying your content: macOS downloads the speech recognition model assets from Apple the first time you record in a new language, and Sparkle fetches the appcast to check for updates. Your audio, transcripts, and notes never leave your Mac.

## Third-party software

Thread has one third-party dependency: [Sparkle](https://github.com/sparkle-project/Sparkle) 2.9.4 (MIT), which provides auto-updates. Sparkle itself vendors bsdiff (BSD-2-Clause), sais-lite (MIT), a modified copy of ed25519 (Zlib), and `SUSignatureVerifier.m` (BSD-2-Clause). Everything else is an Apple framework that ships with macOS.

Full license texts are in `THIRD-PARTY-NOTICES.md`, which is also bundled into `Thread.app/Contents/Resources/` so the notices travel with every copy of the app.

## License

Thread is licensed under the [Apache License 2.0](LICENSE.txt). Third-party
components keep their own licenses, listed in `THIRD-PARTY-NOTICES.md`.

## Disclaimer

Thread is a personal project I built to learn, shared as-is with no warranty or guarantees of any kind. Use it at your own risk — I'm not responsible for anything that happens as a result of using it, including how you choose to record, store, or share your meetings and notes. Please make sure you have consent before recording others.

**Users are solely responsible for ensuring compliance with applicable local laws, including obtaining necessary consents prior to recording or summarizing audio/meetings.**

This is a personal side project and is not affiliated with, endorsed by, or connected to my employer.
