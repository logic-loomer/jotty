---
title: Jotty — v1 Design
project: jotty
type: design-spec
status: approved
created: 2026-05-08
tags: [project/jotty, design, macos, swift, ai]
---

# Jotty — v1 Design

## What it is

A native macOS quick-capture app. Hit a global hotkey, brain-dump in plain language, and an AI quietly extracts tasks (with optional times, due dates, and calendar blocks) into today's list. Incomplete tasks roll to tomorrow. Open source, runs on any Mac, $0 to use.

The bedrock principle: **zero syntax, zero formatting, zero prefixes**. Bullets, prose, run-on sentences, half-thoughts, typos — all valid input. The user types like a human; the AI does the structuring.

## Goals

- A capture loop so fast it replaces the urge to remember things
- Reliable, local-first storage as plain markdown — your data is yours, in a folder, forever
- AI is swappable: a built-in default that needs nothing, plus the option to swap in any cloud provider
- Calendar integration that feels native: type `1–2pm setup laptop`, get a real calendar block
- A clean foundation for phase 2 features (proactive AI, integrations) without rewriting v1

## Non-goals (v1)

- Proactive AI ("you have a meeting at 2, here are prep tasks")
- Email / Slack triggers or auto-suggested tasks
- Two-way sync to Reminders, Things, TickTick, or other task apps
- Mobile app or iCloud sync — markdown folder is canonical; users sync the folder via iCloud Drive / Dropbox / git themselves
- Collaborative or shared lists
- Analytics, telemetry, or any network calls beyond user-configured AI providers
- Paid tier — single open-source binary, BYO API keys for cloud providers

## Stack & distribution

- **Swift / SwiftUI**, native macOS app, single Xcode project
- **Apple Foundation Models** (macOS 26+) as the default on-device AI; falls back to Ollama on older systems
- **EventKit** for calendar read + write
- **macOS Keychain** for API keys
- **Markdown files on disk** as the source of truth — no database
- **Distribution:** GitHub repo (location TBD by user). Pre-built `.app` published as a release; users either build from source or run a one-line `xattr` to dequarantine the unsigned binary. Notarized build optional later if Apple Developer Program ($99/yr) is funded. Distribution-agnostic for now.
- **License:** MIT (assumed; confirm before first commit)

## Architecture

One Xcode project, organized as focused modules. Each has one responsibility, communicates through a narrow interface, and is testable in isolation.

```
Jotty.app
├── JottyApp                  // SwiftUI App entry, scene config
├── Capture/                  // popup window + state machine (input → review)
├── Menubar/                  // NSStatusItem, dropdown view, today's list
├── Store/                    // markdown read/write, daily file resolver, rollover
│   └── MarkdownDoc.swift     // parse/serialize one day's file
├── AI/                       // provider abstraction
│   ├── AIProvider.swift      // protocol
│   ├── AppleFM.swift         // Foundation Models
│   ├── Ollama.swift          // local HTTP
│   ├── Claude.swift          // Anthropic API
│   ├── OpenAI.swift
│   └── Gemini.swift
├── Calendar/                 // EventKit read + write
├── ClaudeAction/             // "Send to Claude" handoff
├── Hotkey/                   // global hotkey registration
├── Keychain/                 // API key storage
├── Launch/                   // SMAppService launch-at-login
└── Settings/                 // SwiftUI settings window
```

**Boundary rules:**

- `AIProvider` protocol is the only seam between AI and the rest of the app. Adding a new provider is an isolated addition; nothing outside `AI/` changes.
- `Store` owns all disk I/O. Nothing else touches files directly.
- `Capture` doesn't know about AI internals — it asks `AI/` to extract, gets `[ExtractedTask]` back, hands the accepted set to `Store`.
- The menubar list view is a thin reactive layer over `Store`, observing today's file.
- All keystrokes in `Capture` and `Menubar` are dispatched as named actions (e.g. `submit`, `back`, `toggleTask`), not bound directly to keys. Keybindings resolve action → key combo at the input layer.

## User flows

### 1. Capture (the moment that happens 20+ times a day)

