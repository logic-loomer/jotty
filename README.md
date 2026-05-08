# Jotty

Open-source macOS quick-capture app. Hit a hotkey, brain-dump, your notes land in a markdown file.

**Status:** Phase 3 shipped. AI extraction with Apple Foundation Models. Capture → Review → Commit flow. Phase 4 (cloud AI providers) incoming.

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
- Cloud AI providers (Ollama, Claude, OpenAI, Gemini) arrive in Phase 4.
- Time blocks are extracted and displayed in Review, but do not yet write calendar events (Phase 5).
- Undo (30-second window to reverse extraction and commit) is deferred.

## Testing

```bash
xcodebuild -scheme Jotty -destination 'platform=macOS' test
```

## Roadmap

- **Phase 1:** capture → markdown file (shipped)
- **Phase 2:** menubar list, daily rollover (shipped)
- **Phase 3:** AI task extraction (Apple Foundation Models default) (shipped)
- **Phase 4:** Cloud AI providers (Ollama, Claude, OpenAI, Gemini)
- **Phase 5:** Calendar integration (read + write)
- **Phase 6:** Send-to-Claude, launch-at-login, full settings UI
- **Phase 7:** Unified inbox (calendar + tasks + notes)
- **Phase 8:** Calendar power-UX (add to calendar, smart scheduling)
- **Phase 9:** Command bar (global search, quick actions)

## License

MIT.
