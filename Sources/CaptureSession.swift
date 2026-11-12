import AppKit

/// Janela sem bordas que cobre um monitor inteiro. É um painel "não ativador",
/// então recebe teclado mesmo quando outro app está em primeiro plano.
final class OverlayWindow: NSPanel {
    let overlay: OverlayView

    init(shot: ScreenShot) {
        let frame = shot.screen.frame
        overlay = OverlayView(frame: NSRect(origin: .zero, size: frame.size), screenshot: shot.image)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = CaptureSession.overlayLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        contentView = overlay
        setFrame(frame, display: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Uma captura em andamento: uma janela por monitor.
@MainActor
final class CaptureSession {
    /// Acima da Dock e da barra de menus, mas abaixo de menus pop-up.
    static let overlayLevel = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)

    var onFinish: (() -> Void)?
    private var windows: [OverlayWindow] = []

    init(shots: [ScreenShot]) {
        windows = shots.map { OverlayWindow(shot: $0) }
        for w in windows { w.overlay.session = self }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        for w in windows { w.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        let target = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
        target?.makeKeyAndOrderFront(nil)
        if let target { target.makeFirstResponder(target.overlay) }
    }

    func selectionStarted(in view: OverlayView) {
        for w in windows where w.overlay !== view { w.overlay.reset() }
    }

    func cancel() { close() }

    func copy(from view: OverlayView) {
        guard let image = view.renderSelection() else { return }
        close()
        ImageExporter.copyToClipboard(image)
        Toast.show("Copiado para a área de transferência")
    }

    func save(from view: OverlayView) {
        guard let image = view.renderSelection() else { return }
        close()
        // Pequeno atraso para as janelas sumirem antes do painel de salvar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            MainActor.assumeIsolated { ImageExporter.save(image) }
        }
    }

    private func close() {
        if NSColorPanel.sharedColorPanelExists { NSColorPanel.shared.orderOut(nil) }
        for w in windows {
            w.overlay.session = nil
            w.orderOut(nil)
            w.close()
        }
        windows.removeAll()
        let finish = onFinish
        onFinish = nil
        finish?()
    }
}

// MARK: - Copiar / salvar

@MainActor
enum ImageExporter {
    static func data(for image: CapturedImage, format: ImageFormat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image.cgImage)
        rep.size = image.pointSize   // grava o DPI correto (144 em Retina)
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }

    static func copyToClipboard(_ image: CapturedImage) {
        let rep = NSBitmapImageRep(cgImage: image.cgImage)
        rep.size = image.pointSize
        let nsImage = NSImage(size: image.pointSize)
        nsImage.addRepresentation(rep)

        let item = NSPasteboardItem()
        if let png = rep.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
        if let tiff = nsImage.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }

    static func defaultFileName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "yyyy-MM-dd 'às' HH.mm.ss"
        return "Captura de Tela \(f.string(from: Date()))"
    }

    static func save(_ image: CapturedImage) {
        let settings = Settings.shared
        let format = settings.imageFormat
        let fileName = defaultFileName() + "." + format.fileExtension

        if settings.askWhereToSave {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSSavePanel()
            panel.title = "Salvar captura"
            panel.allowedContentTypes = [format.utType]
            panel.nameFieldStringValue = fileName
            panel.directoryURL = settings.lastSaveDirectory ?? settings.saveDirectory
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.level = .modalPanel
            guard panel.runModal() == .OK, let url = panel.url else { return }
            if write(image, format: format, to: url) {
                settings.lastSaveDirectory = url.deletingLastPathComponent()
                if settings.copyWhenSaving { copyToClipboard(image) }
            }
        } else {
            let dir = settings.saveDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = uniqueURL(in: dir, fileName: fileName)
            if write(image, format: format, to: url) {
                if settings.copyWhenSaving { copyToClipboard(image) }
                Toast.show("Salvo em \(dir.lastPathComponent)", symbol: "square.and.arrow.down.fill")
            }
        }
    }

    private static func uniqueURL(in dir: URL, fileName: String) -> URL {
        var url = dir.appendingPathComponent(fileName)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }

    @discardableResult
    private static func write(_ image: CapturedImage, format: ImageFormat, to url: URL) -> Bool {
        do {
            guard let data = data(for: image, format: format) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "Não foi possível salvar a captura"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return false
        }
    }
}
