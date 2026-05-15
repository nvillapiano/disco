/// main.swift
/// Disco — system-wide emoji autocomplete
///
/// Entry point. Instantiates AppDelegate and starts the run loop.
/// NSApplicationMain is not used because Disco is built as a Swift Package
/// executable target, which requires a manual entry point.

import Cocoa

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
