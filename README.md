# 🪩 Disco

Slack-style emoji autocomplete for your Mac. Type `:` in any app — Mail, Notes,
VS Code, Slack, Terminal, wherever — and Disco shows a fuzzy-matched popup.
Pick with arrow keys or mouse, confirm with Enter or Tab, and the emoji lands
exactly where your cursor is.

No Electron. No subscription. Pure Swift, pure AppKit, ~1MB.

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

- **macOS 12 Ventura or later**
- **Xcode Command Line Tools:** `xcode-select --install`

---

## Build & Install

```bash
git clone https://github.com/your-username/disco.git
cd disco
bash build.sh
```

This produces:

| File | Use |
|---|---|
| `Disco.app` | Drag to `/Applications` to install locally |
| `Disco.dmg` | Share with others — they open it and drag to their Applications |

### First launch (unsigned app)

Because Disco isn't signed with an Apple Developer certificate, macOS will warn
you the first time:

1. **Right-click** `Disco.app` → **Open** → click **Open** in the dialog
2. That's it — macOS remembers the choice and won't ask again

### Accessibility permission

Disco needs Accessibility access to monitor keystrokes system-wide. On first
launch you'll be prompted automatically:

> System Settings → Privacy & Security → Accessibility → enable Disco

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
├── build.sh                               # One-command build → .app + .dmg
├── Package.swift                          # Swift Package Manager manifest
├── Sources/
│   ├── main.swift                         # Entry point — boots NSApplication
│   ├── AppDelegate.swift                  # Core engine: event tap, key handling, emoji insertion
│   ├── EmojiDatabase.swift                # Data model, fuzzy search, recency-weighted usage
│   ├── DiscoPreferences.swift             # UserDefaults wrapper for persistent settings
│   ├── AutocompleteWindowController.swift # Floating popup (NSPanel)
│   ├── BrowserWindowController.swift      # Full emoji browser window
│   └── SettingsViewController.swift       # Settings popover
└── Resources/
    ├── Info.plist                         # App bundle metadata
    └── emoji.json                         # 745-entry emoji database
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

### Popup
A borderless `NSPanel` at `.popUpMenu` level — above everything, non-activating
(the host app retains focus). Positioned below the text caret using the
Accessibility API (`kAXBoundsForRangeParameterizedAttribute`), falling back to
mouse position if the app doesn't expose caret bounds.

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
- **Change the bundle ID** — edit `BUNDLE_ID` in `build.sh` and
  `CFBundleIdentifier` in `Resources/Info.plist`

---

## Distributing (unsigned)

Share `Disco.dmg`. Recipients:
1. Open the DMG
2. Drag `Disco.app` to their Applications folder
3. Right-click → Open the first time (bypasses Gatekeeper for unsigned apps)
4. Grant Accessibility permission when prompted

---

## Code Signing & Notarization (optional)

If you obtain an Apple Developer account ($99/yr):

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
