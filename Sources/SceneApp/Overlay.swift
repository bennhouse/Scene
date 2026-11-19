import Cocoa
import Combine

/// Avviso mentre Scene cattura o ripristina: un bordo che pulsa lentamente intorno a ogni
/// schermo e un pannellino in basso con lo stato. Le finestre seguono su tutti i desktop,
/// non ricevono clic (le richieste delle app restano utilizzabili) e non sono finestre
/// «vere» per la cattura (livello alto, app Scene esclusa).
@MainActor
final class ProgressOverlay {
    static let shared = ProgressOverlay()

    private var borders: [NSPanel] = []
    private var hud: NSPanel?
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    /// Terza riga: «Press Esc 3 times to stop», che diventa il contatore quando si preme Esc.
    private let hintLabel = NSTextField(labelWithString: "")
    private var statusSink: AnyCancellable?
    private var hintText = ""
    /// Fino a quando la terza riga mostra il contatore di Esc invece dell'indicazione.
    private var escapeUntil = Date.distantPast
    private var escapeStopping = false

    func show(title: String, status: Published<String>.Publisher, appPaths: [String], stopHint: Bool = false) {
        hide(animated: false)
        escapeUntil = .distantPast
        escapeStopping = false
        hintText = stopHint ? "Press Esc 3 times to stop" : ""
        let colors = AppColors.average(appPaths)
        for screen in NSScreen.screens { borders.append(makeBorder(on: screen, colors: colors)) }
        let main = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        hud = makeHUD(on: main, title: title)
        statusSink = status.receive(on: RunLoop.main).sink { [weak self] s in
            self?.detailLabel.stringValue = s.isEmpty ? "Please wait…" : s
        }
        for w in borders + [hud].compactMap({ $0 }) {
            w.alphaValue = 0
            w.orderFrontRegardless()
        }
        // Il bordo compare con una dissolvenza lenta, il pannello subito.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 1.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            for w in borders { w.animator().alphaValue = 1 }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            hud?.animator().alphaValue = 1
        }
    }

    private func showHint() {
        hintLabel.stringValue = hintText
        hintLabel.textColor = .tertiaryLabelColor
    }

    /// Contatore delle pressioni di Esc (1, 2 o 3) nella terza riga, al posto dell'indicazione:
    /// avvisa che altre pressioni fermano il ripristino. Torna l'indicazione dopo due secondi
    /// senza altre pressioni.
    func showEscape(count: Int) {
        guard hud != nil else { return }
        let dots = String(repeating: "●", count: count) + String(repeating: "○", count: 3 - count)
        if count >= 3 {
            escapeStopping = true
            hintLabel.stringValue = "\(dots)  Stopping the restore…"
        } else {
            let left = 3 - count
            hintLabel.stringValue = "\(dots)  Press Esc \(left) more time\(left == 1 ? "" : "s") to stop"
        }
        hintLabel.textColor = .systemOrange
        let until = Date().addingTimeInterval(2)
        escapeUntil = until
        guard count < 3 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) { [weak self] in
            guard let self, self.escapeUntil == until, !self.escapeStopping else { return }
            self.showHint()
        }
    }

    func hide(animated: Bool = true) {
        statusSink = nil
        let windows = borders + [hud].compactMap { $0 }
        borders = []; hud = nil
        guard !windows.isEmpty else { return }
        guard animated else { windows.forEach { $0.orderOut(nil) }; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            for w in windows { w.animator().alphaValue = 0 }
        }, completionHandler: {
            windows.forEach { $0.orderOut(nil) }
        })
    }

    // MARK: - Finestre

    private func panel(_ frame: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.level = .statusBar
        // Visibile su tutti i desktop: resta mentre Scene li attraversa.
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return p
    }

    /// Bordo dritto (senza angoli arrotondati) fatto dei colori medi delle icone delle app della
    /// scena, in fila dalla prima all'ultima e ripetuti 6 volte lungo il perimetro, sfumati l'uno
    /// nell'altro. I colori scorrono lentamente lungo il bordo e il bordo pulsa piano.
    private func makeBorder(on screen: NSScreen, colors: [NSColor]) -> NSPanel {
        let p = panel(screen.frame)
        let size = screen.frame.size
        let v = NSView(frame: NSRect(origin: .zero, size: size))
        v.wantsLayer = true
        guard let root = v.layer else { return p }

        let container = CALayer()
        container.frame = root.bounds
        root.addSublayer(container)

        // Gradiente conico centrato sullo schermo: lungo il bordo, i colori si susseguono per angolo.
        // È un quadrato grande quanto la diagonale, così ruotando copre sempre tutto lo schermo.
        let side = hypot(size.width, size.height)
        let gradient = CAGradientLayer()
        gradient.type = .conic
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: size.width / 2, y: size.height / 2)
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        var stops = Array(repeating: colors, count: 6).flatMap { $0 }
        stops.append(colors[0])   // chiude il giro senza salti
        gradient.colors = stops.map(\.cgColor)
        container.addSublayer(gradient)

        // Scorrimento lento: un giro completo in 90 secondi.
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 90
        spin.repeatCount = .infinity
        gradient.add(spin, forKey: "spin")

        // Solo la striscia del bordo, con gli angoli dritti.
        let width: CGFloat = 5
        let mask = CAShapeLayer()
        mask.frame = container.bounds
        mask.path = CGPath(rect: container.bounds.insetBy(dx: width / 2, dy: width / 2), transform: nil)
        mask.fillColor = nil
        mask.strokeColor = NSColor.black.cgColor
        mask.lineWidth = width
        container.mask = mask

        // Pulsazione lenta. Le animazioni girano nel server grafico: continuano anche se l'app è occupata.
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.5
        pulse.duration = 1.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        container.add(pulse, forKey: "pulse")

        p.contentView = v
        return p
    }

    private func makeHUD(on screen: NSScreen, title: String) -> NSPanel {
        let size = NSSize(width: 340, height: hintText.isEmpty ? 64 : 80)
        let vf = screen.visibleFrame
        // In alto al centro, sotto la barra dei menu, senza ombra né contorno.
        let frame = NSRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 14, width: size.width, height: size.height)
        let p = panel(frame)
        p.level = .statusBar + 1
        p.hasShadow = false

        let fx = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        // Angoli arrotondati con una maschera: anche lo sfondo sfocato segue la curva.
        let radius: CGFloat = 14
        fx.maskImage = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
            return true
        }.then {
            $0.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
            $0.resizingMode = .stretch
        }

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.usesThreadedAnimation = true
        spinner.startAnimation(nil)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        detailLabel.stringValue = "Please wait…"
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.lineBreakMode = .byTruncatingTail
        showHint()
        titleLabel.lineBreakMode = .byTruncatingTail
        let texts = NSStackView(views: hintText.isEmpty ? [titleLabel, detailLabel] : [titleLabel, detailLabel, hintLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        let row = NSStackView(views: [spinner, texts])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(lessThanOrEqualTo: fx.trailingAnchor, constant: -18),
            row.centerYAnchor.constraint(equalTo: fx.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 22),
            spinner.heightAnchor.constraint(equalToConstant: 22),
            texts.widthAnchor.constraint(lessThanOrEqualToConstant: size.width - 18 - 22 - 12 - 18),
        ])
        p.contentView = fx
        return p
    }
}

