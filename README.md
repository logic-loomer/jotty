# Jotty

[![ci](https://github.com/logic-loomer/jotty/actions/workflows/ci.yml/badge.svg)](https://github.com/logic-loomer/jotty/actions/workflows/ci.yml)

Open-source macOS quick-capture app. Hit a hotkey, brain-dump, your notes land in a markdown file.

**Status:** v1.0 shipped, plus Phase 7 (Unified Inbox). Right-click a task to Send to Claude (web or Claude Code), launch Jotty at login via `SMAppService`, a full seven-tab Settings window with key rebinding, a single-screen first-launch onboarding, the complete menubar context menu with inline rename, a documented privacy audit confirming the zero-network default, and a Unified Inbox that surfaces GitHub items (assigned issues / review-requested PRs, via a Keychain-stored Personal Access Token) as suggested tasks with no background polling by default. Builds on Phase 5 (Calendar integration: time-blocked tasks become real macOS Calendar events with a two-way `cal_event:<id>` link, today's events in the menubar, conflict and drift handling) and Phase 4 (five AI providers behind one protocol, API keys in the macOS Keychain, no-restart switching). Capture → Review → Commit flow.

## Build from source

Requires macOS 26+ and Xcode 16+ (Xcode 26 recommended).

```bash
git clone <repo>            # location TBD
cd jotty
xcodegen generate
xcodebuild -scheme Jotty -destination 'platform=macOS' build
```

Open `Jotty.xcodeproj` in Xcode and run, or copy the built `.app` from `~/Library/Developer/Xcode/DerivedData/.../Build/Products/Debug/Jotty.app` to `/Applications`.

## Running an unsigned `.app`

If you download a pre-built `.app` from a release (when releases exist), macOS will refuse to open it because we don't yet pay for an Apple Developer ID. Remove the quarantine bit:

```bash
xattr -d com.apple.quarantine /Applications/Jotty.app
```

## Default keybindings (Phase 1)

| Action | Default |
|---|---|
| Open capture popup (global) | ⌘N |
| Submit captured note | ⌘↩ |
| Cancel capture (autosaves draft) | ⎋ |
| Send task to Claude | ⌘K |

Rebind any action in **Settings → Keybindings** (record a new combo, with conflict
warnings and reset-to-defaults), or edit
`~/Library/Application Support/Jotty/keybindings.json` directly.

## Storage

Notes are written as markdown files (one per day) to `~/Documents/Jotty/` by default. Change the folder in Settings → Storage. Point at your Obsidian vault if you want.

## Capture syntax (Phase 2)

Lines starting with `- [ ] ` are parsed as tasks. Everything else lands as a note.

Example:

```
quick brain-dump
- [ ] call mom
- [ ] renew domain
follow-up: check prod logs after lunch
```

→ creates two tasks ("call mom", "renew domain"); the note section captures
"quick brain-dump\nfollow-up: check prod logs after lunch".

Click the menubar `📝` icon to see today's tasks; click checkboxes to toggle.
Incomplete tasks roll forward to today's file at app launch and at midnight.

## AI task extraction (Phase 3)

Type a freeform brain-dump, press ⌘↩, and the app silently extracts tasks, due dates, and time blocks using on-device Apple Foundation Models. A Review state appears with rows for each extracted item, showing metadata badges (`📅 today 1–2pm`, `📅 due Friday`). Navigate with ↑↓, toggle rows with space, press ⌘↩ to commit, or ⎋ to return and edit the original text. No network requests. Apple FM is the default and requires macOS 26+; older systems fall back to manual `- [ ] ` syntax parsing.

Example:

```
call mom by Friday, block 1-2pm for standup, domain renewal
```

→ extraction creates three tasks ("call mom", "standup", "domain renewal") with due date, time block, and calendar block metadata. Review state displays all three with badges. Accept them and they land in today's `## Tasks` with full metadata preserved; reject and return to edit.

**Manual syntax still works as an escape hatch:** if you type `- [ ] call mom`, it bypasses AI and lands directly as a task.

**Known limits (Phase 3):**
- Time blocks are extracted and displayed in Review, but do not yet write calendar events (Phase 5).
- Undo (30-second window to reverse extraction and commit) is deferred.

## AI Providers (Phase 4)

Apple Foundation Models is the default and runs fully on-device. Phase 4 adds four
more providers behind the same `AIProvider` protocol: one more on-device (Ollama)
and three cloud (Claude, OpenAI, Gemini). Pick one in **Settings → AI → Provider**.
Switching takes effect on the next capture extraction — no restart.

### Provider matrix

| Provider | Locus | Default model | Latency | Cost |
|---|---|---|---|---|
| **Apple Foundation Models** (default) | On-device | system | ~1–2s | Free |
| **Ollama** | On-device | `qwen2.5:3b` | ~1–3s (M-series) | Free |
| **Claude** | Cloud (Anthropic) | `claude-haiku-4-5` | ~1–2s | ~$0.0001–0.0003 / extraction |
| **OpenAI** | Cloud (OpenAI) | `gpt-4o-mini` | ~1–2s | ~$0.0001–0.0003 / extraction |
| **Gemini** | Cloud (Google) | `gemini-2.5-flash` | ~1s | ~$0.00005–0.0001 / extraction |

Apple FM requires macOS 26+. The picker groups providers under **On-device** and
**Cloud** subheaders so the privacy posture is visible before the provider name.

### API keys live in the Keychain — never on disk

Cloud providers need an API key. Enter it once in **Settings → AI** next to the
provider; Jotty writes it to the macOS Keychain (`kSecClassGenericPassword`,
app-scoped, **not** iCloud-synced) and never reads it back into the UI.

**Keys never touch `config.json` or any file on disk.** Settings → AI is the only
place a key is ever entered, and the Keychain is the only place it is ever stored.
There is no environment variable or config-file key path for the app itself. (CI
uses env-var keys for the eval sweep only — see **Evaluation** below — never the
running app.)

### Endpoints each provider hits

Settings → AI shows every cloud endpoint URL before you enable that provider. The
full list (the only network destinations Jotty contacts for extraction):

| Provider | Endpoint |
|---|---|
| Apple Foundation Models | none — runs entirely on this Mac |
| Ollama | `http://127.0.0.1:11434` (local daemon, loopback only) |
| Claude | `https://api.anthropic.com/v1/messages` |
| OpenAI | `https://api.openai.com/v1/chat/completions` |
| Gemini | `https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent` |

### Privacy posture

- **Apple Foundation Models** — On-device. Capture text never leaves your Mac.
- **Ollama** — On-device. Capture text never leaves your Mac; inference happens locally via Ollama.
- **Claude** — Cloud. Capture text is sent to Anthropic.
- **OpenAI** — Cloud. Capture text is sent to OpenAI.
- **Gemini** — Cloud. Capture text is sent to Google.

The default config (Apple FM + local markdown) makes zero outbound network
requests during a capture-extract-commit cycle.

### Ollama runtime

If you don't already have Ollama, Jotty can download and manage it for you, or
reuse an existing install.

- **Detection order:** Homebrew (`/opt/homebrew/bin/ollama`, then
  `/usr/local/bin/ollama`) > `/Applications/Ollama.app` > a Jotty-managed copy
  under `~/Library/Application Support/Jotty/ollama/`. An existing user install
  is always reused, so two daemons never fight over port 11434.
- **First-run download:** if nothing is found, Settings → AI offers "Download
  Ollama" (~150–250 MB). Jotty downloads the signed `Ollama.app`, strips the
  quarantine flag, and verifies the code signature before ever launching it.
- **Daemon:** Jotty starts `ollama serve` bound to `127.0.0.1:11434` and polls
  `/api/version` until ready. Pick a model (`qwen2.5:3b` default,
  `llama3.2:3b` / `phi3.5:3.8b` also offered) and Jotty pulls it via `/api/pull`
  with a progress bar.
- **Daemon log:** `~/Library/Application Support/Jotty/ollama/daemon.log`.
- **Lifecycle:** quitting Jotty stops a Jotty-managed daemon (SIGTERM, then
  SIGKILL after a 5s grace window). A Homebrew/system daemon Jotty merely reused
  is left running.

Model weights live in the standard `~/.ollama/models/` and are preserved when you
disable the provider — re-downloading 2 GB because of a toggle is a worse failure
mode than leaving the weights on disk.

### Provider failure handling

If a provider fails (network down, invalid key, model not loaded, rate limit),
the Review state shows an inline toast and offers to fall back to Apple FM so the
capture is never lost. Cloud rate limits / 5xx are retried with exponential
backoff (max 2 retries, honouring `Retry-After`) before surfacing.

### Evaluation

The same 35-fixture extraction suite from Phase 3 runs against every provider, so
a provider swap is validated against identical inputs. The release-blocker bar is
that dimensions 3 (Date Restraint), 4 (Time-Block Discipline), and 6
(Hallucination Rate) must pass at 100%; non-blocker dimensions are tracked as
signals.

Run the cross-provider sweep locally:

```bash
# Apple FM only (always runs; default)
xcodebuild test -scheme Jotty -destination 'platform=macOS' \
  -only-testing:JottyTests/CrossProviderTests/testAppleFM

# Apple FM + Ollama (requires a running daemon — auto-skips if none)
xcodebuild test -scheme Jotty -destination 'platform=macOS' \
  -only-testing:JottyTests/CrossProviderTests

# Full sweep including the three cloud providers (requires keys)
JOTTY_TEST_CLOUD_PROVIDERS=1 \
ANTHROPIC_API_KEY=… OPENAI_API_KEY=… GEMINI_API_KEY=… \
xcodebuild test -scheme Jotty -destination 'platform=macOS' \
  -only-testing:JottyTests/CrossProviderTests
```

Cloud legs are gated behind `JOTTY_TEST_CLOUD_PROVIDERS=1` plus the per-provider
env key, so contributors without keys stay unblocked — those legs skip cleanly
rather than fail. CI runs the cloud sweep weekly (and on manual dispatch) via
`.github/workflows/eval-providers.yml`, reading the keys from repo secrets
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`). Each run writes a
scorecard to `~/Library/Application Support/Jotty/debug/eval-runs/<timestamp>/`.

The CI eval keys are the **only** place an API key reaches Jotty via an
environment variable; the running app always reads keys from the Keychain.

## Calendar integration (Phase 5)

Time-blocked tasks can become real macOS Calendar events, and today's events read
back into the menubar. Calendar access is never requested at launch; the first
calendar-touching action triggers the macOS full-access prompt, and denying it just
turns the calendar features off (Jotty keeps working as a plain task tool).

**Time-blocked tasks create events.** When you commit a task that carries a time
block (e.g. "standup 9-9:30am"), Jotty creates one event on your default calendar.
The task's markdown line gains a `cal_event:<id>` token linking the task to the
event, alongside the existing `time:` block. The default calendar is the system
default for new events, and you can override it in **Settings → Calendar** (a picker
of your writable calendars). Calendar writes are best-effort: a failure logs a
non-blocking notice but never rolls back the markdown commit, because disk is the
source of truth.

**Pre-commit overlap warning.** Before writing a new time-blocked event, Jotty
checks for events that overlap that window. If one is found, the commit shows
"⚠️ overlaps with 'Standup' — commit anyway?" so you can confirm or cancel before
anything is written.

**Read-only Calendar section in the menubar.** Today's timed events appear in a
read-only "Calendar" section in the menubar popover (below your tasks), sorted by
start time with `·` bullets. Clicking a row opens Calendar.app at that date.

**Two-way link and lifecycle.** Toggling a task done leaves its event untouched (a
done task is still a real commitment). Deleting a task that has a `cal_event` asks
once whether to also delete the calendar event, and remembers your choice (you can
reset it to "Ask each time" in Settings → Calendar). Editing a task's time updates
the linked event in place.

**Drift sync.** If you edit a linked event directly in Calendar.app, Jotty detects
the change the next time it comes to the foreground and prompts to sync the markdown
line (Calendar wins).

The `cal_event:<id>` token sits in the task line alongside the other metadata tokens
(`done:`, `due:`, `rolled_to:`, `time:`); those lines live in the per-day markdown
files described under [Storage](#storage) and [Capture syntax](#capture-syntax-phase-2).
All calendar work goes through a `CalendarService` seam, so the test suite runs
against a fake store and never touches your real calendar or triggers a permission
prompt.

## Send to Claude (Phase 6)

Right-click any task in the menubar and pick **Send to Claude** to hand the task off
to Claude as a prompt. The prompt is the task text wrapped in a small template
("Help me with this task: ..."). There are two modes, chosen in
**Settings → AI → Claude action**:

- **Web** (default) opens `https://claude.ai/new?q=<prompt>` in your browser with the
  prompt prefilled.
- **Claude Code** runs `claude "<prompt>"` via the local Claude Code CLI. The prompt
  is passed as a single argument (never interpolated into a shell command string), so
  task text with quotes or shell metacharacters is safe. If no `claude` binary is on
  your PATH, Jotty shows a one-line notice pointing you back to Web mode instead of
  failing silently.

Send to Claude also has a default keybinding (**⌘K**), rebindable in
**Settings → Keybindings**.

**Web prefill caveat:** the `claude.ai/new?q=` prefill behaviour can change on
Anthropic's side. If you pick Web mode and land on an empty chat, the `q=` prefill
may have been deprecated; use Claude Code mode, or open the desktop deep link
`claude://claude.ai/new?q=<prompt>` if you have the Claude desktop app installed. The
web endpoint lives behind a single constant so it can be swapped in one place.

## Launch at login (Phase 6)

Jotty can start automatically when you log in, so it is always in the menubar without
opening it manually. Toggle **Settings → General → "Launch Jotty at login"** (or opt
in from the first-launch onboarding screen). This uses `SMAppService.mainApp` — the
modern API, not the deprecated `SMLoginItemSetEnabled` / LaunchAgent plist. The
status line reflects the real OS state (`enabled`, `requires approval`, or
`not registered`); if macOS needs you to approve the item, the toggle points you to
**System Settings → General → Login Items**.

## Settings (Phase 6)

The Settings window has seven tabs (Integrations added in Phase 7):

| Tab | What it controls |
|---|---|
| **General** | Launch-at-login toggle, replay the welcome screen |
| **Storage** | Notes folder |
| **AI** | Provider picker, API keys (Keychain), endpoint transparency, Claude action mode |
| **Calendar** | Default calendar, delete-linked-event preference |
| **Integrations** | GitHub PAT (Keychain), opt-in periodic-check toggle, 5-source transparency table (added Phase 7) |
| **Keybindings** | Rebind any action, conflict warnings, reset to defaults |
| **Advanced** | Reveal `config.json` in Finder, reset to defaults, privacy + endpoint summary |

The **Keybindings** tab lists every action with its current key combo, lets you
record a new combo for any of them, warns inline when two actions share a combo
before you leave the tab, and has a **Reset to defaults** button. Rebinding the
global capture hotkey re-registers it live (no restart). Reset writes only
`config.json` defaults — it does not touch your Keychain API keys or
`keybindings.json`.

## First-launch onboarding (Phase 6)

On first launch Jotty shows a single welcome screen: a one-line value statement, a
**Grant Calendar access** button (the same lazy full-access request, no duplicate
prompt), a **Launch Jotty at login** toggle, a 30-second walkthrough link, and a
**Get started** button. It is shown once; you can replay it any time from
**Settings → General**. Skipping or closing it never blocks the app, and permissions
stay lazy.

## Privacy audit (Phase 6)

The default config (Apple Foundation Models + local markdown) makes zero outbound
network requests. This is enforced two ways: an automated unit test
(`PrivacyDefaultTests` — default provider is `apple-fm`, no HTTP client on the default
path) that runs on every build, and a documented manual packet-capture procedure
(tcpdump / Little Snitch during a full capture → extract → commit → rollover cycle)
that is the release-time human confirmation. The full procedure and the per-provider
endpoint table are in **[docs/privacy-audit.md](docs/privacy-audit.md)**.
**Settings → Advanced** shows the same zero-network summary plus the endpoint table.

## Unified Inbox (Phase 7)

External items surface as *suggested* tasks in the menubar, so work assigned to you
elsewhere shows up next to your own captures without leaving Jotty. Open the menubar
and a **Suggested** section (above your tasks) lists each item with its source glyph
and title.

- **Accept** writes the item into today's `## Tasks` with a source link, then drops
  it from the Suggested list. The task line carries `source:<sourceID>:<itemID>` and
  `source_url:<url>` tokens (the same additive metadata pattern as `cal_event:` and
  `time:`), so the task always points back to where it came from.
- **Dismiss** is remembered: the item is recorded in a local dismissed set and is
  never suggested again. Accepted items are tracked the same way, so a later refresh
  never re-suggests something you already actioned.

### Sources

The inbox is built on a single `InboxSource` protocol with a static transparency
registry, so every planned source is visible in Settings even before it ships.

| Source | Status | Auth | Endpoint |
|---|---|---|---|
| **GitHub** | Shipped | Personal Access Token | `https://api.github.com` |
| Gmail | Extension point | — | `https://gmail.googleapis.com` |
| Slack | Extension point | — | `https://slack.com/api` |
| Linear | Extension point | — | `https://api.linear.app` |
| Notion | Extension point | — | `https://api.notion.com` |

**GitHub is the one shipped source.** Set a Personal Access Token (with read access
to issues and pull requests) in **Settings → Integrations**; Jotty stores it in the
macOS Keychain (never in `config.json`, UserDefaults, or any file on disk) and
suggests your assigned issues and review-requested PRs.

**Gmail / Slack / Linear / Notion are documented extension points**, not yet built.
They appear in the transparency table with their endpoints so the privacy posture is
complete, and the protocol + registry make adding one a matter of writing a single
conforming `InboxSource` type — the Keychain credential flow and transparency list
are already generic.

### Refresh and privacy

- **No background polling by default.** With a source configured, the inbox refreshes
  when you open the menubar (lazy, the same as the calendar read). On the default,
  unconfigured config Jotty makes no inbox network request at all.
- **Opt-in periodic checks.** **Settings → Integrations** has a "Check periodically"
  toggle (with an interval, minimum 5 minutes) that is **OFF by default**. Turn it on
  only if you want a timer to refresh in the background.

The full network posture is recorded in
**[docs/privacy-audit.md](docs/privacy-audit.md)**.

## Testing

```bash
xcodebuild -scheme Jotty -destination 'platform=macOS' test
```

## Roadmap

- **Phase 1:** capture → markdown file (shipped)
- **Phase 2:** menubar list, daily rollover (shipped)
- **Phase 3:** AI task extraction (Apple Foundation Models default) (shipped)
- **Phase 4:** Cloud AI providers (Ollama, Claude, OpenAI, Gemini) (shipped)
- **Phase 5:** Calendar integration (read + write) (shipped)
- **Phase 6:** Send-to-Claude, launch-at-login, full settings UI, onboarding, privacy audit — **v1.0 shipped**
- **Phase 7:** Unified inbox (GitHub shipped via PAT; Gmail / Slack / Linear / Notion documented extension points) (shipped)
- **Phase 8:** Calendar power-UX (add to calendar, smart scheduling)
- **Phase 9:** Command bar (global search, quick actions)

## License

MIT.
