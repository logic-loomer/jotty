# Jotty

Open-source macOS quick-capture app. Hit a hotkey, brain-dump, your notes land in a markdown file.

**Status:** Phase 4 shipped. Five AI providers (Apple FM, Ollama, Claude, OpenAI, Gemini) behind one protocol, API keys in the macOS Keychain, no-restart provider switching. Capture → Review → Commit flow. Phase 5 (calendar integration) incoming.

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

Edit `~/Library/Application Support/Jotty/keybindings.json` to rebind. UI for rebinding lands in Phase 6.

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

## Testing

```bash
xcodebuild -scheme Jotty -destination 'platform=macOS' test
```

## Roadmap

- **Phase 1:** capture → markdown file (shipped)
- **Phase 2:** menubar list, daily rollover (shipped)
- **Phase 3:** AI task extraction (Apple Foundation Models default) (shipped)
- **Phase 4:** Cloud AI providers (Ollama, Claude, OpenAI, Gemini) (shipped)
- **Phase 5:** Calendar integration (read + write)
- **Phase 6:** Send-to-Claude, launch-at-login, full settings UI
- **Phase 7:** Unified inbox (calendar + tasks + notes)
- **Phase 8:** Calendar power-UX (add to calendar, smart scheduling)
- **Phase 9:** Command bar (global search, quick actions)

## License

MIT.
