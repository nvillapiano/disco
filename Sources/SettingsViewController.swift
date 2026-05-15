/// SettingsViewController.swift
/// Disco — system-wide emoji autocomplete
///
/// A compact popover (260×160pt) attached to the menu bar status item.
/// Contains two settings:
///   - Trigger character: single-character text field with live validation
///   - Launch at login:   NSSwitch bound to SMAppService (macOS 13+)
///
/// Note on the popover/menu coexistence limitation:
/// NSStatusItem.menu and NSPopover cannot be shown simultaneously. AppDelegate
/// detaches the menu before showing this popover and re-attaches it in
/// popoverDidClose (NSPopoverDelegate). The Settings menu item uses Cmd+, as
/// its key equivalent, but this only works while the menu is attached.

import Cocoa
import ServiceManagement

final class SettingsViewController: NSViewController {

    private let triggerField   = NSTextField()
    private let loginToggle    = NSSwitch()
    private let triggerWarning = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 160))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        loadValues()
    }

    // MARK: - UI Construction

    private func buildUI() {
        // ── Title ──────────────────────────────────────────────────────────────
        let title = NSTextField(labelWithString: "Disco Settings 🪩")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(title)

        // ── Trigger character ──────────────────────────────────────────────────
        let triggerLabel = NSTextField(labelWithString: "Trigger character")
        triggerLabel.font = NSFont.systemFont(ofSize: 12)
        triggerLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(triggerLabel)

        triggerField.stringValue  = DiscoPreferences.shared.triggerCharacter
        triggerField.font         = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        triggerField.alignment    = .center
        triggerField.bezelStyle   = .roundedBezel
        triggerField.delegate     = self  // validation happens in NSTextFieldDelegate
        triggerField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(triggerField)

        // Warning shown in orange when the user sets a risky character (letter/digit).
        triggerWarning.font      = NSFont.systemFont(ofSize: 10)
        triggerWarning.textColor = .systemOrange
        triggerWarning.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(triggerWarning)

        // ── Launch at login ────────────────────────────────────────────────────
        let loginLabel = NSTextField(labelWithString: "Launch at login")
        loginLabel.font = NSFont.systemFont(ofSize: 12)
        loginLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loginLabel)

        loginToggle.state  = DiscoPreferences.shared.launchAtLogin ? .on : .off
        loginToggle.target = self
        loginToggle.action = #selector(loginToggled)
        loginToggle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loginToggle)

        // ── Layout ─────────────────────────────────────────────────────────────
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            triggerLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            triggerLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            triggerField.centerYAnchor.constraint(equalTo: triggerLabel.centerYAnchor),
            triggerField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            triggerField.widthAnchor.constraint(equalToConstant: 42),

            triggerWarning.topAnchor.constraint(equalTo: triggerField.bottomAnchor, constant: 2),
            triggerWarning.trailingAnchor.constraint(equalTo: triggerField.trailingAnchor),

            loginLabel.topAnchor.constraint(equalTo: triggerLabel.bottomAnchor, constant: 22),
            loginLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            loginToggle.centerYAnchor.constraint(equalTo: loginLabel.centerYAnchor),
            loginToggle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    private func loadValues() {
        triggerField.stringValue = DiscoPreferences.shared.triggerCharacter
        loginToggle.state        = DiscoPreferences.shared.launchAtLogin ? .on : .off
    }

    @objc private func loginToggled() {
        DiscoPreferences.shared.launchAtLogin = (loginToggle.state == .on)
    }
}

// MARK: - NSTextFieldDelegate (trigger character validation)

extension SettingsViewController: NSTextFieldDelegate {

    /// Fires on every keystroke. Enforces single-character input and warns the user
    /// if they choose a character that will conflict with normal typing.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let raw = field.stringValue

        // Always keep only the most recently typed character.
        let single = raw.isEmpty ? ":" : String(raw.suffix(1))
        if raw.count > 1 { field.stringValue = single }

        // Warn on letters, digits, and space — these will intercept normal typing
        // (e.g. setting trigger to "a" means Disco fires on every "a" keypress).
        let risky = Set(["a","b","c","d","e","f","g","h","i","j","k","l","m",
                         "n","o","p","q","r","s","t","u","v","w","x","y","z",
                         "0","1","2","3","4","5","6","7","8","9"," "])
        if risky.contains(single.lowercased()) {
            triggerWarning.stringValue = "⚠ May conflict with normal typing"
        } else {
            triggerWarning.stringValue = ""
            DiscoPreferences.shared.triggerCharacter = single
        }
    }

    /// Fires when the field loses focus. Clear the warning and ensure the saved
    /// preference is applied (handles the case where the user typed a risky char,
    /// then tabbed away without confirming).
    func controlTextDidEndEditing(_ obj: Notification) {
        triggerWarning.stringValue = ""
        let val = triggerField.stringValue
        if !val.isEmpty {
            DiscoPreferences.shared.triggerCharacter = val
        } else {
            // Field was cleared — revert display to the current saved value.
            triggerField.stringValue = DiscoPreferences.shared.triggerCharacter
        }
    }
}
