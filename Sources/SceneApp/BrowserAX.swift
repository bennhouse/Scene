import Cocoa

/// Schede di Firefox lette e controllate via Accessibilità (Firefox non ha AppleScript per le schede).
enum BrowserAX {
    static let firefox = "org.mozilla.firefox"

    private static func kids(_ e: AXUIElement) -> [AXUIElement] {
        (AX.attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func find(_ e: AXUIElement, depth: Int = 0, _ pred: (AXUIElement) -> Bool) -> [AXUIElement] {
        if depth > 22 { return [] }
        var out = pred(e) ? [e] : []
        for c in kids(e) { out += find(c, depth: depth + 1, pred) }
        return out
    }

    /// Pulsanti delle schede: il gruppo di schede con più pulsanti.
    static func tabButtons(_ w: AXUIElement) -> [AXUIElement] {
        find(w) { AX.string($0, kAXRoleAttribute) == "AXTabGroup" }
            .map { g in kids(g).filter { AX.string($0, kAXSubroleAttribute) == "AXTabButton" || AX.string($0, kAXRoleAttribute) == "AXRadioButton" } }
            .max { $0.count < $1.count } ?? []
    }

    static func currentURL(_ w: AXUIElement) -> String? {
        find(w) { AX.string($0, kAXRoleAttribute) == "AXWebArea" }
            .compactMap { AX.attr($0, "AXURL").map { "\($0)" } }
            .first { $0.hasPrefix("http") || $0.hasPrefix("file:") }
    }

    /// URL di tutte le schede e indice (1-based) di quella attiva. Seleziona le schede una alla
    /// volta per leggerne l'indirizzo, poi torna su quella di partenza.
    static func readTabs(_ w: AXUIElement) -> (urls: [String], active: Int?)? {
        let tabs = tabButtons(w)
        guard !tabs.isEmpty else {
            return currentURL(w).map { ([$0], 1) }
        }
        let active = tabs.firstIndex { (AX.attr($0, kAXValueAttribute) as? NSNumber)?.boolValue == true }
        var urls: [String] = []
        var last = currentURL(w)
        for (i, t) in tabs.enumerated() {
            if i != active {
                AXUIElementPerformAction(t, kAXPressAction as CFString)
                for _ in 0..<12 {
                    usleep(35_000)
                    if let u = currentURL(w), u != last { break }
                }
            } else if let a = active, i == a, tabs.count > 1, i > 0 {
                AXUIElementPerformAction(t, kAXPressAction as CFString); usleep(80_000)
            }
            let u = currentURL(w)
            if let u { urls.append(u); last = u }
        }
        if let a = active { AXUIElementPerformAction(tabs[a], kAXPressAction as CFString) }
        return urls.isEmpty ? nil : (urls, active.map { $0 + 1 })
    }

    static func selectTab(_ w: AXUIElement, index: Int) {
        let tabs = tabButtons(w)
        guard index >= 1, index <= tabs.count else { return }
        AXUIElementPerformAction(tabs[index - 1], kAXPressAction as CFString)
    }

    /// Apre una finestra di Firefox con quelle schede (comando remoto all'istanza aperta).
    static func runFirefox(app: URL, _ args: [String]) {
        // Solo il vero Firefox: identificativo verificato e eseguibile dichiarato dal suo bundle.
        guard let b = Bundle(url: app), b.bundleIdentifier == firefox, let exe = b.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
