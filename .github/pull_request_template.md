<!--
Thanks for contributing to Jotty! Please read CONTRIBUTING.md if you haven't.
Keep the PR focused on one change.
-->

## What this changes

A short description of the change and the behaviour it affects.

## Why

The problem it solves or the reason for the change. Link any related issue
(`Fixes #123`).

## How it was tested

Jotty is test-first - describe the tests that cover this change.

- [ ] Added/updated tests in `JottyTests` for the new behaviour
- [ ] Ran the suite locally:
      `xcodebuild test -scheme Jotty -destination 'platform=macOS' -skip-testing:JottyTests/CrossProviderTests`
- [ ] Ran `xcodegen generate` (if I added/removed/renamed source files)

## Privacy & security impact

- [ ] Does **not** break the zero-network default (default = Apple FoundationModels
      + local markdown makes no outbound requests)
- [ ] Does **not** write any API key / token anywhere other than the Keychain
- [ ] If this adds a network destination, it's user-opt-in and documented in the
      README endpoints table
- [ ] N/A - no privacy/security surface touched

## Checklist

- [ ] Branched off `main`, focused on a single change
- [ ] Preserves the additive task-line token model (old day files still parse)
- [ ] Commit messages are in the imperative mood
- [ ] I have read and agree to the [Code of Conduct](../CODE_OF_CONDUCT.md)
