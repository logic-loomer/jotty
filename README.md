# Jotty

Open-source macOS quick-capture app. Hit a hotkey, brain-dump, your notes land in a markdown file.

**Status:** Phase 1 — capture-to-disk foundation. AI extraction, calendar integration, and the menubar list arrive in subsequent phases.

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

## Testing

```bash
xcodebuild -scheme Jotty -destination 'platform=macOS' test
```

## Roadmap

- **Phase 1 (now):** capture → markdown file
- **Phase 2:** menubar list, daily rollover
- **Phase 3:** AI task extraction (Apple Foundation Models default)
- **Phase 4:** Cloud AI providers (Ollama, Claude, OpenAI, Gemini)
- **Phase 5:** Calendar integration (read + write)
- **Phase 6:** Send-to-Claude, launch-at-login, full settings UI

## License

MIT.
