import AppKit
import Carbon.HIToolbox

/// Imagem final já recortada e com as anotações aplicadas.
struct CapturedImage {
    let cgImage: CGImage
    let pointSize: NSSize
}

/// Tela de seleção/edição exibida sobre um monitor congelado.
final class OverlayView: NSView, NSTextViewDelegate {
    weak var session: CaptureSession?

    let screenshot: CGImage

    private(set) var selection: CGRect?
    private var annotations: [Annotation] = []
    private var redoStack: [Annotation] = []
    private var inProgress: Annotation?

    private var tool: Tool? { didSet { refreshToolButtons(); invalidateCursors() } }
    private var color: NSColor = Settings.shared.defaultColor { didSet { colorChanged() } }
    private var lineWidth: CGFloat = Settings.shared.lineWidth { didSet { widthChanged() } }

    private enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }
    private enum Drag {
        case none
        case creating(CGPoint)
        case moving(CGPoint, CGRect)
        case resizing(Handle, CGRect)
        case drawing(CGPoint)
    }
    private var drag: Drag = .none

    private let imageView: ImageLayerView
    private let canvas = PassthroughView()
    private let toolsBar = ToolbarView(orientation: .vertical)
    private let actionsBar = ToolbarView(orientation: .horizontal)
    private let palette = PaletteView()
    private var toolButtons: [Tool: ToolbarButton] = [:]
    private var colorButton: ToolbarButton!
    private var editingText: AnnotationTextView?
    private var transientMessage: String?
    private var transientTimer: Timer?

    // MARK: Init

    init(frame: NSRect, screenshot: CGImage) {
        self.screenshot = screenshot
        self.imageView = ImageLayerView(image: screenshot)
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .aqua)

        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)

        canvas.frame = bounds
        canvas.autoresizingMask = [.width, .height]
        canvas.drawHandler = { [weak self] in self?.drawCanvas() }
        addSubview(canvas)

        buildToolbars()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não suportado") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var isDraggingNewSelection: Bool {
        if case .creating = drag { return true }
        return false
    }

    // MARK: Barras

    private func buildToolbars() {
        for t in Tool.allCases {
            let b = ToolbarButton(symbol: t.symbol, tooltip: "\(t.title) (\(t.shortcut))") { [weak self] in
                self?.toggleTool(t)
            }
            toolButtons[t] = b
            toolsBar.add(b)
        }
        colorButton = ToolbarButton(image: swatchImage(), tooltip: "Cor e espessura") { [weak self] in
            self?.togglePalette()
        }
        toolsBar.add(colorButton)
        toolsBar.addSeparator()
        toolsBar.add(ToolbarButton(symbol: "arrow.uturn.backward", tooltip: "Desfazer (⌘Z)") { [weak self] in
            self?.undoAnnotation()
        })
        toolsBar.add(ToolbarButton(symbol: "arrow.uturn.forward", tooltip: "Refazer (⇧⌘Z)") { [weak self] in
            self?.redoAnnotation()
        })

        actionsBar.add(ToolbarButton(symbol: "doc.on.doc", tooltip: "Copiar para a área de transferência (⌘C ou ↩)") { [weak self] in
            self?.performCopy()
        })
        actionsBar.add(ToolbarButton(symbol: "square.and.arrow.down", tooltip: "Salvar (⌘S)") { [weak self] in
            self?.performSave()
        })
        actionsBar.addSeparator()
        actionsBar.add(ToolbarButton(symbol: "xmark", tooltip: "Fechar (Esc)") { [weak self] in
            self?.session?.cancel()
        })

        palette.selectedColor = color
        palette.selectedWidth = lineWidth
        palette.onColor = { [weak self] c in self?.color = c }
        palette.onWidth = { [weak self] w in self?.lineWidth = w }
        palette.onCustomColor = { [weak self] in self?.openColorPanel() }

        for v in [toolsBar, actionsBar, palette] as [NSView] {
            v.isHidden = true
            addSubview(v)
        }
    }

    private func swatchImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let c = color
        return NSImage(size: size, flipped: false) { r in
            c.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)).fill()
            NSColor(white: 0, alpha: 0.3).setStroke()
            let b = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
            b.lineWidth = 1
            b.stroke()
            return true
        }
    }

    private func refreshToolButtons() {
        for (t, b) in toolButtons { b.isActive = (t == tool) }
    }

    private func layoutBars() {
        guard let sel = selection, !isDraggingNewSelection, sel.width >= 1, sel.height >= 1 else {
            toolsBar.isHidden = true
            actionsBar.isHidden = true
            palette.isHidden = true
            return
        }
        toolsBar.isHidden = false
        actionsBar.isHidden = false
        let gap: CGFloat = 8

        var tf = toolsBar.frame
        if sel.maxX + gap + tf.width <= bounds.maxX - 2 {
            tf.origin.x = sel.maxX + gap
        } else if sel.minX - gap - tf.width >= bounds.minX + 2 {
            tf.origin.x = sel.minX - gap - tf.width
        } else {
            tf.origin.x = sel.maxX - tf.width - gap
        }
        tf.origin.y = min(max(sel.minY, bounds.minY + gap), bounds.maxY - tf.height - gap)
        toolsBar.frame = tf

        var af = actionsBar.frame
        af.origin.x = min(max(sel.maxX - af.width, bounds.minX + gap), bounds.maxX - af.width - gap)
        if sel.maxY + gap + af.height <= bounds.maxY - 2 {
            af.origin.y = sel.maxY + gap
        } else if sel.minY - gap - af.height >= bounds.minY + 2 {
            af.origin.y = sel.minY - gap - af.height
        } else {
            af.origin.y = sel.maxY - af.height - gap
        }
        if af.intersects(tf) {
            af.origin.x = max(bounds.minX + gap, tf.minX - gap - af.width)
        }
        actionsBar.frame = af

        if !palette.isHidden { positionPalette() }
    }

    private func positionPalette() {
        let tf = toolsBar.frame
        var pf = palette.frame
        let anchorY = tf.minY + colorButton.frame.minY
        if tf.minX - 8 - pf.width >= bounds.minX {
            pf.origin.x = tf.minX - 8 - pf.width
        } else {
            pf.origin.x = tf.maxX + 8
        }
        pf.origin.y = min(max(anchorY - 10, bounds.minY + 8), bounds.maxY - pf.height - 8)
        palette.frame = pf
    }

    private func togglePalette() {
        palette.isHidden.toggle()
        if !palette.isHidden {
            palette.selectedColor = color
            palette.selectedWidth = lineWidth
            positionPalette()
        }
    }

    private func openColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        panel.level = NSWindow.Level(rawValue: CaptureSession.overlayLevel.rawValue + 1)
        panel.orderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        color = sender.color
    }

    private func colorChanged() {
        colorButton?.image = swatchImage()
        palette.selectedColor = color
        if let tv = editingText {
            tv.textColor = color
            tv.insertionPointColor = color
        }
        Settings.shared.defaultColor = color
        canvas.needsDisplay = true
    }

    private func widthChanged() {
        palette.selectedWidth = lineWidth
        Settings.shared.lineWidth = lineWidth
        if let tv = editingText {
            tv.font = NSFont.systemFont(ofSize: Annotation.fontSize(forLineWidth: lineWidth), weight: .semibold)
            resizeTextView(tv)
        }
        canvas.needsDisplay = true
    }

    // MARK: Desenho

    private func drawCanvas() {
        let dim = NSColor(white: 0, alpha: 0.45)
        guard let sel = selection, sel.width > 0, sel.height > 0 else {
            dim.setFill()
            NSBezierPath(rect: bounds).fill()
            drawHint()
            return
        }

        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: sel))
        path.windingRule = .evenOdd
        dim.setFill()
        path.fill()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: sel).addClip()
        for a in annotations { a.draw() }
        inProgress?.draw()
        NSGraphicsContext.restoreGraphicsState()

        let border = NSBezierPath(rect: sel.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.stroke()
        border.setLineDash([5, 4], count: 2, phase: 0)
        NSColor(white: 0, alpha: 0.55).setStroke()
        border.stroke()

        if !isDraggingNewSelection {
            for h in Handle.allCases {
                let r = handleRect(h, in: sel)
                NSColor.white.setFill()
                NSBezierPath(rect: r).fill()
                NSColor(white: 0.2, alpha: 1).setStroke()
                let hb = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
                hb.lineWidth = 1
                hb.stroke()
            }
        }
        drawSizeLabel(for: sel)
        if let msg = transientMessage { drawBadge(msg, at: CGPoint(x: sel.midX, y: sel.midY), centered: true) }
    }

    private func drawHint() {
        drawBadge("Arraste para selecionar uma área  •  Esc para cancelar",
                  at: CGPoint(x: bounds.midX, y: bounds.midY), centered: true, fontSize: 15)
    }

    private func drawSizeLabel(for sel: CGRect) {
        let scale = CGFloat(screenshot.width) / max(bounds.width, 1)
        let text = "\(Int((sel.width * scale).rounded())) × \(Int((sel.height * scale).rounded()))"
        var origin = CGPoint(x: sel.minX, y: sel.minY - 26)
        if origin.y < bounds.minY + 2 { origin.y = sel.minY + 6; origin.x = sel.minX + 6 }
        drawBadge(text, at: origin, centered: false)
    }

    private func drawBadge(_ text: String, at p: CGPoint, centered: Bool, fontSize: CGFloat = 12) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        var r = NSRect(x: p.x, y: p.y, width: size.width + 14, height: size.height + 6)
        if centered { r.origin = CGPoint(x: p.x - r.width / 2, y: p.y - r.height / 2) }
        NSColor(white: 0, alpha: 0.72).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        s.draw(at: CGPoint(x: r.minX + 7, y: r.minY + 3))
    }

    // MARK: Geometria

    private func handleCenter(_ h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    private func handleRect(_ h: Handle, in r: CGRect) -> CGRect {
        let c = handleCenter(h, in: r)
        return CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
    }

    private func handle(at p: CGPoint) -> Handle? {
        guard let sel = selection else { return nil }
        // cantos têm prioridade
        let ordered: [Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft, .top, .right, .bottom, .left]
        for h in ordered {
            let c = handleCenter(h, in: sel)
            if abs(c.x - p.x) <= 7 && abs(c.y - p.y) <= 7 { return h }
        }
        return nil
    }

    private func resized(_ r: CGRect, handle h: Handle, to p: CGPoint) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch h {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        }
        return CGRect(corner: CGPoint(x: minX, y: minY), corner: CGPoint(x: maxX, y: maxY))
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    private func snapped(_ r: CGRect) -> CGRect {
        let s = window?.backingScaleFactor ?? 2
        let minX = (r.minX * s).rounded() / s, minY = (r.minY * s).rounded() / s
        let maxX = (r.maxX * s).rounded() / s, maxY = (r.maxY * s).rounded() / s
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(bounds)
    }

    private func point(_ event: NSEvent) -> CGPoint {
        clamp(convert(event.locationInWindow, from: nil))
    }

    // MARK: Cursores

    private func invalidateCursors() {
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        guard let sel = selection, editingText == nil else { return }
        let inner: NSCursor
        switch tool {
        case .none: inner = .openHand
        case .some(.text): inner = .iBeam
        case .some: inner = .crosshair
        }
        addCursorRect(sel, cursor: inner)
        for h in Handle.allCases {
            let cursor: NSCursor
            switch h {
            case .left, .right: cursor = .resizeLeftRight
            case .top, .bottom: cursor = .resizeUpDown
            default: cursor = .crosshair
            }
            addCursorRect(handleRect(h, in: sel).insetBy(dx: -3, dy: -3), cursor: cursor)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        let p = point(event)
        if !palette.isHidden { palette.isHidden = true }

        if editingText != nil {
            commitText()
            guard tool == .text, let sel = selection, sel.contains(p), handle(at: p) == nil else {
                window?.makeFirstResponder(self)
                return
            }
        }
        window?.makeFirstResponder(self)

        if let sel = selection {
            if let h = handle(at: p) {
                drag = .resizing(h, sel)
                return
            }
            if sel.contains(p) {
                if let tool {
                    if tool == .text {
                        beginText(at: p)
                    } else {
                        drag = .drawing(p)
                        inProgress = newAnnotation(tool, from: p, to: p)
                        canvas.needsDisplay = true
                    }
                } else {
                    drag = .moving(p, sel)
                    NSCursor.closedHand.set()
                }
                return
            }
            // fora da seleção com uma ferramenta ativa: não faz nada
            if tool != nil { return }
        }

        session?.selectionStarted(in: self)
        selection = CGRect(origin: p, size: .zero)
        drag = .creating(p)
        layoutBars()
        canvas.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .none:
            return
        case .creating(let start):
            let end = shift ? clamp(squareConstrained(from: start, to: p)) : p
            selection = snapped(CGRect(corner: start, corner: end))
        case .moving(let start, let orig):
            var r = orig.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(r.origin.x, bounds.minX), bounds.maxX - r.width)
            r.origin.y = min(max(r.origin.y, bounds.minY), bounds.maxY - r.height)
            selection = snapped(r)
        case .resizing(let h, let orig):
            selection = snapped(resized(orig, handle: h, to: p))
        case .drawing(let start):
            inProgress = updated(inProgress, start: start, to: p, shift: shift)
        }
        layoutBars()
        canvas.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .creating:
            if let s = selection, s.width < 4 || s.height < 4 { selection = nil }
        case .drawing:
            if let a = inProgress, a.isMeaningful {
                annotations.append(a)
                redoStack.removeAll()
            }
            inProgress = nil
        default:
            break
        }
        drag = .none
        layoutBars()
        invalidateCursors()
        canvas.needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        // botão direito: desfaz a seleção atual ou fecha
        if selection != nil && annotations.isEmpty {
            reset()
        } else if selection == nil {
            session?.cancel()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard selection != nil else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 8 : event.scrollingDeltaY
        guard abs(delta) >= 0.5 else { return }
        let newWidth = min(max(lineWidth + (delta > 0 ? 1 : -1), 1), 20)
        guard newWidth != lineWidth else { return }
        lineWidth = newWidth
        showTransient("Espessura: \(Int(lineWidth))")
    }

    private func showTransient(_ msg: String) {
        transientMessage = msg
        transientTimer?.invalidate()
        transientTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.transientMessage = nil
                self?.canvas.needsDisplay = true
            }
        }
        canvas.needsDisplay = true
    }

    // MARK: Anotações

    private func newAnnotation(_ tool: Tool, from a: CGPoint, to b: CGPoint) -> Annotation? {
        switch tool {
        case .pen: return .pen([a], color, lineWidth)
        case .marker: return .marker([a], color, lineWidth)
        case .line: return .line(a, b, color, lineWidth)
        case .arrow: return .arrow(a, b, color, lineWidth)
        case .rectangle: return .rectangle(CGRect(corner: a, corner: b), color, lineWidth)
        case .text: return nil
        }
    }

    private func updated(_ a: Annotation?, start: CGPoint, to p: CGPoint, shift: Bool) -> Annotation? {
        guard let a else { return nil }
        switch a {
        case .pen(var pts, let c, let w):
            if let last = pts.last, hypot(last.x - p.x, last.y - p.y) < 1 { return a }
            pts.append(p)
            return .pen(pts, c, w)
        case .marker(var pts, let c, let w):
            if shift, let first = pts.first {
                // Shift: marca-texto em linha reta horizontal
                return .marker([first, CGPoint(x: p.x, y: first.y)], c, w)
            }
            if let last = pts.last, hypot(last.x - p.x, last.y - p.y) < 1 { return a }
            pts.append(p)
            return .marker(pts, c, w)
        case .line(let s, _, let c, let w):
            return .line(s, shift ? angleConstrained(from: s, to: p) : p, c, w)
        case .arrow(let s, _, let c, let w):
            return .arrow(s, shift ? angleConstrained(from: s, to: p) : p, c, w)
        case .rectangle(_, let c, let w):
            return .rectangle(CGRect(corner: start, corner: shift ? squareConstrained(from: start, to: p) : p), c, w)
        case .text:
            return a
        }
    }

    private func toggleTool(_ t: Tool) {
        commitText()
        tool = (tool == t) ? nil : t
        window?.makeFirstResponder(self)
    }

    private func undoAnnotation() {
        commitText()
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        canvas.needsDisplay = true
    }

    private func redoAnnotation() {
        guard let a = redoStack.popLast() else { return }
        annotations.append(a)
        canvas.needsDisplay = true
    }

    // MARK: Texto

    private func beginText(at p: CGPoint) {
        let tv = AnnotationTextView(frame: NSRect(x: p.x, y: p.y - 4, width: 20, height: 20))
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                 height: CGFloat.greatestFiniteMagnitude)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.font = NSFont.systemFont(ofSize: Annotation.fontSize(forLineWidth: lineWidth), weight: .semibold)
        tv.textColor = color
        tv.insertionPointColor = color
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.delegate = self
        addSubview(tv)
        editingText = tv
        resizeTextView(tv)
        window?.makeFirstResponder(tv)
        invalidateCursors()
    }

    private func resizeTextView(_ tv: NSTextView) {
        guard let lm = tv.layoutManager, let tc = tv.textContainer, let font = tv.font else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let lineH = lm.defaultLineHeight(for: font)
        tv.setFrameSize(NSSize(width: max(ceil(used.width) + 6, 20), height: max(ceil(used.height), lineH)))
        tv.needsDisplay = true
    }

    func textDidChange(_ notification: Notification) {
        if let tv = editingText { resizeTextView(tv) }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                commitText()
                window?.makeFirstResponder(self)
            }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            commitText()
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    func commitText() {
        guard let tv = editingText else { return }
        editingText = nil
        let text = tv.string
        let origin = tv.frame.origin
        tv.delegate = nil
        tv.removeFromSuperview()
        let a = Annotation.text(text, origin, color, lineWidth)
        if a.isMeaningful {
            annotations.append(a)
            redoStack.removeAll()
        }
        invalidateCursors()
        canvas.needsDisplay = true
    }

    // MARK: Teclado

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard editingText == nil, window?.isKeyWindow == true else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch key {
        case "c": performCopy(); return true
        case "s": performSave(); return true
        case "z":
            if flags.contains(.shift) { redoAnnotation() } else { undoAnnotation() }
            return true
        case "a": selectAllScreen(); return true
        case "w": session?.cancel(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_Escape:
            if !palette.isHidden { palette.isHidden = true } else { session?.cancel() }
            return
        case kVK_Return, kVK_ANSI_KeypadEnter:
            performCopy()
            return
        case kVK_LeftArrow: nudge(dx: -step, dy: 0, resize: flags.contains(.option)); return
        case kVK_RightArrow: nudge(dx: step, dy: 0, resize: flags.contains(.option)); return
        case kVK_UpArrow: nudge(dx: 0, dy: -step, resize: flags.contains(.option)); return
        case kVK_DownArrow: nudge(dx: 0, dy: step, resize: flags.contains(.option)); return
        case kVK_Delete, kVK_ForwardDelete:
            undoAnnotation()
            return
        default:
            break
        }
        if selection != nil, flags.isDisjoint(with: [.command, .control, .option]),
           let t = Tool.forShortcut(event.charactersIgnoringModifiers ?? "") {
            toggleTool(t)
            return
        }
        super.keyDown(with: event)
    }

    /// Setas movem a seleção; com ⌥ redimensionam (lado direito/inferior).
    private func nudge(dx: CGFloat, dy: CGFloat, resize: Bool) {
        guard var r = selection else { return }
        if resize {
            r.size.width = max(4, r.width + dx)
            r.size.height = max(4, r.height + dy)
        } else {
            r = r.offsetBy(dx: dx, dy: dy)
            r.origin.x = min(max(r.origin.x, bounds.minX), bounds.maxX - r.width)
            r.origin.y = min(max(r.origin.y, bounds.minY), bounds.maxY - r.height)
        }
        selection = r.intersection(bounds)
        layoutBars()
        invalidateCursors()
        canvas.needsDisplay = true
    }

    private func selectAllScreen() {
        session?.selectionStarted(in: self)
        selection = bounds
        layoutBars()
        invalidateCursors()
        canvas.needsDisplay = true
    }

    // MARK: Ações

    private func performCopy() {
        guard selection != nil else { return }
        session?.copy(from: self)
    }

    private func performSave() {
        guard selection != nil else { return }
        session?.save(from: self)
    }

    /// Limpa a seleção (usado quando o usuário começa a selecionar em outro monitor).
    func reset() {
        commitText()
        selection = nil
        annotations.removeAll()
        redoStack.removeAll()
        inProgress = nil
        drag = .none
        palette.isHidden = true
        layoutBars()
        invalidateCursors()
        canvas.needsDisplay = true
    }

    // MARK: Modo demonstração (usado só pelo gerador de imagens de divulgação)

    func applyDemoState(selection: CGRect?, annotations: [Annotation], tool: Tool?,
                        creating: Bool = false, showPalette: Bool = false,
                        color: NSColor? = nil, lineWidth: CGFloat? = nil) {
        if let color { self.color = color }
        if let lineWidth { self.lineWidth = lineWidth }
        self.selection = selection
        self.annotations = annotations
        self.tool = tool
        drag = creating ? .creating(selection?.origin ?? .zero) : .none
        palette.isHidden = true
        layoutBars()
        if showPalette { togglePalette() }
        canvas.needsDisplay = true
    }

    // MARK: Exportação

    /// Recorta a área selecionada na resolução nativa (Retina) e aplica as anotações.
    func renderSelection() -> CapturedImage? {
        commitText()
        guard let sel = selection, sel.width >= 1, sel.height >= 1 else { return nil }
        let sx = CGFloat(screenshot.width) / bounds.width
        let sy = CGFloat(screenshot.height) / bounds.height
        let full = CGRect(x: 0, y: 0, width: screenshot.width, height: screenshot.height)
        let pixelRect = CGRect(x: sel.minX * sx, y: sel.minY * sy,
                               width: sel.width * sx, height: sel.height * sy).integral.intersection(full)
        let pw = Int(pixelRect.width), ph = Int(pixelRect.height)
        guard pw > 0, ph > 0, let cropped = screenshot.cropping(to: pixelRect) else { return nil }

        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = screenshot.colorSpace ?? srgb
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: bitmapInfo)
                ?? CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                             space: srgb, bitmapInfo: bitmapInfo)
        else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: pw, height: ph))

        if !annotations.isEmpty {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: pw, height: ph))
            ctx.translateBy(x: 0, y: CGFloat(ph))
            ctx.scaleBy(x: sx, y: -sy)
            ctx.translateBy(x: -pixelRect.minX / sx, y: -pixelRect.minY / sy)
            let nsctx = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsctx
            for a in annotations { a.draw() }
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        }

        guard let out = ctx.makeImage() else { return nil }
        return CapturedImage(cgImage: out, pointSize: NSSize(width: CGFloat(pw) / sx, height: CGFloat(ph) / sy))
    }
}
