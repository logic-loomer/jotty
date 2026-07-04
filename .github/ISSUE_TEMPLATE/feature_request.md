---
name: Feature request
about: Suggest an idea or improvement for Jotty
title: "[Feature] "
labels: enhancement
assignees: ''
---

## The problem

What are you trying to do that Jotty makes hard or impossible today? Describe the
situation, not just the solution.

## Proposed idea

What you'd like to see. If it touches capture syntax, tasks, calendar, the inbox,
providers, or the command bar, say which.

## How it fits Jotty's design

Jotty has a few load-bearing invariants - please note how your idea sits with
them (or flag if it deliberately challenges one):

- **Zero-network default** - the default config makes no outbound requests.
- **Disk is the source of truth** - tasks/notes are per-day markdown files;
  calendar/inbox/AI are best-effort layers on top.
- **Secrets in the Keychain only** - no keys/tokens on disk.
- **Additive task-line tokens** - new metadata is additive so old files still
  parse.

## Alternatives considered

Any workarounds you use today, or other approaches you thought about.

## Additional context

Mockups, links, or examples.
