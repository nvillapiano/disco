# 🪩 Disco

Slack-style emoji autocomplete for your Mac. Type `:` in any app — Mail, Notes,
VS Code, Slack, Terminal, wherever — and Disco shows a fuzzy-matched popup.
Pick with arrow keys or mouse, confirm with Enter or Tab, and the emoji lands
exactly where your cursor is.

No Electron. No subscription. Pure Swift, pure AppKit, ~1MB.

---

## Download

**[→ Download the latest Disco.dmg](https://github.com/nvillapiano/disco/releases/latest)**

1. Open the DMG and drag **Disco.app** to `/Applications`
2. Launch Disco — right-click → **Open** on first run to bypass Gatekeeper
3. Grant Accessibility when prompted: **System Settings → Privacy & Security → Accessibility**
4. Type `:fire` in any app to get started

---

## Features

| | |
|---|---|
| **System-wide autocomplete** | Works in every app that accepts text input |
| **Fuzzy search** | `:party` matches 🎉 `:tada:`, `:fireworks:`, `:confetti_ball:` |
| **Alias label** | Shows `:tada:` below the popup so you always know the shortcode |
| **Emoji Browser** | Full searchable browser with category sidebar, copy & insert |
| **Configurable trigger** | Change `:` to any character in Settings |
| **Recency-weighted history** | Frequently *and recently* used emoji surface first |
| **Launch at login** | Stays running silently in the background |
| **Menu bar icon** | 🪩 — unobtrusive, always accessible |
| **No Dock icon** | Pure menu bar app |
| **No clipboard clobber** | Emoji is injected directly — your clipboard is never touched |

---

## Requirements

- **macOS 12 Monterey or later**
- **Xcode Command Line Tools** (build from source only): `xcode-select --install`

---

## Build from Source

```bash
git clone https://github.com/nvillapiano/disco.git
cd disco
npm run build:full   # build + install to /Applications + relaunch
```

Or step by step:

```bash
npm run build     # compile → Disco.app + Disco.dmg
npm run migrate   # quit running Disco, copy to /Applications, relaunch
```

`build.sh` can also be run directly without npm:

```bash
bash build.sh
# then drag Disco.app to /Applications manually
```

### Code signing (keeps Accessibility permission across rebuilds)

macOS revokes Accessibility permission whenever the app binary changes, unless
the app is signed with a stable identity. Create a local self-signed cert once:

1. Open **Keychain Access** → menu bar: **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `Disco Dev` · Identity Type: **Self Signed Root** · Certificate Type: **Code Signing**
3. Click **Create**

The build script signs automatically with this cert on every build. Without it,
you'll be prompted to re-grant Accessibility after each `npm run build:full`.

### First launch (unsigned / locally built)

1. **Right-click** `Disco.app` → **Open** → click **Open** in the dialog
2. macOS remembers the choice — you won't be asked again

### Accessibility permission

Disco needs Accessibility access to monitor keystrokes system-wide:

> System Settings → Privacy & Security → Accessibility → enable Disco

The menu bar icon shows `⚠️ Accessibility needed` until this is granted.

---

## Usage

| Action | Result |
|---|---|
| Type `:` anywhere | Popup appears with popular emoji |
| Type `:fire` | Filters to matching emoji |
| `↑` `↓` `←` `→` | Navigate the popup |
| `Enter` or `Tab` | Insert the selected emoji |
| `Escape` | Dismiss without inserting |
| Click any emoji | Insert it |
| Click outside popup | Dismiss |
| Menu bar 🪩 → Browse Emoji… | Open full browser |
| Double-click in browser | Insert emoji and close |

---

## Settings

Click 🪩 in the menu bar → **Settings…**

- **Trigger character** — default `:`. Change to any single character. Avoid
  letters and numbers (they'll conflict with normal typing).
- **Launch at login** — start Disco automatically when you log in (macOS 13+).

---

## Project Structure

```
Disco/
├── build.sh                               # Compile → .app + .dmg, code-sign with "Disco Dev" cert
├── install.sh                             # Quit running Disco, copy to /Applications, relaunch
├── package.json                           # npm scripts: build, migrate, build:full, release
├── Package.swift                          # Swift Package Manager manifest
├── Sources/
│   ├── main.swift                         # Entry point — boots NSApplication
│   ├── AppDelegate.swift                  # Core engine: event tap, key handling, emoji insertion
│   ├── EmojiDatabase.swift                # Data model, fuzzy search, recency-weighted usage
│   ├── DiscoPreferences.swift             # UserDefaults wrapper for persistent settings
│   ├── AutocompleteWindowController.swift # Floating popup (NSPanel)
│   ├── BrowserWindowController.swift      # Full emoji browser window
│   └── SettingsViewController.swift       # Settings popover
├── Resources/
│   ├── Info.plist                         # App bundle metadata
│   └── emoji.json                         # 745-entry emoji database
└── .github/
    └── workflows/
        └── release.yml                    # Build + publish DMG to GitHub Releases on v* tag push
```

---

## How It Works

### Event interception
Disco registers a system-wide `CGEventTap` via Core Graphics. This requires
Accessibility permission and intercepts `keyDown` events before they reach the
target app. A `typingBuffer` accumulates characters starting from the trigger
character (e.g. `:fire`).

### Fuzzy search
Each emoji entry is scored across aliases, description, and tags using prefix
and contains matching. Scores are weighted by recency-decayed usage so emoji
you've used recently surface above ones you used heavily long ago. Formula:
`decayedScore = count / sqrt(hoursSinceLastUse + 1)`.

### Popup positioning
The popup is positioned using a three-step fallback:

1. **Exact caret bounds** via `kAXBoundsForRangeParameterizedAttribute` — works
   in native AppKit apps (TextEdit, Notes, Mail, etc.). Degenerate rects returned
   by apps that partially implement this API are rejected (zero height, or bottom
   of screen).
2. **Focused element frame** via `kAXPositionAttribute` / `kAXSizeAttribute` —
   works in browsers and Electron apps. Elements taller than 120pt are skipped
   (they're container views, not text inputs). X position uses the mouse cursor
   if it's within the field, otherwise the field's horizontal centre.
3. **Mouse cursor position** — universal fallback.

### Key event handling
While the popup is open, navigation keys (↑↓←→), Enter, Tab, and Escape are
consumed (`return nil` from the event tap callback) so they never reach the host
app. Backspace is passed through so the host app also removes the character.

### Emoji insertion
On selection: sends `kVK_Delete` keypresses to erase the typed query, then
injects the emoji character directly into the HID event stream using
`CGEvent.keyboardSetUnicodeString`. No clipboard is involved, so the user's
pasteboard is never disturbed.

---

## Customising

- **Add emoji** — edit `Resources/emoji.json` (schema: `emoji`, `description`,
  `aliases`, `tags`, `category`)
- **Resize the popup grid** — edit `cellSize` and `cols` in `AutocompleteWindowController.swift`
- **Change the bundle ID** — edit `CFBundleIdentifier` in `Resources/Info.plist`

---

## Releasing

```bash
# 1. Bump version in package.json
# 2. Update CHANGELOG.md
# 3. Commit and push
git add -A && git commit -m "Release vX.Y.Z" && git push

# 4. Tag and push — GitHub Actions builds and publishes the DMG automatically
npm run release
```

The workflow (`.github/workflows/release.yml`) runs on `macos-latest`, builds
`Disco.dmg`, and attaches it to a new GitHub Release.

---

## Code Signing & Notarization

For distribution to others, Disco ships as an unsigned DMG. Recipients
right-click → Open once to bypass Gatekeeper.

If you obtain an Apple Developer account ($99/yr) you can fully notarize:

```bash
# Sign
codesign --deep --force --options runtime \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  Disco.app

# Notarize
xcrun notarytool submit Disco.dmg \
  --apple-id your@email.com \
  --team-id TEAMID \
  --password APP_SPECIFIC_PASSWORD \
  --wait

# Staple
xcrun stapler staple Disco.app
```

After notarization, recipients can open Disco normally with no Gatekeeper warning.

---

## License

MIT — do whatever you want with it.
