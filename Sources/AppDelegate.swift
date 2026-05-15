/// AppDelegate.swift
/// Disco — system-wide emoji autocomplete
///
/// This is the central nervous system of Disco. It owns:
///   - The menu bar status item and menu
///   - The CGEventTap that intercepts system-wide keystrokes
///   - The typing buffer that accumulates the user's query
///   - The autocomplete lifecycle (show, update, hide, commit)
///   - Emoji insertion via direct Unicode event injection
///
/// Architecture note:
/// Disco is a pure menu bar app (LSUIElement = true, .accessory activation policy).
/// There is no main window and no Dock icon. All UI is driven from the status item.

import Cocoa
import Carbon.HIToolbox  // kVK_* virtual key constants

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var statusItem: NSStatusItem!
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Lazily created on first use; persists for the app lifetime.
    private var autocompleteController: AutocompleteWindowController?
    private var browserWindowController: BrowserWindowController?
    private var settingsPopover: NSPopover?
    private var settingsVC: SettingsViewController?

    // MARK: Typing state

    /// True from when the trigger character is typed until the popup is dismissed.
    private var isCapturing = false

    /// Accumulates everything the user has typed since the trigger, including the
    /// trigger character itself. E.g. ":fire" for the query "fire". Used both to
    /// drive search and to know how many backspaces to send on commit.
    private var typingBuffer = ""

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // hide from Dock and Cmd-Tab switcher
        EmojiDatabase.shared.load()
        setupMenuBar()
        checkAccessibilityAndStartTap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopEventTap()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "🪩"
        statusItem.button?.font = NSFont.systemFont(ofSize: 14)
        statusItem.button?.toolTip = "Disco"

        let browse   = NSMenuItem(title: "Browse Emoji…", action: #selector(openBrowser),  keyEquivalent: "");  browse.target  = self
        let settings = NSMenuItem(title: "Settings…",     action: #selector(openSettings), keyEquivalent: ","); settings.target = self
        let about    = NSMenuItem(title: "About Disco",   action: #selector(showAbout),    keyEquivalent: "");  about.target   = self
        // Quit target is nil so the responder chain delivers it to NSApp.terminate(_:) automatically.
        let quit     = NSMenuItem(title: "Quit Disco",    action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")

        let menu = NSMenu()
        menu.addItem(browse)
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(about)
        menu.addItem(quit)
        statusItem.menu = menu
    }

    // MARK: - Accessibility & Event Tap

    /// Checks whether Disco already has Accessibility trust and starts the event
    /// tap immediately if so, or triggers the system permission prompt and then
    /// polls every 5 seconds until the user grants it.
    private func checkAccessibilityAndStartTap() {
        if AXIsProcessTrusted() {
            startEventTap()
        } else {
            // Pass prompt:true exactly once to show the system dialog.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            pollForAccessibility()
        }
    }

    /// Polls for Accessibility trust on a 5-second interval.
    /// Uses plain AXIsProcessTrusted() (no prompt option) so the system dialog
    /// is never re-triggered during polling.
    private func pollForAccessibility() {
        if AXIsProcessTrusted() {
            startEventTap()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.pollForAccessibility()
            }
        }
    }

    /// Creates and enables the CGEventTap. The tap intercepts keyDown events at
    /// the session level (before they reach any application) using a C-compatible
    /// callback that bridges back into this instance via an unretained pointer.
    ///
    /// If tap creation fails (rare, but possible if Accessibility was revoked
    /// after launch), it retries after 2 seconds.
    private func startEventTap() {
        let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let me = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return me.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Disco: failed to create event tap — will retry")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.startEventTap()
            }
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopEventTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
    }

    // MARK: - Key Event Handling

    /// The core event tap handler. Called synchronously on the main thread for
    /// every keyDown event system-wide.
    ///
    /// Return values:
    ///   - `Unmanaged.passRetained(event)` — pass the event through to the host app unchanged
    ///   - `nil` — swallow the event entirely; the host app never sees it
    ///
    /// Note: All UI mutations (popup updates, selection) are dispatched to the main
    /// queue via DispatchQueue.main.async rather than called directly, because
    /// AppKit is not safe to call from within the event tap callback itself.
    private func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags   = event.flags

        // Never intercept system shortcuts — pass through and cancel any active
        // capture so the popup doesn't linger after e.g. Cmd-Tab.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            if isCapturing { cancelCapture() }
            return Unmanaged.passRetained(event)
        }

        // Escape: dismiss the popup and swallow the event so it doesn't trigger
        // unintended behaviour in host apps (e.g. vim normal mode, VS Code command cancel).
        if keyCode == kVK_Escape {
            if isCapturing {
                cancelCapture()
                return nil  // consume — do not forward to host app
            }
            return Unmanaged.passRetained(event)
        }

        // Keys that only matter while the popup is open.
        if isCapturing {

            // Confirm: swallow Enter/Tab so the host app doesn't act on them
            // (submit a form, send a message, insert a tab character, etc.).
            if keyCode == kVK_Return || keyCode == kVK_Tab {
                DispatchQueue.main.async { self.autocompleteController?.selectCurrent() }
                return nil
            }

            // Navigation: swallow arrow keys so they don't also move the cursor
            // in the host app while the user is navigating the popup grid.
            if keyCode == kVK_DownArrow || keyCode == kVK_RightArrow {
                DispatchQueue.main.async { self.autocompleteController?.moveDown() }
                return nil
            }
            if keyCode == kVK_UpArrow || keyCode == kVK_LeftArrow {
                DispatchQueue.main.async { self.autocompleteController?.moveUp() }
                return nil
            }

            // Backspace: pass through so the host app deletes the character too,
            // then trim the buffer and update the popup. If the buffer is down to
            // just the trigger character, cancel entirely.
            if keyCode == kVK_Delete {
                if typingBuffer.count <= 1 {
                    cancelCapture()
                } else {
                    typingBuffer.removeLast()
                    scheduleAutocompleteUpdate()
                }
                return Unmanaged.passRetained(event)
            }
        }

        // Typed character — check if it starts or continues a capture session.
        guard let char = event.character else { return Unmanaged.passRetained(event) }

        let trigger = DiscoPreferences.shared.triggerCharacter

        if !isCapturing && char == trigger {
            isCapturing = true
            typingBuffer = trigger
            scheduleAutocompleteUpdate()
            return Unmanaged.passRetained(event)
        }

        if isCapturing {
            // Space and newline break the capture — assume the user has moved on.
            if char == " " || char == "\n" || char == "\r" {
                cancelCapture()
                return Unmanaged.passRetained(event)
            }
            typingBuffer += char
            scheduleAutocompleteUpdate()
        }

        return Unmanaged.passRetained(event)
    }

    // MARK: - Autocomplete Updates

    /// Debounces autocomplete updates through the main queue so that rapid
    /// keystroke bursts don't stack up redundant UI work.
    private func scheduleAutocompleteUpdate() {
        DispatchQueue.main.async { [weak self] in self?.updateAutocomplete() }
    }

    private func updateAutocomplete() {
        // Strip the trigger character — search only over the user's actual query.
        let query = String(typingBuffer.dropFirst())
        let results = EmojiDatabase.shared.search(query: query)

        if results.isEmpty && !query.isEmpty {
            hideAutocomplete()
            return
        }

        if autocompleteController == nil {
            let ac = AutocompleteWindowController()
            ac.onSelect = { [weak self] entry in self?.commitEmoji(entry) }
            ac.onCancel = { [weak self] in self?.cancelCapture() }
            autocompleteController = ac
        }

        let pos = caretScreenPosition()
        autocompleteController?.show(emoji: results, near: pos)
    }

    private func hideAutocomplete() {
        autocompleteController?.hide()
    }

    private func cancelCapture() {
        isCapturing = false
        typingBuffer = ""
        DispatchQueue.main.async { [weak self] in self?.hideAutocomplete() }
    }

    // MARK: - Emoji Insertion

    /// Called when the user confirms a selection. Records usage, resets capture
    /// state, then schedules insertion with a short delay to let the popup
    /// animation complete before we start sending backspaces.
    private func commitEmoji(_ entry: EmojiEntry) {
        let deleteCount = typingBuffer.count
        let emojiString = entry.emoji
        cancelCapture()
        EmojiDatabase.shared.recordUsage(entry)

        // 40ms gives the popup time to dismiss before we start sending keystrokes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            self.replaceTypedText(deleteCount: deleteCount, with: emojiString)
        }
    }

    /// Erases the typed query and injects the selected emoji into the event stream.
    ///
    /// Insertion approach: `CGEvent.keyboardSetUnicodeString` injects the emoji
    /// as a Unicode keyboard event directly into the HID event stream. This is
    /// cleaner and more reliable than the alternative clipboard-swap approach
    /// (save pasteboard → paste → restore pasteboard), which had a race condition
    /// during the restore delay and failed in apps that block ⌘V.
    private func replaceTypedText(deleteCount: Int, with emoji: String) {
        let src = CGEventSource(stateID: .hidSystemState)

        // Send one backspace per character in the buffer (trigger char + query).
        for _ in 0..<deleteCount {
            CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Delete), keyDown: true)?
                .post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Delete), keyDown: false)?
                .post(tap: .cghidEventTap)
        }

        // 30ms after the backspaces, inject the emoji as a Unicode keyboard event.
        // virtualKey 0 is a placeholder — the actual character is set via
        // keyboardSetUnicodeString, which accepts a UTF-16 code unit array.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            let utf16 = Array(emoji.utf16)
            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            keyDown?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyUp?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Caret Position

    /// Returns the screen position of the insertion caret in the currently focused
    /// text field, using the macOS Accessibility API.
    ///
    /// Tries three approaches in order:
    ///   1. Exact caret bounds via kAXBoundsForRangeParameterizedAttribute
    ///   2. Focused element frame (text field bounds) — works in apps that don't
    ///      expose per-character caret bounds (Chrome, Electron, VSCode, etc.)
    ///   3. Current mouse location as a last resort
    ///
    /// All Accessibility rects use top-left origin (CG screen coordinates), which
    /// is converted to NSPoint bottom-left origin for NSWindow positioning.
    private func caretScreenPosition() -> NSPoint {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedEl: CFTypeRef?
        AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedEl)
        guard let focused = focusedEl, let el = focused as? AXUIElement else {
            return NSEvent.mouseLocation
        }

        let screenH = NSScreen.screens.first?.frame.height ?? 800

        // 1. Precise caret position via the selected text range bounds.
        var selVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &selVal) == .success,
           let sel = selVal {
            var boundsVal: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                el, kAXBoundsForRangeParameterizedAttribute as CFString, sel, &boundsVal
            ) == .success, let bv = boundsVal, let axVal = bv as? AXValue {
                var rect = CGRect.zero
                if AXValueGetValue(axVal, .cgRect, &rect), rect.maxY > 0 {
                    return NSPoint(x: rect.minX, y: screenH - rect.maxY)
                }
            }
        }

        // 2. Fallback: use the focused element's own frame so the popup at least
        //    appears near the active text field instead of wherever the mouse is.
        var posVal: CFTypeRef?
        var sizeVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posVal) == .success,
           AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeVal) == .success,
           let pv = posVal as? AXValue, let sv = sizeVal as? AXValue {
            var pos  = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(pv, .cgPoint, &pos), AXValueGetValue(sv, .cgSize, &size), size.height > 0 {
                // Anchor to the bottom-left of the focused element in AppKit coords.
                return NSPoint(x: pos.x, y: screenH - (pos.y + size.height))
            }
        }

        return NSEvent.mouseLocation
    }

    // MARK: - Menu Actions

    @objc func openBrowser() {
        if browserWindowController == nil {
            let bc = BrowserWindowController()
            // When inserting from the browser, deleteCount is 0 — there is no
            // typed query to erase, just inject the emoji at the current cursor.
            bc.onInsert = { [weak self] entry in
                guard let self else { return }
                EmojiDatabase.shared.recordUsage(entry)
                self.typingBuffer = ""
                self.replaceTypedText(deleteCount: 0, with: entry.emoji)
            }
            browserWindowController = bc
        }
        browserWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings() {
        if settingsPopover == nil {
            let vc = SettingsViewController()
            settingsVC = vc
            let pop = NSPopover()
            pop.contentViewController = vc
            pop.behavior = .transient
            pop.contentSize = NSSize(width: 260, height: 160)
            // Delegate restores the menu after the popover closes.
            // NSStatusItem.menu and NSPopover cannot coexist — the menu must be
            // detached before showing the popover and re-attached when it closes.
            pop.delegate = self
            settingsPopover = pop
        }

        guard let button = statusItem.button else { return }
        statusItem.menu = nil   // must be nil or the popover won't appear
        settingsPopover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Disco 🪩",
            .applicationVersion: "1.1",
            .credits: NSAttributedString(
                string: "Slack-style emoji picker for your Mac.\nType : in any app to get started.",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            )
        ])
    }
}

// MARK: - NSPopoverDelegate

extension AppDelegate: NSPopoverDelegate {
    /// Re-attach the status item menu once the settings popover has fully closed.
    /// If we re-attach it too early (e.g. on popoverWillClose) the animation
    /// glitches; waiting for didClose is the safe approach.
    func popoverDidClose(_ notification: Notification) {
        setupMenuBar()
    }
}

// MARK: - CGEvent character helper

private extension CGEvent {
    /// Returns the single Unicode character produced by this keyDown event.
    ///
    /// Uses `keyboardGetUnicodeString` rather than reading the keyCode and looking
    /// it up in a keymap — this correctly handles non-US keyboard layouts and
    /// composed characters without any custom mapping logic.
    var character: String? {
        var length = 0
        var chars  = [UniChar](repeating: 0, count: 4)
        self.keyboardGetUnicodeString(maxStringLength: 4,
                                      actualStringLength: &length,
                                      unicodeString: &chars)
        guard length > 0 else { return nil }
        var result = ""
        for i in 0..<length {
            guard let scalar = Unicode.Scalar(chars[i]) else { continue }
            result.append(Character(scalar))
        }
        return result.isEmpty ? nil : String(result.prefix(1))
    }
}
