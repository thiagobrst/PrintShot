import AppKit
import SwiftUI

// Gera as imagens de divulgação usando o código real do PrintShot.
// Uso: PrintShotDemo <backdrop.png> <pasta-de-saída>

MainActor.assumeIsolated {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    let args = CommandLine.arguments
    let backdropURL = URL(fileURLWithPath: args[1])
    let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    guard let src = CGImageSourceCreateWithURL(backdropURL as CFURL, nil),
          let backdrop = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        print("não consegui abrir o backdrop"); exit(1)
    }
    let pointSize = NSSize(width: CGFloat(backdrop.width) / 2, height: CGFloat(backdrop.height) / 2)

    func pump(_ t: TimeInterval = 0.4) { RunLoop.current.run(until: Date().addingTimeInterval(t)) }

    func host(_ view: NSView) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: view.frame.width, height: view.frame.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = view
        w.orderFrontRegardless()
        return w
    }

    func capture(_ view: NSView, name: String) {
        view.layoutSubtreeIfNeeded()
        view.window?.displayIfNeeded()
        pump()
        CATransaction.flush()
        let scale: CGFloat = 2
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        // 1) via camadas (pega fundo, sombras, cantos arredondados)
        if let layer = view.layer,
           let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.scaleBy(x: scale, y: scale)
            if !layer.isGeometryFlipped && view.isFlipped {
                // nada: o render já respeita a geometria da camada
            }
            layer.render(in: ctx)
            if let img = ctx.makeImage() { save(img, outDir.appendingPathComponent("\(name).png")) }
        }
        // 2) via cacheDisplay (alternativa)
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: outDir.appendingPathComponent("\(name)-alt.png"))
            }
        }
        print("ok: \(name)")
    }

    func save(_ img: CGImage, _ url: URL) {
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // Coordenadas em pontos (tela de 1440×900).
    let red = NSColor.annotationRed
    let yellow = NSColor(hex: "#FFD60A")!
    let selection = CGRect(x: 140, y: 150, width: 1160, height: 650)
    let annotations: [Annotation] = [
        .rectangle(CGRect(x: 724, y: 180, width: 281, height: 132), red, 4),
        .arrow(CGPoint(x: 600, y: 425), CGPoint(x: 738, y: 588), red, 5),
        .text("Queda na semana 7 — investigar", CGPoint(x: 430, y: 378), red, 4),
        .marker([CGPoint(x: 1002, y: 410), CGPoint(x: 1292, y: 410)], yellow, 3),
    ]

    func makeOverlay() -> (OverlayView, NSWindow) {
        let v = OverlayView(frame: NSRect(origin: .zero, size: pointSize), screenshot: backdrop)
        return (v, host(v))
    }

    // 1. Selecionando a área
    do {
        let (v, w) = makeOverlay()
        v.applyDemoState(selection: CGRect(x: 140, y: 150, width: 760, height: 430), annotations: [], tool: nil, creating: true)
        capture(v, name: "01-selecionando"); w.orderOut(nil)
    }
    // 2. Anotado, com barras de ferramentas
    do {
        let (v, w) = makeOverlay()
        v.applyDemoState(selection: selection, annotations: annotations, tool: .arrow, lineWidth: 4)
        capture(v, name: "02-anotando"); w.orderOut(nil)
    }
    // 3. Paleta de cores aberta
    do {
        let (v, w) = makeOverlay()
        v.applyDemoState(selection: selection, annotations: annotations, tool: .text, showPalette: true, lineWidth: 5)
        capture(v, name: "03-paleta"); w.orderOut(nil)
    }
    // 4. Resultado exportado (o que vai para a área de transferência / arquivo)
    do {
        let (v, w) = makeOverlay()
        v.applyDemoState(selection: selection, annotations: annotations, tool: nil)
        if let out = v.renderSelection() { save(out.cgImage, outDir.appendingPathComponent("04-resultado.png")) }
        print("ok: 04-resultado"); w.orderOut(nil)
    }
    // 5. Preferências
    do {
        let model = PreferencesModel()
        model.hasScreenPermission = true
        model.primary = .f13
        model.secondary = .cmdShift2
        let hv = NSHostingView(rootView: PreferencesView(model: model))
        hv.frame = NSRect(origin: .zero, size: hv.fittingSize)
        let w = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: hv.frame.width, height: hv.frame.height),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Preferências do PrintShot"
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = hv
        w.orderFrontRegardless()
        pump(0.8)
        capture(hv, name: "05-preferencias")
        w.orderOut(nil)
    }
    exit(0)
}