1. User presses the global hotkey (default ⌘N, configurable). Popup appears in <50ms, focused, ready to type. Position is configurable; default is centered on the active display (the one with the cursor).
2. User types a brain dump. Plain language. Any format.
3. User presses ⌘↩ (configurable: `submit`). Popup transitions in place to **Review** state — same window, no flicker.
4. AI runs against the note text and the current local timestamp. Returns a structured list of `ExtractedTask`s. A small spinner is visible during the call.
5. Review state shows each task as a checkbox row with metadata badges (`📅 due Fri`, `📅 today 1–2pm`, `[✓] block calendar`). All checked by default.
6. User navigates with ↑↓ (configurable), toggles with space (configurable), or edits a row inline.
7. User presses ⌘↩ again (`commit`). Accepted tasks land in today's markdown file; calendar events are created for any task with `block calendar` checked. Popup closes.
8. Toast confirms: "3 tasks added · 1 calendar event created · ⌘Z to undo" (undo support is v1 stretch — see open questions).

**Recovery:**

- Note text autosaves to a draft file on every keystroke. If the popup is dismissed (⎋) or the app crashes mid-capture, opening the popup again restores the draft.
- AI failure → inline error toast; user can still commit the raw note as-is to today's `## Notes` section with no extracted tasks.
- Time-conflict detection: if a calendar-block overlaps an existing event, warn before commit ("⚠️ overlaps with 'Standup' — commit anyway?").

**Capture popup states:**

```
┌─ Jotty ──────────────────────────── ⎋ ┐
│  email Jamie about Q2 plan            │
│  block 1-2pm setup laptop             │
│  domain renewal due Friday            │
│  prod logs after lunch                │
│                                       │
│                       ⌘↩ extract ›    │
└───────────────────────────────────────┘
                  Input
```

```
┌─ Jotty — review ──────────────────── ⎋ ┐
│  Tasks extracted (4):                  │
│                                        │
│  ☑ Email Jamie about Q2 plan           │
│  ☑ Setup laptop          📅 today 1–2p │
│       └─ blocks calendar  [✓]          │
│  ☑ Renew domain          📅 due Fri    │
│  ☑ Check prod logs       (today)       │
│                                        │
│  ↑↓ navigate · space toggle            │
│              ⌫ back      ⌘↩ commit ›   │
└────────────────────────────────────────┘
                  Review
```

### 2. List & menubar

A `📝` icon in the top menubar. Click → dropdown:

```
┌─ Jotty · Fri May 8 ───────────────┐
│  3 of 7 done                      │
├───────────────────────────────────┤
│ Today                             │
│  ☐ Email Jamie about Q2 plan      │
│  ☐ Setup laptop      1–2pm        │
│  ☑ Standup notes                  │
│  ☐ Renew domain      due Fri      │
│  ☐ Check prod logs                │
│                                   │
│ Calendar (read-only)              │
│  · 9:00  Standup                  │
│  · 14:30 1:1 w/ Pat               │
├───────────────────────────────────┤
│  ⌘N Capture …      ⌘, Settings    │
└───────────────────────────────────┘
```

- Click a checkbox → toggles done; line strikethroughs in place
- Click a task title → small inline editor (rename, change due, etc.)
- Right-click task → menu: Send to Claude · Delete · Move to tomorrow · Open day file
- Calendar events are read-only with a `·` bullet (no checkbox); click → opens Calendar.app
- Optional badge on the menubar icon shows undone task count (Settings → General)

### 3. Daily rollover

- **Triggers:** at app launch each day; and at midnight if the app is running (a `Timer` scheduled to next midnight)
- **For each unchecked `- [ ]` in yesterday's file:** copy to today's `## Tasks`, preserve its task ID and metadata, leave the original line in yesterday's file with a `<!-- rolled_to:2026-05-08 -->` marker so history is intact
- **Tasks with `due:` in the future** stay in their original day's file until the due date arrives, then roll
- A "Yesterday's leftovers" section appears briefly in today's menubar with subtle styling so the user notices what carried over (collapses after first interaction)

### 4. Calendar integration (read + write, v1)

