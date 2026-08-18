# Security Policy

## Reporting a vulnerability

Please do not report security issues through public GitHub issues.

Report any security issue to [https://www.sfdc.co/SubmitVuln](https://www.sfdc.co/SubmitVuln)
as soon as it is discovered. Include what you found, how to reproduce it, and what
you think the impact is.

This project limits its runtime dependencies in order to reduce the total cost of
ownership as much as can be, but all consumers should remain vigilant and have their
security stakeholders review all third-party products (3PP) like this one and their
dependencies.

## Supported versions

Only the most recent release is supported. Thread auto-updates through Sparkle,
so users on older versions should update before reporting.

## What is worth reporting

A few areas matter more than others, given how Thread works.

Thread runs **without the App Sandbox**, because inspecting another
application's accessibility tree is incompatible with it. Hardened runtime is
enabled and the entitlements grant only audio input, Apple Events, and
user-selected file access. Anything that widens that surface is worth reporting.

Thread holds **microphone, screen recording, accessibility, and Apple Events
permissions**. It uses screen recording only to capture system audio and
accessibility only to read Meet's mute state and active speaker. Any path that
uses these for something else is a serious issue.

Updates are delivered by **Sparkle** and verified with an EdDSA signature; the
public key is `SUPublicEDKey` in `Info.plist`. Anything that would let an
attacker deliver an unsigned or substituted update is critical.

Notes and transcripts are stored as **plain Markdown** in folders the user
chooses, reached through security-scoped bookmarks. Thread contains no
networking code of its own, and audio, transcripts, and notes are never
transmitted. Any behaviour that contradicts that is a bug worth reporting.

## Out of scope

Thread deliberately stores notes unencrypted, as plain Markdown files, so they
remain readable and greppable outside the app. Local file permissions are the
protection there; this is a design decision, not a vulnerability.
