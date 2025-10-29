import SwiftUI
import AppKit

// Explicit NSApplication bootstrap using NSHostingView.
// This avoids using the `@main` attribute and works with swift build.

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let contentView = ContentView()
let hosting = NSHostingView(rootView: contentView)

let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
    styleMask: [.titled, .closable, .resizable, .miniaturizable],
    backing: .buffered,
    defer: false
)
window.center()
window.title = "VoltAI"
window.contentView = hosting
window.makeKeyAndOrderFront(nil)

app.activate(ignoringOtherApps: true)
app.run()

