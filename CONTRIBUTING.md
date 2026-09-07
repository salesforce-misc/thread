# Contributing Guide For Thread

This page lists the operational governance model of this project, as well as the
recommendations and requirements for how to best contribute to Thread. We strive to
obey these as best as possible. As always, thanks for contributing – we hope these
guidelines make it easier and shed some light on our approach and processes.

# Governance Model

## Salesforce Sponsored

The intent and goal of open sourcing this project is to increase the contributor and
user base. However, only Salesforce employees will be given `admin` rights and will be
the final arbitrars of what contributions are accepted or not.

# Getting started

Thread is a macOS app, so contributing needs a fairly specific setup. You will need
macOS 26 or later, Xcode 26, and an Apple Intelligence–capable Mac. Several of Thread's
core features depend on frameworks that only exist on macOS 26 (`FoundationModels`,
`SpeechAnalyzer`), so there is no way to build or meaningfully test on an older system.

```bash
brew install xcodegen   # only needed if you change project.yml
xcodegen generate
open Thread.xcodeproj
```

Build and run the `Thread` scheme. Debug builds install under a separate bundle
identifier (`com.thread.app.dev`) so they can sit alongside a release install, and they
skip Sparkle entirely.

`project.yml` is the source of truth for the Xcode project. `Thread.xcodeproj` is
committed for convenience, but edit the YAML and regenerate rather than changing build
settings in Xcode, or your change will be lost the next time someone runs `xcodegen`.

# Issues, requests & ideas

Use GitHub Issues page to submit issues, enhancement requests and discuss ideas.

### Bug Reports and Fixes

- If you find a bug, please search for it in the
  [Issues](https://github.com/salesforce-misc/thread/issues), and if it isn't already
  tracked, [create a new issue](https://github.com/salesforce-misc/thread/issues/new).
  Even if an Issue is closed, feel free to comment and add details, it will still be
  reviewed.
- Issues that have already been identified as a bug (note: able to reproduce) will be
  labelled `bug`.
- If you'd like to submit a fix for a bug, [send a Pull Request](#creating-a-pull-request)
  and mention the Issue number.

Please include your macOS version, whether the Mac supports Apple Intelligence, and which
meeting platform you were using. For transcription problems, note whether the issue
affected your microphone, the far end, or both, since those are separate capture paths.

Do not attach recordings, transcripts, or notes to an issue. Thread is built so that this
content never leaves your machine, and a bug report is not a good reason to break that.

### New Features

- If you'd like to add new functionality to this project, describe the problem you want to
  solve in a [new Issue](https://github.com/salesforce-misc/thread/issues/new).
- Issues that have been identified as a feature request will be labelled `enhancement`.
- If you'd like to implement the new feature, please wait for feedback from the project
  maintainers before spending too much time writing the code. In some cases,
  `enhancement`s may not align well with the project objectives at the time.

### Tests, Documentation, Miscellaneous

- If you'd like to improve the tests, you want to make the documentation clearer, you have
  an alternative implementation of something that may have advantages over the way it's
  currently done, or you have any other change, we would be happy to hear about it!
  - If it's a trivial change, go ahead and [send a Pull Request](#creating-a-pull-request)
    with the changes you have in mind.
  - If not, [open an Issue](https://github.com/salesforce-misc/thread/issues/new) to
    discuss the idea first.

# Contribution Checklist

- [x] Clean, simple, well styled code. Match the surrounding code: the codebase leans on
      Swift concurrency and SwiftUI, and keeps view state close to the views that use it.
- [x] Commits should be atomic and messages must be descriptive. Related issues should be
      mentioned by Issue number.
- [x] Comments
  - Module-level & function-level comments.
  - Comments on complex blocks of code or algorithms (include references to sources).
- [x] Dependencies
  - Minimize number of dependencies. Sparkle is the only third-party library, and that is
    deliberate. If a change would add another, please open an issue to discuss it first,
    since every new dependency has to go through licence review.
  - Prefer Apache 2.0, BSD3, MIT, ISC and MPL licenses.
- [x] Reviews
  - Changes must be approved via peer code review.

Anything touching accessibility inspection of Google Meet or Microsoft Teams is inherently
fragile, because it reads another application's UI tree. Those changes need to be tested
against a live call; the Debug menu has probes for dumping the tree.

# Creating a Pull Request

1. **Ensure the bug/feature was not already reported** by searching on GitHub under Issues.
   If none exists, create a new issue so that other contributors can keep track of what you
   are trying to add/fix and offer suggestions (or let you know if there is already an
   effort in progress).
2. **Clone** the forked repo to your machine.
3. **Create** a new branch to contain your work (e.g. `git br fix-issue-11`)
4. **Commit** changes to your own branch.
5. **Push** your work back up to your fork. (e.g. `git push fix-issue-11`)
6. **Submit** a Pull Request against the `main` branch and refer to the issue(s) you are
   fixing. Try not to pollute your pull request with unintended changes. Keep it simple and
   small.
7. **Sign** the Salesforce CLA (you will be prompted to do so when submitting the Pull
   Request)

> **NOTE**: Be sure to [sync your fork](https://help.github.com/articles/syncing-a-fork/)
> before making a pull request.

# Contributor License Agreement ("CLA")

In order to accept your pull request, we need you to submit a CLA. You only need to do this
once to work on any of Salesforce's open source projects.

Complete your CLA here: <https://cla.salesforce.com/sign-cla>

# Security issues

Please do not open a public issue. See [SECURITY.md](SECURITY.md).

# Code of Conduct

Please follow our [Code of Conduct](CODE_OF_CONDUCT.md).

# License

By contributing your code, you agree to license your contribution under the terms of our
project [LICENSE](LICENSE.txt) and to sign the
[Salesforce CLA](https://cla.salesforce.com/sign-cla)
