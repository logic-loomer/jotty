# Contributing to Jotty

Thanks for your interest in Jotty, an open-source macOS quick-capture app. This
guide covers how to build, test, and land a change. By participating you agree to
follow our [Code of Conduct](CODE_OF_CONDUCT.md).

## Prerequisites

- **macOS 26.0 or newer.** The default on-device extraction path uses Apple
  Intelligence / FoundationModels, which is macOS 26-only, and the test bundle
  injects into a host app built against `MACOSX_DEPLOYMENT_TARGET = 26.0` (a host
  OS older than the deployment target refuses to launch it).
- **Xcode 16+** (Xcode 26 recommended).
- **XcodeGen** - the `.xcodeproj` is generated from `project.yml`, not checked in
  by hand: `brew install xcodegen`.

## Build

```bash
git clone https://github.com/logic-loomer/jotty.git
cd jotty
xcodegen generate     # regenerate Jotty.xcodeproj from project.yml
xcodebuild -scheme Jotty -destination 'platform=macOS' build
```

Re-run `xcodegen generate` any time you add, remove, or rename source files. Do
not hand-edit `Jotty.xcodeproj` - it is a build artifact; edit `project.yml`
instead.

## Test

The full suite runs on every push and PR (see `.github/workflows/ci.yml`). Run it
locally the same way CI does:

```bash
xcodebuild test \
  -scheme Jotty \
  -destination 'platform=macOS' \
  -skip-testing:JottyTests/CrossProviderTests
```

`CrossProviderTests` exercises the cloud AI providers and needs API keys, so it is
excluded from the default run. Contributors without keys stay unblocked - those
legs skip cleanly. To run the cross-provider sweep yourself, see the
[Evaluation](README.md#evaluation) section of the README.

Apple FoundationModels suites legitimately `XCTSkip` on machines without Apple
Intelligence (including hosted CI runners). That is expected - gate on the
`xcodebuild` exit status, not on a zero-skip count.

## Test-driven development

Jotty is written test-first, and we ask contributions to follow the same rhythm:

1. **Red** - write a failing test that captures the behaviour you want.
2. **Green** - write the minimum code to make it pass.
3. **Refactor** - clean up with the suite green.

Every behaviour change ships with a test. Bug fixes start with a test that
reproduces the bug. The `JottyTests` folder mirrors the app's structure; put new
tests next to the closest existing group (e.g. `AI/`, `Calendar/`, `Inbox/`,
`Settings/`). Prefer testing through the existing seams - services like
`CalendarService` are protocol-backed so tests run against fakes and never touch
your real calendar, Keychain, or the network.

## Architecture conventions

A few invariants the codebase depends on - please preserve them:

- **Zero-network default.** The default config (Apple FoundationModels + local
  markdown) must make no outbound network requests during a
  capture → extract → commit → rollover cycle. `PrivacyDefaultTests` enforces
  this; do not add a code path that breaks it.
- **Disk is the source of truth.** Tasks and notes live in per-day markdown files.
  Calendar, inbox, and AI features are best-effort layers on top - a failure there
  must never roll back or block the markdown write.
- **Additive task-line tokens.** Task metadata (`due:`, `time:`, `cal_event:`,
  `recur:`, `snooze:`, `source:`, …) is additive so older day files keep parsing.
  Add new tokens; don't repurpose existing ones.
- **Secrets in the Keychain only.** API keys and the GitHub PAT are stored in the
  macOS Keychain, never in `config.json`, UserDefaults, or any file on disk.

## Pull requests

- Branch off `main`; keep a PR focused on one change.
- Make sure `xcodegen generate` was run if you touched the file layout, and that
  the local test command above passes before you push.
- Fill in the [pull request template](.github/pull_request_template.md): what
  changed, why, how you tested it, and any privacy/security impact.
- CI (build + test on macOS 26) must be green. Reviews focus on correctness, test
  coverage, and the architecture invariants above; expect review comments and a
  back-and-forth before merge - that is the normal culture here, not a sign
  anything is wrong.
- Write clear commit messages in the imperative mood ("Add snooze token parsing",
  not "added snooze").

## Reporting bugs and requesting features

Use the [issue templates](.github/ISSUE_TEMPLATE). For anything security-sensitive
(API keys, Keychain, the network posture) do **not** open a public issue - follow
[SECURITY.md](SECURITY.md) instead.
