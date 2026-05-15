/// DiscoPreferences.swift
/// Disco — system-wide emoji autocomplete
///
/// Thin UserDefaults wrapper that centralises all persistent user settings.
/// Access via the singleton `DiscoPreferences.shared`.
///
/// Current settings:
///   - triggerCharacter  — the character that activates the popup (default: ":")
///   - launchAtLogin     — whether Disco starts automatically on login (default: false)

import Foundation
import ServiceManagement

final class DiscoPreferences {
    static let shared = DiscoPreferences()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let triggerChar   = "com.disco.triggerChar"
        static let launchAtLogin = "com.disco.launchAtLogin"
    }

    private init() {}

    // MARK: - Trigger character

    /// The single character that starts an emoji search session.
    /// Defaults to ":" (Slack convention). Stored as a single-character string;
    /// the setter trims to the first character and rejects empty strings.
    var triggerCharacter: String {
        get { defaults.string(forKey: Key.triggerChar) ?? ":" }
        set {
            let val = String(newValue.prefix(1))
            defaults.set(val.isEmpty ? ":" : val, forKey: Key.triggerChar)
        }
    }

    // MARK: - Launch at login

    /// When true, registers Disco with macOS to launch automatically at login.
    /// Uses SMAppService (macOS 13+). On macOS 12, the toggle is a no-op
    /// (SMLoginItemSetEnabled requires a signed helper bundle).
    var launchAtLogin: Bool {
        get { defaults.bool(forKey: Key.launchAtLogin) }
        set {
            defaults.set(newValue, forKey: Key.launchAtLogin)
            applyLaunchAtLogin(newValue)
        }
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Disco: launch at login error: \(error)")
            }
        }
        // macOS 12 fallback: silently ignored.
        // SMLoginItemSetEnabled requires a code-signed helper bundle
        // which Disco doesn't ship. Launch at login is functional on 13+.
    }
}
