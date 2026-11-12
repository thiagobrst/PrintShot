import AppKit

enum Tool: String, CaseIterable {
    case pen, line, arrow, rectangle, marker, text

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .marker: return "highlighter"
        case .text: return "textformat"
        }
    }

    var title: String {
        switch self {
        case .pen: return "Lápis"
        case .line: return "Linha"
        case .arrow: return "Seta"
        case .rectangle: return "Retângulo"
        case .marker: return "Marca-texto"
        case .text: return "Texto"
        }
    }

    var shortcut: String {
        switch self {
        case .pen: return "P"
        case .line: return "L"
        case .arrow: return "A"
        case .rectangle: return "R"
        case .marker: return "M"
        case .text: return "T"
        }
    }

    static func forShortcut(_ s: String) -> Tool? {
        allCases.first { $0.shortcut.lowercased() == s.lowercased() }
    }
}

/// Uma anotação desenhada sobre a captura. As coordenadas estão em pontos,
/// no sistema da tela inteira (origem no canto superior esquerdo).
enum Annotation {
    case pen([CGPoint], NSColor, CGFloat)
    case marker([CGPoint], NSColor, CGFloat)
    case line(CGPoint, CGPoint, NSColor, CGFloat)
    case arrow(CGPoint, CGPoint, NSColor, CGFloat)
    case rectangle(CGRect, NSColor, CGFloat)
    case text(String, CGPoint, NSColor, CGFloat)

    static func fontSize(forLineWidth w: CGFloat) -> CGFloat { 12 + w * 3.5 }

    static func textAttributes(color: NSColor, lineWidth: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize(forLineWidth: lineWidth), weight: .semibold),
            .foregroundColor: color,
        ]
    }

    var isMeaningful: Bool {
        switch self {
        case .pen(let pts, _, _), .marker(let pts, _, _): return !pts.isEmpty
        case .line(let a, let b, _, _), .arrow(let a, let b, _, _): return hypot(b.x - a.x, b.y - a.y) > 2
        case .rectangle(let r, _, _): return r.width > 2 && r.height > 2
        case .text(let s, _, _, _): return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func draw() {
        switch self {
        case let .pen(pts, color, w):
            color.setStroke()
            let p = Annotation.smoothPath(pts)
            p.lineWidth = w
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()

        case let .marker(pts, color, w):
            color.withAlphaComponent(0.38).setStroke()
            let p = Annotation.smoothPath(pts)
            p.lineWidth = max(10, w * 5)
            p.lineCapStyle = .square
            p.lineJoinStyle = .round
            p.stroke()

        case let .line(a, b, color, w):
            color.setStroke()
            let p = NSBezierPath()
            p.move(to: a)
            p.line(to: b)
            p.lineWidth = w
            p.lineCapStyle = .round
            p.stroke()

        case let .arrow(a, b, color, w):
            Annotation.drawArrow(from: a, to: b, color: color, width: w)

        case let .rectangle(r, color, w):
            color.setStroke()
            let p = NSBezierPath(rect: r)
            p.lineWidth = w
            p.lineJoinStyle = .miter
            p.stroke()

        case let .text(s, origin, color, w):
            NSAttributedString(string: s, attributes: Annotation.textAttributes(color: color, lineWidth: w))
                .draw(at: origin)
        }
    }

    // MARK: Desenho auxiliar

    static func smoothPath(_ pts: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 {
            path.line(to: first)
            return path
        }
        if pts.count == 2 {
            path.line(to: pts[1])
            return path
        }
        var current = first
        for i in 1..<(pts.count - 1) {
            let q = pts[i]
            let end = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            // curva quadrática convertida em cúbica
            let c1 = CGPoint(x: current.x + 2 / 3 * (q.x - current.x), y: current.y + 2 / 3 * (q.y - current.y))
            let c2 = CGPoint(x: end.x + 2 / 3 * (q.x - end.x), y: end.y + 2 / 3 * (q.y - end.y))
            path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
            current = end
        }
        path.line(to: pts[pts.count - 1])
        return path
    }

    static func drawArrow(from a: CGPoint, to b: CGPoint, color: NSColor, width w: CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return }
        let ux = dx / len, uy = dy / len
        let headLen = min(max(w * 4.5, 16), len)
        let headHalf = headLen * 0.45
        let base = CGPoint(x: b.x - ux * headLen, y: b.y - uy * headLen)
        let px = -uy, py = ux

        color.setStroke()
        color.setFill()

        // haste (termina um pouco dentro da ponta para não aparecer emenda)
        let shaftEnd = CGPoint(x: base.x + ux * headLen * 0.3, y: base.y + uy * headLen * 0.3)
        let shaft = NSBezierPath()
        shaft.move(to: a)
        shaft.line(to: shaftEnd)
        shaft.lineWidth = w
        shaft.lineCapStyle = .round
        shaft.stroke()

        let head = NSBezierPath()
        head.move(to: b)
        head.line(to: CGPoint(x: base.x + px * headHalf, y: base.y + py * headHalf))
        head.line(to: CGPoint(x: base.x - px * headHalf, y: base.y - py * headHalf))
        head.close()
        head.lineJoinStyle = .round
        head.lineWidth = 1
        head.fill()
        head.stroke()
    }
}

// MARK: - Geometria

extension CGRect {
    init(corner a: CGPoint, corner b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

func squareConstrained(from a: CGPoint, to b: CGPoint) -> CGPoint {
    let side = max(abs(b.x - a.x), abs(b.y - a.y))
    return CGPoint(x: a.x + (b.x >= a.x ? side : -side), y: a.y + (b.y >= a.y ? side : -side))
}

/// Restringe a linha a múltiplos de 45° (usado com Shift).
func angleConstrained(from a: CGPoint, to b: CGPoint) -> CGPoint {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = hypot(dx, dy)
    let step = CGFloat.pi / 4
    let angle = (atan2(dy, dx) / step).rounded() * step
    return CGPoint(x: a.x + cos(angle) * len, y: a.y + sin(angle) * len)
}