private extension NSImage {
    func then(_ f: (NSImage) -> Void) -> NSImage { f(self); return self }
}

/// Colore medio dell'icona di ogni app (pixel trasparenti esclusi), reso pastello.
enum AppColors {
    static func average(_ appPaths: [String]) -> [NSColor] {
        var seen = Set<String>()
        let colors = appPaths.filter { seen.insert($0).inserted }.compactMap(average(of:))
        if colors.count >= 2 { return colors }
        let fallback = [NSColor(deviceHue: 0.58, saturation: 0.3, brightness: 0.96, alpha: 1),
                        NSColor(deviceHue: 0.78, saturation: 0.25, brightness: 0.96, alpha: 1)]
        return colors + fallback.prefix(2 - colors.count)
    }

    static func average(of path: String) -> NSColor? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        let n = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()
        var r = 0.0, g = 0.0, b = 0.0, w = 0.0
        for y in 0..<n { for x in 0..<n {
            guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
            // I pixel colorati contano più di quelli grigi: il colore dell'icona, non il suo fondo.
            let sat = max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent)
            let k = 0.2 + sat
            r += c.redComponent * k; g += c.greenComponent * k; b += c.blueComponent * k; w += k
        } }
        guard w > 0 else { return nil }
        let avg = NSColor(deviceRed: r / w, green: g / w, blue: b / w, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        avg.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        // Pastello: tinta dell'icona, poca saturazione, molta luce. Calmo anche con tante app.
        return NSColor(deviceHue: h, saturation: min(0.38, s * 0.6), brightness: 0.96, alpha: 1)
    }
}
