import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var captureItem: NSMenuItem!
    private var session: CaptureSession?
    private var isStartingCapture = false
    private var prefsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildStatusItem()

        HotKeyManager.shared.onPress = { [weak self] in self?.startCapture() }
        registerHotKeys(showErrors: true)
        NotificationCenter.default.addObserver(forName: Settings.hotKeysChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotKeys(showErrors: false) }
        }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        if !Settings.shared.hasLaunchedBefore {
            Settings.shared.hasLaunchedBefore = true
            openPreferences()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPreferences()
        return false
    }

    // MARK: Atalhos

    private func registerHotKeys(showErrors: Bool) {
        let combos = [Settings.shared.primaryHotKey, Settings.shared.secondaryHotKey].compactMap { $0 }
        let failed = HotKeyManager.shared.register(combos)
        updateCaptureItemTitle()
        if showErrors, !failed.isEmpty {
            let names = failed.map(\.displayString).joined(separator: ", ")
            let alert = NSAlert()
            alert.messageText = "Atalho indisponível"
            alert.informativeText = "Não foi possível registrar \(names). Outro app pode estar usando essa combinação. Escolha outro atalho nas Preferências."
            alert.runModal()
        }
    }

    private func updateCaptureItemTitle() {
        let names = [Settings.shared.primaryHotKey, Settings.shared.secondaryHotKey]
            .compactMap { $0?.displayString }
        captureItem?.title = names.isEmpty ? "Capturar área" : "Capturar área   (\(names.joined(separator: " ou ")))"
    }

    // MARK: Menus

    private func buildMainMenu() {
        // Não aparece (app de barra de menus), mas habilita ⌘C/⌘V/⌘Z na caixa de texto.
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Preferências…", action: #selector(openPreferences), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Sair do PrintShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Editar")
        edit.addItem(withTitle: "Desfazer", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Refazer", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Recortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Selecionar Tudo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "PrintShot")
            img?.isTemplate = true
            button.image = img
            button.toolTip = "PrintShot — clique para capturar, clique direito para o menu"
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        captureItem = NSMenuItem(title: "Capturar área", action: #selector(captureFromMenu), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(.separator())
        let prefs = NSMenuItem(title: "Preferências…", action: #selector(openPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        let folder = NSMenuItem(title: "Abrir pasta de capturas", action: #selector(openSaveFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Sair do PrintShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.delegate = self
        updateCaptureItemTitle()
    }

    @objc private func statusButtonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
            || event?.modifierFlags.contains(.option) == true
        if wantsMenu {
            statusItem.menu = menu
            sender.performClick(nil)
        } else {
            startCapture()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil   // volta a capturar no clique esquerdo
    }

    @objc private func captureFromMenu() {
        // espera o menu desaparecer para não sair na captura
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            MainActor.assumeIsolated { self.startCapture() }
        }
    }

    @objc private func openSaveFolder() {
        let dir = Settings.shared.lastSaveDirectory ?? Settings.shared.saveDirectory
        NSWorkspace.shared.open(dir)
    }

    @objc func openPreferences() {
        if prefsWindow == nil {
            let host = NSHostingController(rootView: PreferencesView(model: PreferencesModel()))
            let w = NSWindow(contentViewController: host)
            w.title = "Preferências do PrintShot"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            prefsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        prefsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Captura

    func startCapture() {
        guard session == nil, !isStartingCapture else { return }
        guard CGPreflightScreenCaptureAccess() else {
            showPermissionAlert(nil)
            return
        }
        isStartingCapture = true
        prefsWindow?.orderOut(nil)
        Task { @MainActor in
            defer { self.isStartingCapture = false }
            do {
                let shots = try await ScreenCapturer.captureAllScreens()
                let s = CaptureSession(shots: shots)
                s.onFinish = { [weak self] in self?.session = nil }
                self.session = s
                s.show()
            } catch {
                self.showPermissionAlert(error)
            }
        }
    }

    private func showPermissionAlert(_ error: Error?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "O PrintShot precisa de permissão de Gravação de Tela"
        var info = "Abra Ajustes do Sistema › Privacidade e Segurança › Gravação de Tela e Áudio do Sistema, ative o PrintShot e reabra o app."
        if let error { info += "\n\nDetalhe: \(error.localizedDescription)" }
        alert.informativeText = info
        alert.addButton(withTitle: "Abrir Ajustes")
        alert.addButton(withTitle: "Cancelar")
        if alert.runModal() == .alertFirstButtonReturn {
            CGRequestScreenCaptureAccess()
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
