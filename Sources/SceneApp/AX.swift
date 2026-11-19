import Cocoa
import ApplicationServices

/// Helper per l'Accessibility API.
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// L'Accessibilità di sistema risponde? A volte smette per qualche istante (errore
    /// «API disabilitata»): in quel caso non si legge nulla e non si deve chiudere nulla.
    static func responsive() -> Bool {
        var v: CFTypeRef?
        let e = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &v)
        return e != .apiDisabled && e != .notImplemented
    }

    /// Attende fino a `seconds` che l'Accessibilità risponda.
    static func waitResponsive(seconds: Double = 3) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if responsive() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return responsive()
    }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }

    static func bool(_ el: AXUIElement, _ name: String) -> Bool { (attr(el, name) as? Bool) ?? false }

    /// Finestre standard dell'app sul/i desktop visibili (AX non vede gli altri Space).
    /// `anyKind`: anche le finestre che l'app espone con un tipo insolito (il Project Manager di
    /// DaVinci Resolve è un «AXUnknown» senza pulsante di chiusura).
    /// `minimized`: anche le finestre ridotte nel Dock.
    static func windows(pid: pid_t, anyKind: Bool = false, minimized: Bool = false) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2.0)
        guard let list = attr(app, kAXWindowsAttribute) as? [AXUIElement] else { return [] }
        // Alcune app (es. Terminale) espongono le finestre normali come AXDialog.
        return list.filter {
            // Di tipo insolito vale solo se ha un titolo: le schermate di caricamento non ne hanno.
            (isWindow($0) || (anyKind && string($0, kAXRoleAttribute) == kAXWindowRole && !(title($0) ?? "").isEmpty))
                && (minimized || !bool($0, kAXMinimizedAttribute)) && !isFilePanel($0)
        }
    }

    /// I pannelli Apri e Salva non sono finestre di documenti: Anteprima, per esempio, mostra
    /// «Apri» quando parte senza file, e non va scambiato per una finestra della scena.
    static func isFilePanel(_ w: AXUIElement) -> Bool {
        ["open-panel", "save-panel"].contains(string(w, kAXIdentifierAttribute) ?? "")
    }

    private static func isWindow(_ w: AXUIElement) -> Bool {
        string(w, kAXRoleAttribute) == kAXWindowRole &&
        [kAXStandardWindowSubrole, kAXDialogSubrole].contains(string(w, kAXSubroleAttribute) ?? kAXStandardWindowSubrole)
    }

    /// Finestre dell'app su qualunque desktop, tramite token remoti (id elemento 0..<1500).
    /// Trova solo finestre che qualche client AX ha già interrogato almeno una volta:
    /// chi la usa deve confrontare il risultato con CGWindowList.
    static func remoteWindows(pid: pid_t) -> [AXUIElement] {
        guard remoteWindowsAvailable else { return [] }
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        var out: [AXUIElement] = []
        let deadline = Date().addingTimeInterval(0.5)
        for id: UInt64 in 0..<1500 {
            if id % 100 == 0 && Date() > deadline { break }
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
            guard let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(el, 0.3)
            if isWindow(el), !bool(el, kAXMinimizedAttribute) { out.append(el) }
        }
        return out
    }

    /// Finestre visibili più quelle raggiungibili sugli altri desktop, senza doppioni.
    static func allWindows(pid: pid_t) -> [AXUIElement] {
        var seen = Set<CGWindowID>()
        var out: [AXUIElement] = []
        for w in windows(pid: pid) + remoteWindows(pid: pid) {
            guard let id = windowID(w), seen.insert(id).inserted else { continue }
            out.append(w)
        }
        return out
    }

    /// La finestra mostra quel file? Usa AXDocument; se l'app non lo espone, il nome nel titolo.
    static func shows(_ el: AXUIElement, document path: String) -> Bool {
        if let d = documentPath(el) { return d == path }
        guard let t = title(el), !t.isEmpty else { return false }
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        return t.contains(name) || (stem.count >= 3 && t.contains(stem))
    }

    /// La finestra sta mostrando una richiesta (foglio "Vuoi salvare?" o dialogo dell'app)?
    static func hasPrompt(_ el: AXUIElement, pid: pid_t) -> Bool {
        if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement],
           kids.contains(where: { string($0, kAXRoleAttribute) == "AXSheet" }) { return true }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        let wins = attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return wins.contains { w in
            [kAXDialogSubrole, kAXSystemDialogSubrole].contains(string(w, kAXSubroleAttribute) ?? "")
                && windowID(w) != windowID(el) && bool(w, kAXModalAttribute)
        }
    }

    static func windowID(_ el: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        return _AXUIElementGetWindow(el, &wid) == .success && wid != 0 ? wid : nil
    }

    static func title(_ el: AXUIElement) -> String? { string(el, kAXTitleAttribute) }

    /// La finestra è di un'app a documenti (espone AXDocument) ma il suo documento non è mai
    /// stato salvato: non c'è un file da cercare dal titolo («Senza nome» non è un file).
    static func isUnsavedDocument(_ el: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(el, &names) == .success,
              (names as? [String])?.contains(kAXDocumentAttribute) == true else { return false }
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, kAXDocumentAttribute as CFString, &v) != .success || v == nil
    }

    static func documentPath(_ el: AXUIElement) -> String? {
        guard let s = string(el, kAXDocumentAttribute), let u = URL(string: s), u.isFileURL else { return nil }
        return u.path
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    /// Sposta/ridimensiona solo se serve: ogni scrittura fa ridisegnare la finestra.
    /// `sameDisplay`: la finestra resta sul suo monitor, quindi basta spostarla e poi
    /// ridimensionarla (due passaggi invece di tre, un movimento più pulito).
    @discardableResult
    static func setFrame(_ el: AXUIElement, _ r: CGRect, sameDisplay: Bool = false) -> Bool {
        if let f = frame(el), abs(f.minX - r.minX) <= 1, abs(f.minY - r.minY) <= 1,
           abs(f.width - r.width) <= 1, abs(f.height - r.height) <= 1 { return true }
        if let f = frame(el), abs(f.width - r.width) <= 1, abs(f.height - r.height) <= 1 {
            var pt = r.origin
            guard let pv = AXValueCreate(.cgPoint, &pt) else { return false }
            return AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pv) == .success
        }
        var pt = r.origin, sz = r.size
        guard let pv = AXValueCreate(.cgPoint, &pt), let sv = AXValueCreate(.cgSize, &sz) else { return false }
        if sameDisplay {
            let e = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pv)
            AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sv)
            return e == .success
        }
        // Dimensione, posizione, ancora dimensione: necessario quando si cambia monitor.
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sv)
        let e = AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pv)
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sv)
        return e == .success
    }

    /// La finestra ha modifiche non salvate? È il pallino nel pulsante rosso (AXEdited).
    /// Le app che salvano da sole (Pagine, TextEdit…) non lo mostrano: chiuderle non perde nulla.
    /// nil quando non si può sapere (nessun pulsante rosso o nessuna informazione).
    static func isEdited(_ el: AXUIElement) -> Bool? {
        guard let b = attr(el, kAXCloseButtonAttribute) else { return nil }
        return (attr(b as! AXUIElement, "AXEdited") as? NSNumber)?.boolValue
    }

    /// L'app sta mostrando una richiesta (per esempio «Vuoi salvare?») in una delle sue finestre?
    static func appHasPrompt(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        let wins = attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return wins.contains { w in
            if [kAXDialogSubrole, kAXSystemDialogSubrole].contains(string(w, kAXSubroleAttribute) ?? "") { return true }
            let kids = attr(w, kAXChildrenAttribute) as? [AXUIElement] ?? []
            return kids.contains { string($0, kAXRoleAttribute) == "AXSheet" }
        }
    }

    /// Un avviso dell'app (finestra di dialogo senza pulsante rosso ma con un pulsante Annulla),
    /// per esempio «Navigazione privata non disponibile» di Safari.
    static func alert(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        return (attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).first { w in
            string(w, kAXSubroleAttribute) == kAXDialogSubrole && attr(w, kAXCloseButtonAttribute) == nil
                && attr(w, kAXCancelButtonAttribute) != nil
        }
    }

    /// Preme Annulla in un avviso.
    static func cancel(_ alert: AXUIElement) {
        if let b = attr(alert, kAXCancelButtonAttribute) {
            AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString)
        }
    }

    /// Chiude premendo il pulsante rosso: l'app può chiedere di salvare.
    @discardableResult
    static func close(_ el: AXUIElement) -> Bool {
        guard let b = attr(el, kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString) == .success
    }
}
