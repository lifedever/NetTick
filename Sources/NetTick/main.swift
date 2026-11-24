import AppKit

// .accessory：不占 Dock；打开主窗口时临时切成 .regular（见 MainWindowController）
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