- **Read:** today's events from EventKit appear in the menubar list (read-only, click → Calendar.app)
- **Write:** any extracted task with a time block creates a real calendar event on commit
- **Default calendar:** chosen in Settings → Calendar; defaults to the user's primary calendar
- **Two-way link:** the calendar `eventID` is stored in the task's metadata so the two stay paired
  - Toggle task done in Jotty → calendar event left alone (you still attended)
  - Delete task in Jotty → asks once: "also delete the calendar event?", remembers the answer
  - Edit task time in Jotty → updates the calendar event in place
  - Edit event in Calendar.app → on next Jotty open, drift is detected and the user is prompted to sync
- **Permissions:** first calendar-creating commit triggers macOS's Calendar write permission prompt
- **Conflict warning:** before commit, if any new event overlaps an existing event, show "⚠️ overlaps with '<title>' — commit anyway?"

### 5. Send to Claude

- **Where it appears:** right-click any task or note → **Send to Claude**; or ⌘K with task selected (configurable)
- **What it sends:** the task title plus context (the note it came from, plus today's other tasks if relevant)
- **Two delivery modes** (Settings → AI → Claude action):
  - **Claude.ai web** — opens `claude.ai/new?q=…` with the prompt prefilled. No API key required.
  - **Claude Code** — runs `claude "$(prompt)"` via terminal handoff. Useful for users who live in CC.
- **v1 simplification:** fire and forget. The Claude response lives in Claude, not stored back into Jotty. Phase 2 hook: a "Claude reply" surface inside Jotty that pipes the task to the API and shows the response inline.

## Data model

### Daily markdown file

Path: `<storage-folder>/<YYYY-MM-DD>.md` — defaults to `~/Documents/Jotty/`, configurable to any folder including the user's Obsidian vault.

```markdown
---
date: 2026-05-08
created: 2026-05-08T07:30:00+10:00
---

## Tasks

- [ ] Email Jamie about Q2 plan <!-- id:t_a1b2 -->
- [ ] Setup laptop <!-- id:t_a1b3 time:13:00-14:00 cal_event:E47A2... -->
- [x] Standup notes <!-- id:t_a1b4 done:2026-05-08T09:30 -->
- [ ] Renew domain <!-- id:t_a1b5 due:2026-05-09 -->
- [ ] Check prod logs <!-- id:t_a1b6 source_note:n_001 -->

## Notes

### 07:30 <!-- id:n_001 -->
ok so today need to email Jamie re Q2 plan, also block 1-2pm to setup laptop...
```

**Why HTML comments for metadata:** keeps files clean and Obsidian-readable; the visible markdown is exactly what a human would write. Comments are stripped by readers but parsed by Jotty for stable IDs and structured fields.

**Task metadata fields:**

| key | type | meaning |
|---|---|---|
| `id` | `t_<base32>` | stable task ID, generated on creation |
| `time` | `HH:MM-HH:MM` | local time block; presence implies calendar event |
| `due` | `YYYY-MM-DD` | due date without time; affects rollover |
| `cal_event` | EventKit eventID | linkage to the calendar event, if created |
| `done` | ISO timestamp | completion timestamp; presence + `[x]` means done |
| `source_note` | `n_<id>` | the note this task was extracted from |
| `rolled_to` | `YYYY-MM-DD` | set on the original line when rolled forward |

### ExtractedTask (in-memory)

```swift
struct ExtractedTask {
    let title: String
    let dueDate: Date?         // "by Friday"
    let timeBlock: TimeBlock?  // start + end, both local
    let calendarBlock: Bool    // create a calendar event? defaults to true if timeBlock != nil
}

struct TimeBlock {
    let start: Date
    let end: Date
}
```

## AI provider abstraction

```swift
protocol AIProvider {
    var id: String { get }              // "apple-fm", "ollama", "claude", ...
    var displayName: String { get }
    var isAvailable: Bool { get async } // checks reachability / model loaded

    func extractTasks(
        from text: String,
        now: Date,                       // local current time, anchors "tomorrow", "1pm"
        timezone: TimeZone
    ) async throws -> [ExtractedTask]
}
```

- **Default:** `AppleFM` on macOS 26+ Apple Silicon. Uses `@Generable` types for structured output, ~zero RAM overhead, no install.
- **Fallback:** `Ollama` on older systems or non-Apple-Silicon. Talks HTTP to `localhost:11434`. Default model `qwen2.5:3b` (configurable). Surfaces a setup hint in onboarding if Ollama isn't installed.
- **Cloud providers:** `Claude`, `OpenAI`, `Gemini`. JSON-mode / structured outputs. API keys via Keychain.
- **Failure handling:** unreachable provider → inline toast with the specific error + offer to fall back to Apple FM for this single capture.

**Prompt requirements** (any provider):

- Anchor "today", "tomorrow", "this afternoon", weekday names against the supplied `now` and `timezone`
- Detect time blocks: `1-2pm`, `from 9 to 11`, `for an hour starting at 3` — return as `TimeBlock`
- Detect due dates: `by Friday`, `due tomorrow`, `before EOM` — return as `dueDate`
- Default `calendarBlock = true` whenever a `timeBlock` is present (user's chosen default)
- Ignore non-actionable text (observations, feelings, context) unless it clearly implies a task
- Tolerate any phrasing — bullets, prose, run-ons, typos, lowercase, missing punctuation

**Tunable in Settings → AI → Advanced:**

- Custom extraction prompt (overrides default)
- Temperature (default 0.2)
- Per-provider model selection

**Test fixtures.** A curated set of natural-phrasing samples (10–20 examples) lives at `Tests/Fixtures/extraction/` in the repo, paired with expected `[ExtractedTask]` outputs. CI runs them against each provider implementation. Swapping providers must not regress the feel of extraction.

## Configuration

A single, unified configuration surface — all settings live in one place, both UI and JSON.

**Locations:**

- UI: Settings window (⌘, from menubar) — sidebar tabs for General · Storage · AI · Calendar · Keybindings · Advanced
- Disk: `~/Library/Application Support/Jotty/config.json` — power users can hand-edit and version-control
- Keybindings: `~/Library/Application Support/Jotty/keybindings.json` — same, separated for clarity
- API keys: macOS Keychain (never on disk in plaintext)

**All defaults are configurable.** This is a hard requirement, not a polish item. Notably:

- Global hotkey
- Every keystroke in capture and menubar (submit, commit, back, cancel, toggle, navigate, send-to-Claude)
- Storage folder path (with quick "use my Obsidian vault" preset)
- AI provider, model, temperature, prompt
- Default calendar for new events
- Conflict-warning behavior, calendar-event-on-task-delete behavior
- Launch at login (default: prompted on first run)
- Capture popup position on screen (default: centered)
- Menubar count badge on/off
- Notification sound and theme (System / Light / Dark)

**Action-based keybindings.** Capture and menubar listen for actions (`submit`, `back`, `toggleTask`, …), not raw keys. Adding or rebinding a key never touches feature code. Conflict detection warns when two actions resolve to the same key combo. Reset-to-defaults button.

## Launch & lifecycle

- **Launch at login** via `SMAppService.mainApp.register()` (macOS 13+). No deprecated LaunchAgent plists.
- **Headless launch** — no dock icon, no window — just menubar icon and global hotkey listener
- **Resource shape at idle:** ~10–15 MB RAM, 0% CPU. Wakes only on hotkey press, menubar click, or midnight rollover.
- **Quitting (⌘Q)** stops the session cleanly without disabling the launch-at-login preference
- **Onboarding** on first launch: a single-screen welcome that requests Calendar permission, prompts for launch-at-login, and links to a 30-second walkthrough of capture

## Privacy & security

- **Default config (Apple FM + local markdown) makes zero network requests, ever.** This is the headline.
- Switching to a cloud AI provider sends only the capture text to that provider; Jotty never logs or relays it elsewhere
- Calendar access is local via EventKit; no calendar data is transmitted anywhere
- API keys stored in macOS Keychain (`kSecClassGenericPassword`, app-scoped, not synced)
- No analytics, no telemetry, no auto-update phone-home (manual update via GitHub releases)
- All network requests scoped to the user-selected provider's API endpoint; surfaced in Settings → AI for transparency

## Testing strategy

- **Unit tests** per module: `Store` (markdown round-trip, rollover logic, ID stability), `AI/<provider>` (each provider stubs the network and verifies request shape + parsing of structured output), `Calendar` (EventKit interactions mocked via a thin protocol seam), `Hotkey` (registration / cleanup), keybindings JSON parse + conflict detection.
- **Extraction fixture suite** (described above under AI provider abstraction) — runs against every real provider in CI when API keys are present, and against Apple FM / Ollama locally on developer machines.
- **End-to-end capture test** (XCTest UI test): spawn app, simulate hotkey, type a fixture string, assert popup transitions and resulting markdown file content.
- **Manual smoke checklist** in the README for releases — capture, rollover, calendar create, calendar conflict, provider switch, restart-from-cold.

## Phase 2+ parking lot

Captured here so we don't lose them, but explicitly out of v1:

- Proactive AI: "you have a meeting at 2, here are prep tasks based on the calendar event"
- Email / Slack triggers that surface as suggested tasks (now formalized in **Phase 7 — Unified Inbox**)
- "Claude reply" inline surface (currently fire-and-forget)
- Snooze tasks to a specific date (beyond simple due-date)
- Drag-reorder tasks in the menubar; Kanban-style "today / later" split
- Persistent floating window option (alternative to menubar dropdown)
- Auto-update mechanism (Sparkle)
- Notarized signed builds + DMG installer
- Cross-platform port (Linux/Windows) via Tauri shell — speculative

## Long-term vision: open-source Akiflow

Akiflow ($14.99/mo) is the inspiration for where Jotty heads after Phase 6. Three new phases extend the vision:

### Phase 7 — Unified Inbox

Pull "actionables" from where they live into Jotty's list:

- **GitHub:** assigned issues, mentioned-in PR/issue, review-requested
- **Gmail:** starred / labeled threads (OAuth, read-only)
- **Slack:** saved messages, mentions in starred channels (Slack OAuth + scopes)
- **Linear / Shortcut / Jira:** assigned tickets
- **Notion:** assigned pages from a target database

Each integration is a separate provider (similar pattern to AI provider abstraction): a protocol + per-source implementation. Inbox items are first-class Jotty tasks with a `source: <integration>:<id>` metadata field, deep-link back to the original. Sync is pull-on-demand and on a schedule (background timer; configurable interval per integration). Auth via macOS Keychain.

### Phase 8 — Calendar power-UX

Builds on Phase 5's read+write calendar:

- **Drag-to-time-block:** drop any task onto a calendar slot to convert it into a real calendar event with linked task
- **Recurring tasks:** rrule-based (daily, weekdays, weekly Mon/Wed/Fri, etc.)
- **Snooze to specific time** ("snooze until Tomorrow 9am" / "next Monday")
- **Calendar canvas view:** dedicated window showing today's calendar with available focus slots highlighted. Akiflow's headline UX.

### Phase 9 — Command Bar

A universal `⌘K` palette à la Linear / Raycast / Akiflow's command bar:

- Fuzzy search across tasks, days, integrations, settings
- Quick actions: snooze, send to Claude, open source, delete, complete
- Keyboard-only navigation; `Tab` to drill into actions
- Plugin-friendly: each integration registers commands

These three phases turn Jotty from "personal capture app" into "free, open-source command center for your work" — same value as Akiflow, no $14.99/mo, fully local-first with optional cloud AI.

## Open questions for the implementation plan

These don't block the spec, but the plan author should resolve before coding:

1. **Undo for capture commit.** Toast says "⌘Z to undo" — is that v1 or stretch? Implementation: keep the pre-commit state in memory for ~30s, on undo reverse the file write and delete any created calendar event. Simple but adds code paths.
2. **Inline rename of task** in the menubar — does it edit the markdown file directly, or open a small inline field that writes on blur?
3. **Markdown writer concurrency** — what happens if the user has the day's file open in Obsidian and Jotty wants to write? Strategy: file lock + diff merge, or watch-and-reconcile. Pick before implementing.
4. **First-launch onboarding flow** — exact screens, copy, ordering. Needs a small design pass.
5. **"Yesterday's leftovers" UX** — collapses after first interaction, but what counts as "interacted"? Any click in the dropdown? Toggling one of them?

---

*Approved 2026-05-08. Next step: write the implementation plan.*
