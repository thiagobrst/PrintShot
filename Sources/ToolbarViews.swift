import AppKit

// MARK: - Botão da barra

final class ToolbarButton: NSButton {
    private let handler: () -> Void

    var isActive = false { didSet { updateLook() } }

    init(symbol: String, tooltip: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(cfg)
        setup(tooltip: tooltip)
    }

    init(image: NSImage, tooltip: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        self.image = image
        setup(tooltip: tooltip)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    private func setup(tooltip: String) {
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        toolTip = tooltip
        refusesFirstResponder = true
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 6
        target = self
        action = #selector(fire)
        updateLook()
    }

    private func updateLook() {
        layer?.backgroundColor = isActive
            ? NSColor.systemBlue.withAlphaComponent(0.18).cgColor
            : NSColor.clear.cgColor
        contentTintColor = isActive ? .systemBlue : NSColor(white: 0.18, alpha: 1)
    }

    @objc private func fire() { handler() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

// MARK: - Barra de ferramentas

final class ToolbarView: NSView {
    enum Orientation { case vertical, horizontal }

    private let orientation: Orientation
    private var items: [NSView] = []
    private let pad: CGFloat = 4
    private let itemSize: CGFloat = 32
    private let gap: CGFloat = 2

    init(orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .aqua)
        layer?.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 0, alpha: 0.2).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var isFlipped: Bool { true }

    func add(_ v: NSView) {
        items.append(v)
        addSubview(v)
        relayout()
    }

    func addSeparator() {
        let sep = NSView(frame: .zero)
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 0, alpha: 0.12).cgColor
        sep.identifier = NSUserInterfaceItemIdentifier("separator")
        add(sep)
    }

    private func relayout() {
        var offset = pad
        for v in items {
            let isSep = v.identifier?.rawValue == "separator"
            let length = isSep ? 1 : itemSize
            switch orientation {
            case .vertical:
                v.frame = isSep
                    ? NSRect(x: pad + 4, y: offset + 2, width: itemSize - 8, height: 1)
                    : NSRect(x: pad, y: offset, width: itemSize, height: itemSize)
            case .horizontal:
                v.frame = isSep
                    ? NSRect(x: offset + 2, y: pad + 4, width: 1, height: itemSize - 8)
                    : NSRect(x: offset, y: pad, width: itemSize, height: itemSize)
            }
            offset += (isSep ? length + 4 : length) + gap
        }
        let total = offset - gap + pad
        let thickness = itemSize + 2 * pad
        setFrameSize(orientation == .vertical
                     ? NSSize(width: thickness, height: total)
                     : NSSize(width: total, height: thickness))
    }

    // Impede que cliques no fundo da barra comecem uma nova seleção.
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
}

// MARK: - Paleta de cores e espessura

final class PaletteView: NSView {
    static let colors: [NSColor] = [
        .annotationRed,
        NSColor(hex: "#FF8A00")!, NSColor(hex: "#FFD60A")!, NSColor(hex: "#30D158")!,
        NSColor(hex: "#0A84FF")!, NSColor(hex: "#BF5AF2")!, NSColor(hex: "#FF375F")!,
        .black, .white,
    ]
    static let widths: [CGFloat] = [2, 3, 5, 8]

    var selectedColor: NSColor = .annotationRed { didSet { needsDisplay = true } }
    var selectedWidth: CGFloat = 3 { didSet { needsDisplay = true } }
    var onColor: ((NSColor) -> Void)?
    var onWidth: ((CGFloat) -> Void)?
    var onCustomColor: (() -> Void)?

