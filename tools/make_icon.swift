import Cocoa
// Icona di Scene, stile macOS Sequoia, colori neutri: tre finestre disposte a S.
// Materiali: superfici opache con gradiente morbido, bordino luminoso in alto,
// ombre portate brevi e sfumate tra i piani, vani "incisi" con ombra interna, grana leggera.
// Uso: make_icon <cartella>  →  <cartella>/AppIcon.iconset
let out = CommandLine.arguments[1]
let set = out + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// Forma delle icone macOS: rettangolo con angoli "continui" (curvatura continua),
/// come nel template Apple: 824×824 su 1024 con raggio ≈ 185 (22,5%).
/// Coefficienti degli angoli continui di Apple (UIBezierPath, cornerCurve .continuous).
func squirclePath(_ r: CGRect) -> CGPath {
    let R = min(r.width, r.height) * 0.225
    let p = CGMutablePath()
    // Ogni angolo: punto d'angolo, direzione di arrivo d1, direzione di uscita d2.
    // pt(u, v) = angolo − d1·u·R + d2·v·R
    let corners: [(CGPoint, CGVector, CGVector)] = [
        (CGPoint(x: r.maxX, y: r.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),  // alto destra
        (CGPoint(x: r.maxX, y: r.minY), CGVector(dx: 0, dy: -1), CGVector(dx: -1, dy: 0)), // basso destra
        (CGPoint(x: r.minX, y: r.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),  // basso sinistra
        (CGPoint(x: r.minX, y: r.maxY), CGVector(dx: 0, dy: 1), CGVector(dx: 1, dy: 0)),   // alto sinistra
    ]
    for (i, (c, d1, d2)) in corners.enumerated() {
        func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: c.x - d1.dx * u * R + d2.dx * v * R, y: c.y - d1.dy * u * R + d2.dy * v * R)
        }
        if i == 0 { p.move(to: pt(1.52866483, 0)) } else { p.addLine(to: pt(1.52866483, 0)) }
        p.addCurve(to: pt(0.66993427, 0.06549600), control1: pt(1.08849323, 0), control2: pt(0.86840689, 0.02065399))
        p.addLine(to: pt(0.63149399, 0.07491100))
        p.addCurve(to: pt(0.07491100, 0.63149399), control1: pt(0.37282392, 0.16905607), control2: pt(0.16905607, 0.37282392))
        p.addLine(to: pt(0.06549600, 0.66993427))
        p.addCurve(to: pt(0, 1.52866483), control1: pt(0.02065399, 0.86840689), control2: pt(0, 1.08849323))
    }
    p.closeSubpath()
    return p
}

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    func grad(_ cols: [CGColor], _ locs: [CGFloat]) -> CGGradient {
        CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)!
    }

    let m = s * 100 / 1024, side = s * 824 / 1024
    let rect = CGRect(x: m, y: m, width: side, height: side)
    let squircle = squirclePath(rect)

    // --- Ombra esterna dell'icona: ampia e tenue + stretta di contatto.
    for (off, blur, a) in [(0.014, 0.04, 0.28), (0.003, 0.006, 0.22)] as [(CGFloat, CGFloat, CGFloat)] {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * off), blur: s * blur, color: c(0, 0, 0, a))
        ctx.addPath(squircle); ctx.setFillColor(c(90, 92, 98)); ctx.fillPath()
        ctx.restoreGState()
    }

    // --- Base: grafite opaca, più chiara in alto.
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    ctx.drawLinearGradient(grad([c(120, 148, 218), c(99, 124, 195), c(83, 96, 179)], [0, 0.5, 1]),
                           start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.restoreGState()

    // Griglia 16×16 interna allo squircle (y verso l'alto).
    let u = side / 16
    func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: m + x * u, y: m + y * u, width: w * u, height: h * u)
    }
    let radius = u * 0.55
    func rr(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }

    /// Una finestra piena: ombra portata, materiale opaco con gradiente, barra del titolo
    /// separata da un filo inciso, bordino chiaro in alto e scuro in basso.
    func drawWindow(_ r: CGRect, bar: CGFloat, top: CGColor, bottom: CGColor, barTop: CGColor, barBottom: CGColor,
                    shadowAlpha: CGFloat) {
        let path = rr(r, radius)
        // Ombra portata: corta e scura vicino al bordo + lunga e diffusa.
        for (off, blur, a) in [(0.18, 0.25, shadowAlpha), (0.55, 1.1, shadowAlpha * 0.7)] as [(CGFloat, CGFloat, CGFloat)] {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -u * off), blur: u * blur, color: c(20, 20, 26, a * 0.55))
            ctx.addPath(path); ctx.setFillColor(bottom); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        // Corpo della finestra.
        ctx.drawLinearGradient(grad([top, bottom], [0, 1]),
                               start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.minY), options: [])
        // Barra del titolo, appena più scura.
        let barRect = CGRect(x: r.minX, y: r.maxY - bar * u, width: r.width, height: bar * u)
        ctx.saveGState()
        ctx.clip(to: barRect)
        ctx.drawLinearGradient(grad([barTop, barBottom], [0, 1]),
                               start: CGPoint(x: 0, y: barRect.maxY), end: CGPoint(x: 0, y: barRect.minY), options: [])
        ctx.restoreGState()
        // Filo inciso sotto la barra: ombra sopra, luce sotto.
        let line = max(1, u * 0.07)
        ctx.setFillColor(c(0, 0, 0, 0.16))
        ctx.fill(CGRect(x: r.minX, y: barRect.minY, width: r.width, height: line))
        ctx.setFillColor(c(255, 255, 255, 0.45))
        ctx.fill(CGRect(x: r.minX, y: barRect.minY - line, width: r.width, height: line))
        // Bordino: luce sul filo superiore, ombra sul filo inferiore.
        let lw = max(1, u * 0.09)
        ctx.addPath(rr(r.insetBy(dx: lw / 2, dy: lw / 2), radius)); ctx.setLineWidth(lw)
        ctx.replacePathWithStrokedPath(); ctx.clip()
        ctx.drawLinearGradient(grad([c(255, 255, 255, 0.75), c(255, 255, 255, 0), c(0, 0, 0, 0), c(0, 0, 0, 0.14)],
                                    [0, 0.3, 0.7, 1]),
                               start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.minY), options: [])
        ctx.restoreGState()
    }

    // Tre finestre che disegnano una S: piccola in alto a destra, alta al centro,
    // piccola in basso a sinistra. Margini dal bordo come nell'icona precedente.
    let margin: CGFloat = 2.8, gap: CGFloat = 0.65
    // Tre finestre della stessa larghezza.
    let small: CGFloat = (16 - 2 * margin - 2 * gap) / 3, center: CGFloat = small
    let smallH: CGFloat = 4.4, full: CGFloat = 16 - 2 * margin
    let left = R(margin, margin, small, smallH)
    let middle = R(margin + small + gap, margin, center, full)
    let right = R(16 - margin - small, 16 - margin - smallH, small, smallH)

    let gray = (c(255, 255, 255, 0.36), c(255, 255, 255, 0.29), c(255, 255, 255, 0.30), c(255, 255, 255, 0.26))
    let white = (c(255, 255, 255, 0.60), c(255, 255, 255, 0.50), c(255, 255, 255, 0.52), c(255, 255, 255, 0.46))
    drawWindow(left, bar: 1.0, top: gray.0, bottom: gray.1, barTop: gray.2, barBottom: gray.3, shadowAlpha: 0.38)
    drawWindow(right, bar: 1.0, top: gray.0, bottom: gray.1, barTop: gray.2, barBottom: gray.3, shadowAlpha: 0.38)
    drawWindow(middle, bar: 1.2, top: white.0, bottom: white.1, barTop: white.2, barBottom: white.3, shadowAlpha: 0.5)

    // --- Bordino dell'icona: luce sopra, ombra sotto.
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    ctx.addPath(squircle); ctx.setLineWidth(max(1, s * 0.006) * 2); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(grad([c(255, 255, 255, 0.55), c(255, 255, 255, 0), c(0, 0, 0, 0), c(0, 0, 0, 0.35)],
                                [0, 0.3, 0.75, 1]),
                           start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
    ctx.restoreGState()

    // --- Grana leggerissima (texture del materiale), solo dentro lo squircle.
    if px >= 128 {
        ctx.saveGState()
        ctx.addPath(squircle); ctx.clip()
        var seed: UInt64 = 0x5CE11E
        func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 40) / CGFloat(1 << 24) }
        let dot = max(1, s / 512)
        for _ in 0..<(px * px / 6) {
            let v = rnd()
            ctx.setFillColor(v > 0.5 ? c(255, 255, 255, 0.016) : c(0, 0, 0, 0.016))
            ctx.fill(CGRect(x: rect.minX + rnd() * side, y: rect.minY + rnd() * side, width: dot, height: dot))
        }
        ctx.restoreGState()
    }

    let img = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
