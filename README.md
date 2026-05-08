# Jotty

Open-source macOS quick-capture app. Hit a hotkey, brain-dump, your notes land in a markdown file.

**Status:** Phase 2 shipped. Menubar list and daily rollover are live. Phase 3 (AI extraction) incoming.

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

## Testing

```bash
xcodebuild -scheme Jotty -destination 'platform=macOS' test
```

## Roadmap

- **Phase 1:** capture → markdown file (shipped)
- **Phase 2:** menubar list, daily rollover (shipped)
- **Phase 3:** AI task extraction (Apple Foundation Models default)
- **Phase 4:** Cloud AI providers (Ollama, Claude, OpenAI, Gemini)
- **Phase 5:** Calendar integration (read + write)
- **Phase 6:** Send-to-Claude, launch-at-login, full settings UI
- **Phase 7:** Unified inbox (calendar + tasks + notes)
- **Phase 8:** Calendar power-UX (add to calendar, smart scheduling)
- **Phase 9:** Command bar (global search, quick actions)

## License

MIT.
