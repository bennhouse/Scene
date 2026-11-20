import Foundation
import CoreGraphics

enum ConfigKind: String, Codable {
    case monitorPlusMac
    case macOnly

    var label: String {
        switch self {
        case .monitorPlusMac: return "Monitor + Mac"
        case .macOnly: return "Mac Only"
        }
    }
}

struct SavedDisplay: Codable, Hashable {
    var uuid: String
    var isBuiltin: Bool
    var name: String
    var frame: CGRect          // CG globale
    var visibleFrame: CGRect   // CG globale
    var desktopCount: Int
    var currentOrdinal: Int    // desktop attivo al momento del salvataggio
}

struct WindowContent: Codable, Hashable {
    var documentPath: String?   // AXDocument, oppure ricavato dal titolo
    var documentFromTitle: Bool? // true se il percorso è stato dedotto dal titolo
    var folderPath: String?     // Finder
    var urls: [String]?         // schede Safari / Chrome
    var activeTab: Int?         // 1-based
    var privateWindow: Bool?    // finestra anonima / privata / in incognito

    var isEmpty: Bool { documentPath == nil && folderPath == nil && (urls ?? []).isEmpty }

    var summary: String? {
        if let p = folderPath { return p }
        if let d = documentPath { return d }
        if let u = urls, !u.isEmpty { return u.count == 1 ? u[0] : "\(u.count) tabs · \(u[0])" }
        return nil
    }
}

struct SavedWindow: Codable, Hashable, Identifiable {
    var id = UUID()
    var bundleID: String
    var appName: String
    var appPath: String
    var title: String?
    var displayUUID: String
    var displayIsBuiltin: Bool
    var desktopOrdinal: Int     // 1-based tra i desktop di quel monitor
    var frame: CGRect           // CG globale, assoluto
    var relFrame: CGRect        // frazioni del visibleFrame del monitor
    var content: WindowContent
    var zIndex: Int             // 0 = in primo piano
    var minimized: Bool?        // ridotta nel Dock (nil nelle scene salvate prima)
}

struct SavedScene: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var icon: String?           // SF Symbol
    var created: Date
    var config: ConfigKind
    var displays: [SavedDisplay]
    var windows: [SavedWindow]

    func display(_ uuid: String) -> SavedDisplay? { displays.first { $0.uuid == uuid } }

    /// Senza i pannelli: finestre senza titolo né contenuto che stanno dentro una finestra con
    /// titolo della stessa app, sullo stesso desktop. Lightroom Classic, per esempio, disegna
    /// barra dei moduli, filmstrip e pannelli laterali come finestre separate: salvate come
    /// finestre a sé, al ripristino rimpicciolivano la finestra principale e la si cercava
    /// all'infinito.
    func withoutPanels() -> SavedScene {
        var s = self
        s.windows = windows.filter { w in
            guard (w.title ?? "").isEmpty, w.content.isEmpty else { return true }
            return !windows.contains { o in
                o.id != w.id && o.bundleID == w.bundleID && o.displayUUID == w.displayUUID &&
                o.desktopOrdinal == w.desktopOrdinal && !(o.title ?? "").isEmpty &&
                o.frame.insetBy(dx: -2, dy: -2).contains(w.frame)
            }
        }
        return s
    }
}
