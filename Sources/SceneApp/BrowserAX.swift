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

    /// Voce di menu dell'app con scorciatoia ⌘ + lettera (senza altri modificatori), cercata
    /// per scorciatoia e non per nome, così funziona in ogni lingua.
    /// `modifiers`: modificatori oltre a ⌘ (1 = ⇧).
    static func menuItem(pid: pid_t, cmdChar: String, modifiers: Int = 0) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        guard let barRef = AX.attr(app, kAXMenuBarAttribute) else { return nil }
        let bar = barRef as! AXUIElement
        func search(_ menu: AXUIElement) -> AXUIElement? {
            kids(menu).first { item in
                (AX.attr(item, kAXMenuItemCmdCharAttribute) as? String)?.uppercased() == cmdChar.uppercased()
                    && (AX.attr(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue == modifiers
                    && AX.bool(item, kAXEnabledAttribute)
            }
        }
        let tops = kids(bar)
        for top in tops { for menu in kids(top) { if let i = search(menu) { return i } } }
        // Firefox riempie i menu solo quando vengono aperti: si apre per un attimo il menu File
        // (terzo della barra, dopo Apple e il nome dell'app) e si cerca lì.
        guard tops.count > 2, let menu = kids(tops[2]).first else { return nil }
        press(tops[2])
        usleep(150_000)
        if let i = search(menu) { return i }   // premerla chiude anche il menu
        AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        return nil
    }

    /// Firefox appena avviato non espone schede e pagine all'Accessibilità finché un client non
    /// lo chiede. Questa richiesta (la stessa delle utilità di sistema) lo fa partire.
    static func enableAccessibility(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    /// Da spegnere appena finito con le schede: finché è accesa Firefox ignora i cambi di
    /// posizione e dimensione fatti via Accessibilità (la finestra resterebbe dov'è).
    static func disableEnhancedUI(pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
    }

    /// Chiude una scheda con la sua crocetta (il primo pulsante dentro la scheda). Funziona anche
    /// quando Firefox non è l'app attiva, a differenza della voce di menu.
    @discardableResult
    static func closeTab(_ tab: AXUIElement) -> Bool {
        guard let b = kids(tab).first(where: { AX.string($0, kAXRoleAttribute) == kAXButtonRole }) else { return false }
        return press(b)
    }

    @discardableResult
    static func press(_ el: AXUIElement) -> Bool {
        AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }
}
