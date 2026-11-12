import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // só ícone na barra de menus, sem Dock
    withExtendedLifetime(delegate) {
        app.run()
    }
}