    private let pad: CGFloat = 10
    private let cell: CGFloat = 24
    private let spacing: CGFloat = 6
    private let columns = 5

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .aqua)
        layer?.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 0, alpha: 0.2).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 6
        layer?.masksToBounds = false
        let w = pad * 2 + CGFloat(columns) * cell + CGFloat(columns - 1) * spacing
        let h = pad * 2 + 3 * cell + 2 * spacing + 8
        setFrameSize(NSSize(width: w, height: h))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var isFlipped: Bool { true }

    private func colorRect(_ i: Int) -> NSRect {
        let col = i % columns, row = i / columns
        return NSRect(x: pad + CGFloat(col) * (cell + spacing),
                      y: pad + CGFloat(row) * (cell + spacing),
                      width: cell, height: cell)
    }

    private var customRect: NSRect { colorRect(Self.colors.count) }

    private func widthRect(_ i: Int) -> NSRect {
        let y = pad + 2 * (cell + spacing) + 8
        let totalW = bounds.width - 2 * pad
        let slot = totalW / CGFloat(Self.widths.count)
        return NSRect(x: pad + CGFloat(i) * slot, y: y, width: slot, height: cell)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, c) in Self.colors.enumerated() {
            let r = colorRect(i).insetBy(dx: 2, dy: 2)
            c.setFill()
            NSBezierPath(ovalIn: r).fill()
            NSColor(white: 0, alpha: 0.25).setStroke()
            let border = NSBezierPath(ovalIn: r)
            border.lineWidth = 0.5
            border.stroke()
            if c.hexString == selectedColor.hexString {
                NSColor.systemBlue.setStroke()
                let ring = NSBezierPath(ovalIn: colorRect(i).insetBy(dx: -1, dy: -1))
                ring.lineWidth = 2
                ring.stroke()
            }
        }
        // botão "mais cores"
        let cr = customRect.insetBy(dx: 2, dy: 2)
        let colors = [NSColor.systemRed, .systemYellow, .systemGreen, .systemBlue, .systemPurple]
        let gradient = NSGradient(colors: colors)
        gradient?.draw(in: NSBezierPath(ovalIn: cr), angle: 45)
        let plus = NSAttributedString(string: "+", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: NSColor.white,
        ])
        let ps = plus.size()
        plus.draw(at: NSPoint(x: cr.midX - ps.width / 2, y: cr.midY - ps.height / 2))

        // separador
        NSColor(white: 0, alpha: 0.12).setFill()
        NSRect(x: pad, y: pad + 2 * (cell + spacing) + 1, width: bounds.width - 2 * pad, height: 1).fill()

        // espessuras
        for (i, w) in Self.widths.enumerated() {
            let r = widthRect(i)
            if w == selectedWidth {
                NSColor.systemBlue.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 0), xRadius: 5, yRadius: 5).fill()
            }
            let d = max(4, w * 1.6)
            selectedColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (i, c) in Self.colors.enumerated() where colorRect(i).contains(p) {
            selectedColor = c
            onColor?(c)
            return
        }
        if customRect.contains(p) { onCustomColor?(); return }
        for (i, w) in Self.widths.enumerated() where widthRect(i).contains(p) {
            selectedWidth = w
            onWidth?(w)
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - Caixa de texto em edição

final class AnnotationTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.85).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: -3, dy: -2))
        border.lineWidth = 1
        border.setLineDash([4, 3], count: 2, phase: 0)
        border.stroke()
        super.draw(dirtyRect)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
}

// MARK: - Visão que não intercepta cliques

final class PassthroughView: NSView {
    var drawHandler: (() -> Void)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { drawHandler?() }
}

// MARK: - Fundo com a tela congelada (camada da GPU, sem redesenho a cada movimento)

final class ImageLayerView: NSView {
    private let image: CGImage

    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = image
        layer?.contentsGravity = .resize
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Aviso rápido ("Copiado!")

@MainActor
enum Toast {
    private static var window: NSPanel?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill") {
        window?.orderOut(nil)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 16, weight: .semibold)
        icon.contentTintColor = .systemGreen
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        let size = stack.fittingSize
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.visibleFrame.minY + 80,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 10
        bg.layer?.masksToBounds = true
        bg.appearance = NSAppearance(named: .vibrantDark)
        stack.frame = bg.bounds
        bg.addSubview(stack)
        panel.contentView = bg
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        window = panel

        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel.animator().alphaValue = 0 },
                                                 completionHandler: {
                MainActor.assumeIsolated {
                    panel.orderOut(nil)
                    if window === panel { window = nil }
                }
            })
        }
    }
}
