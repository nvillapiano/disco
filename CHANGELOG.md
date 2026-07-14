# Changelog

All notable changes to Disco are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [1.1.0] — 2026-07-14

### Added
- **Pre-built DMG release via GitHub Actions.** Every `v*` tag push triggers a
  macOS build on GitHub Actions and publishes a `Disco.dmg` to GitHub Releases.
  Users can now download a ready-to-run build without installing Xcode.
  See `.github/workflows/release.yml`.
- **`npm run migrate`** — quits any running Disco instance, copies the newly
  built `Disco.app` to `/Applications`, strips quarantine attributes, and
  relaunches the app. Replaces the previous manual drag-and-drop step.
- **`npm run build:full`** — single command that builds and installs: runs
  `npm run build` then `npm run migrate`.
- **`npm run release`** — creates and pushes the version tag from `package.json`,
  triggering the GitHub Actions release workflow automatically.
- **Status menu health display.** The menu bar menu now shows the live state of
  both the Accessibility permission and the event tap:
  `✅ Accessibility granted` / `⚠️ Accessibility needed` and
  `✅ Listening for :` / `⚠️ Event tap inactive`. Status lines refresh when
  the tap starts and when the menu opens.

### Fixed
- **Popup no longer anchors to the bottom-left corner.** Two bugs combined to
  produce the bottom-left regression: (1) some apps return a degenerate
  `kAXBoundsForRangeParameterizedAttribute` rect with zero height and `maxY`
  equal to the full screen height, which converts to `(0, 0)` in AppKit
  coordinates. These rects are now rejected with explicit `height > 2` and
  `maxY < screenH` guards. (2) the fallback path was using the left edge of the
  focused element as the X anchor, always producing a far-left popup. It now
  uses the mouse cursor X if it's within the field, falling back to the
  horizontal centre of the field.
- **Menu bar icon no longer disappears after showing the popup.** `setupMenuBar()`
  was being called from three places (launch, event-tap start, `popoverDidClose`)
  and each call was creating a new `NSStatusItem`, causing the old one to be
  released and vanish. `NSStatusItem` is now created exactly once; subsequent
  calls only rebuild the menu content via a new `attachMenu()` helper.
- **Accessibility permission now persists across rebuilds.** macOS revokes
  Accessibility grants when the app binary changes if the code signing identity
  changes between builds. `build.sh` now signs with a stable self-signed
  `Disco Dev` certificate (created once in Keychain Access) so the TCC database
  keeps the grant across rebuilds. Falls back to ad-hoc signing with a warning
  if the cert is not found.
- **Enter/Tab no longer leaks into the host app.** Previously, confirming a
  selection with Enter would also trigger whatever Enter does in the underlying
  app (submit a form, send a message, add a newline). The event tap now returns
  `nil` for Enter and Tab while the popup is open, consuming the keypress
  entirely before the host app sees it.
- **Arrow keys no longer move the cursor in the host app while the popup is
  open.** Up/Down/Left/Right are now fully consumed during an active capture
  session, so navigating the popup no longer also repositions the cursor.
- **Escape no longer leaks into apps like vim or VS Code.** Escape is now
  swallowed when dismissing the popup, preventing unintended mode changes or
  command cancellations in apps that interpret Escape.
- **Emoji insertion no longer clobbers the clipboard.** The previous approach
  temporarily swapped the pasteboard contents and relied on a 250ms timer to
  restore them — a window during which a fast paste would receive the emoji
  instead of the user's actual clipboard. Insertion now uses
  `CGEvent.keyboardSetUnicodeString` to inject the character directly into the
  event stream. No clipboard is touched.

### Changed
- **Usage tracking is now recency-weighted.** Emoji you used heavily a year ago
  but haven't touched since will gradually yield their top positions to emoji
  you use regularly now. Decay formula: `score = count / sqrt(hoursSinceLastUse + 1)`.
  Existing usage data is migrated automatically on first launch — nothing is lost.
- **Popup result count is now hardcoded at 30.** The value was previously stored
  as a UserDefaults preference (`com.disco.popupResultCount`) but was never
  exposed in the Settings UI, making it a hidden and effectively unused knob.
  30 is a sensible ceiling for a 10-column grid.
- **Browser window remembers its size and position.** The emoji browser now uses
  `NSWindow.setFrameAutosaveName` so resizing and repositioning the window
  persists across launches.

---

## [1.0.0] — 2026-03-25

### Added
- Initial release.
- System-wide emoji autocomplete triggered by `:` (configurable).
- Fuzzy search across aliases, descriptions, and tags.
- 10-column floating popup with blurred background and alias label.
- Full emoji browser with category sidebar, search, copy, and insert.
- Usage tracking — frequently used emoji surface first.
- Launch at login toggle (macOS 13+).
- Menu bar icon (🪩) with Browse, Settings, About, and Quit.
- One-command build script producing both `.app` and `.dmg`.
