# Thread

For any feedback or comments, please connect with me on [LinkedIn](https://www.linkedin.com/in/jamesarthurbarker/) or email me at [james.barker@salesforce.com](mailto:james.barker@salesforce.com).

![Thread running a local meeting transcript on macOS](assets/thread-app.gif)

Thread is a private meeting companion for macOS. Start it before a call and it listens, transcribes the conversation live, and helps you turn it into clean notes, summaries, and follow-ups. By default, nothing leaves your Mac.

There's no account and no sign-up. Meetings, notes, and transcripts stay on your Mac unless you optionally bring your own API keys in Setup.

Sessions are plain Markdown files in folders you choose, so your notes stay readable, greppable, and yours.

## Download

**[⬇︎ Download the latest version](https://github.com/salesforce-misc/thread/releases/latest/download/Thread.dmg)**

[See all releases](https://github.com/salesforce-misc/thread/releases)

Open the `.dmg` and drag **Thread** to your Applications folder. The build is notarized, so it opens without a Gatekeeper warning, and it keeps itself up to date automatically after that.

## Features

- **Live transcription** — Captures both your voice and everyone else on the call, transcribed in real time as you talk.
- **Private & offline** — On-device by default. No account, and nothing is uploaded unless you turn on Bring Your Own Keys.
- **Bring Your Own Keys** — Optional. Use your own OpenAI or Anthropic API key for Enhance and Ask, and OpenAI for live transcription. Off by default.
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
- **Apple Notes** — Optional, one-way. Copies a saved session into a Thread folder in Notes (iCloud or On My Mac) and turns the tasks into real checkboxes. No recording files are sent. The next copy replaces anything typed in Notes.

## How it works

**Live transcription of both sides.** The microphone is captured through `AVAudioEngine` and the far end through `ScreenCaptureKit` system-audio capture, each fed to its own on-device transcriber. Entries are labelled `You` or `Meeting`, and audio is converted into 20 ms chunks on an explicit timeline to get lower-latency partial results than macOS's default ~100 ms mic buffers.

**Automatic meeting detection.** `MeetingDetector` polls Chrome's tabs via AppleScript for a real Meet room URL, distinguishes the lobby from a joined call by watching the tab title, and derives a human meeting name to offer one-tap recording.

**Mute-aware capture.** `GoogleMeetMuteMonitor` reads Meet's mute state from the accessibility tree and gates microphone transcription accordingly, so muting yourself in the call stops you being transcribed.

**Speaker attribution.** Off by default as an experimental Setup toggle; without it, transcript lines stay `You` or `Meeting`. When enabled, `SpeakerVisionMonitor` finds the active speaker in the host app's accessibility tree and attributes lines to named participants. Google Meet, Microsoft Teams on the web and in the desktop app, and Zoom on the web are all read from a class marker on the speaking tile. Zoom's desktop app publishes no speaking indicator at all, so it attributes by elimination instead: when exactly one remote participant is unmuted, they are the speaker. Names can be missed or mislabeled.

**Enhance.** Rewrites your rough notes into clean Markdown using the meeting transcript as evidence, and extracts action items with owners — only naming someone when the name appears verbatim, never guessing. Ships with a built-in default prompt, plus your own reusable templates.

**Ask.** A chat over your notes, scoped to one note or your whole library. Notes are chunked and embedded with `NLEmbedding` for semantic retrieval, and the model has tools to search passages, read or summarise a specific note, summarise a topic across many notes, and list or tick off tasks. Answers cite the notes they came from. Asking about a single note is a one-off conversation held in memory — only the transcript and your notes are written to the `.md` file.

**Bring Your Own Keys.** Off by default. When enabled, Enhance and Ask can call OpenAI or Anthropic with a key stored in the Mac Keychain, and live transcription can call OpenAI instead of on-device speech. Audio and notes then go to the provider you chose, billed to your account.

**Learned glossary.** When Enhance sees that your notes spell a name or term differently from the transcript, it proposes a correction. Accepted terms persist per-user in Application Support and are applied to future transcripts, so Thread learns your jargon and your colleagues' names.

**Rich text notes.** A Markdown-backed editor with headings, bold/italic/strikethrough, links, bullet and numbered lists, and checkbox tasks, driven by the Format menu and the usual shortcuts.

**Full-library search.** An in-memory index over every note's title, notes, and transcript, rebuilt off the main thread and filtered live as you type.

**Apple Notes.** Optional, one-way copy from Thread into Apple Notes. The Markdown file on your Mac stays the original. Notes is a place to read the copy. The next copy replaces the note, including anything typed there.

No recording file is sent. When you stop a session, or save a summary or tasks, Thread creates a note in a folder named Thread, or updates that note if it is still there. Setup chooses iCloud or On My Mac. The note has four parts: the session title, the summary, the tasks, and the transcript.

The words are written with AppleScript. Notes accepts a small piece of HTML as the note body: headings, paragraphs, and a bullet list. That is enough for the title, the summary, and the transcript. It is not enough for a Notes checklist. A real checklist is the circle you can tap, open or done. That is not an HTML list, and it is not the characters ☐ and ☑︎. Notes stores each checklist row inside the note: the line is marked as a checklist, with its own id, and a flag for open or done. AppleScript never sets that. A task line sent as HTML comes back as a bullet, or as plain text with a ballot box drawn in the letters. Shortcuts for Notes take ordinary text too, so they cannot create the circles. Typing Notes' own checklist shortcut only works while Notes is the frontmost app, and Thread does not bring Notes forward. The script can place the words. It cannot mark those words as a native checklist, and it cannot record which rows are done.

The copy is two steps. First, AppleScript creates or updates the note and sets the body. The task lines are ordinary lines under a Tasks heading, and their text matches the tasks in Thread, including whether each one is open or done. Thread remembers the note's id, so the next copy updates that same note instead of making a duplicate. Second, after the words are saved, Thread quits Notes and edits only the checklist style of those task lines in the Notes database. The wording is left as Notes saved it. Each task line between the Tasks heading and the Transcript heading is matched to a Thread task by its text. A match becomes a real checkbox, open or done to match Thread. Other lines are left alone. Open Notes again to see the circles.

Matching is exact, after trimming space and ignoring a leading ballot box. A blank line is skipped. If a task's text is not on its own line in that section, that task stays as Notes saved it, and Thread tells you which line did not match.

The checklist marks live in `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite`. macOS treats that file as private. An app cannot read or write it until you turn on Full Disk Access for Thread. There is no popup. In System Settings, go to Privacy & Security, then Full Disk Access, and turn Thread on. Thread uses that permission for this file only, and only to mark the tasks in the note it just copied. The summary and the transcript are still written by AppleScript, which uses the separate Automation permission for Notes. If Full Disk Access is off, the note is still copied. The tasks just do not become circles. The permission is tied to the app named Thread. A copy named Thread Dev is a different app, and a new install can need the switch turned on again.

Notes keeps the script's version of the note in memory. If Thread marks the checkboxes while Notes is still open, Notes can save the bullet version back over them, and the circles disappear. Quitting Notes lets that save finish. Thread then marks the task lines while nothing else is writing the database. That quit happens on every copy. Open Notes again afterward.

This does not read your other notes, and it does not edit them. A check, a new row, or a deletion in Notes is replaced the next time Thread copies. The database edit does not change the words of the note. Only the checklist style of the matching task lines changes. Changing the text there would corrupt the note, because Notes tracks those characters separately from the style. Only lines in the Tasks section are marked, from the Tasks heading down to the Transcript heading.

## Requirements

- **macOS 26 (Tahoe) or later.** Thread is built on frameworks that ship with macOS 26: `FoundationModels` for the on-device LLM, `SpeechAnalyzer`/`SpeechTranscriber` for streaming speech recognition, and Liquid Glass for the UI.
- **An Apple Intelligence–capable Mac** (Apple silicon, M1 or later) for on-device Enhance and Ask. Transcription and note-taking work without it. Bring Your Own Keys can run Enhance and Ask through OpenAI or Anthropic instead.
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

macOS will prompt on first use. Each is requested only when the corresponding feature runs. Full Disk Access is the exception: macOS does not prompt, so Thread has to be turned on by hand.

| Permission | Why |
| --- | --- |
| Microphone | Transcribing your own speech |
| Screen Recording | `ScreenCaptureKit` system-audio capture of the other participants |
| Automation (Chrome) | Reading tab URLs to detect an active Meet call |
| Automation (Notes) | Optional copy of a saved session into Apple Notes |
| Full Disk Access | Optional. Marks tasks in that note as real checkboxes. macOS does not prompt; turn Thread on under Privacy & Security |
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
| `Thread/BringYourOwnLLM.swift` | Setup: Bring Your Own Keys, Keychain storage, key verify |
| `Thread/OpenAIChat.swift` | OpenAI Chat Completions for Enhance and Ask |
| `Thread/ClaudeChat.swift` | Anthropic Messages API for Enhance and Ask |
| `Thread/OpenAITranscription.swift` | Optional OpenAI live transcription |
| `Thread/Glossary.swift` | Learned vocabulary and transcript correction |
| `Thread/SessionStore.swift` | Library folders, Markdown read/write, autosave |
| `Thread/NotesSync.swift` | Optional one-way copy of a session into Apple Notes |
| `Thread/NotesChecklistWriter.swift` | Turns the copied task lines into native Notes checkboxes |
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

By default everything runs locally. Speech recognition uses on-device models, note enhancement and Ask use Apple's on-device foundation model, and embeddings come from `NaturalLanguage`.

Two things always reach the network, neither carrying your content: macOS downloads the speech recognition model assets from Apple the first time you record in a new language, and Sparkle fetches the appcast to check for updates.

If you turn on **Bring Your Own Keys**, notes and/or audio are sent to OpenAI or Anthropic using a key you paste. That usage is billed to your account. Keys are stored in the Mac Keychain; removing one from Thread does not revoke it at the provider. With both toggles off, your audio, transcripts, and notes never leave your Mac.

Apple Notes sync writes the session text into Notes on this Mac. It does not include recording files. If that Notes account is iCloud, Apple syncs the note the same way it syncs your other notes.

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
