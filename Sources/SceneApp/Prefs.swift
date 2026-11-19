import Cocoa

/// Scorciatoia da tastiera per cambiare desktop (come in Impostazioni › Tastiera › Abbreviazioni › Mission Control).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var flags: UInt64      // CGEventFlags.rawValue
    var display: String

    /// macOS defaults for "Move left/right a space": ⌃← and ⌃→.
    private static let arrowFlags = CGEventFlags([.maskControl, .maskNumericPad, .maskSecondaryFn]).rawValue
    static let macLeft = Shortcut(keyCode: 123, flags: arrowFlags, display: "⌃←")
    static let macRight = Shortcut(keyCode: 124, flags: arrowFlags, display: "⌃→")

    /// The shortcuts set in System Settings › Keyboard › Keyboard Shortcuts › Mission Control
    /// (symbolic hot keys 79 = move left a space, 81 = move right a space).
    static var defaultLeft: Shortcut { system(79) ?? macLeft }
    static var defaultRight: Shortcut { system(81) ?? macRight }

    static func system(_ id: Int) -> Shortcut? {
        guard let all = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
                .dictionary(forKey: "AppleSymbolicHotKeys"),
              let entry = all[String(id)] as? [String: Any],
              (entry["enabled"] as? Bool) ?? (entry["enabled"] as? Int == 1),
              let value = entry["value"] as? [String: Any],
              let params = value["parameters"] as? [Int], params.count == 3 else { return nil }
        let char = params[0], code = params[1], mods = UInt64(params[2])
        let f = CGEventFlags(rawValue: mods)
        var s = ""
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        let arrows: [Int: String] = [123: "←", 124: "→", 125: "↓", 126: "↑"]
        if let a = arrows[code] { s += a }
        else if char > 0, char < 65535, let u = UnicodeScalar(char) { s += String(Character(u)).uppercased() }
        else { s += "#\(code)" }
        return Shortcut(keyCode: UInt16(code), flags: mods, display: s)
    }

    init(keyCode: UInt16, flags: UInt64, display: String) {
        self.keyCode = keyCode; self.flags = flags; self.display = display
    }

    /// Da un evento di tastiera registrato nelle impostazioni.
    init?(event: NSEvent) {
        let m = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var f = CGEventFlags()
        var s = ""
        if m.contains(.control) { f.insert(.maskControl); s += "⌃" }
        if m.contains(.option) { f.insert(.maskAlternate); s += "⌥" }
        if m.contains(.shift) { f.insert(.maskShift); s += "⇧" }
        if m.contains(.command) { f.insert(.maskCommand); s += "⌘" }
        guard !f.isEmpty else { return nil }   // serve almeno un modificatore
        let arrows: [UInt16: String] = [123: "←", 124: "→", 125: "↓", 126: "↑"]
        if let a = arrows[event.keyCode] {
            f.insert(.maskNumericPad); f.insert(.maskSecondaryFn); s += a
        } else {
            s += (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
        self.init(keyCode: event.keyCode, flags: f.rawValue, display: s)
    }

    /// Preme la scorciatoia come farebbe una persona: modificatori giù, tasto giù e su, modificatori su.
    /// Il rilascio dei modificatori è indispensabile: senza, macOS li considera ancora premuti e
    /// un'app che si avvia in quel momento lo vede (Firefox con ⌥ premuto parte in Troubleshoot Mode).
    func post() {
        let src = CGEventSource(stateID: .hidSystemState)
        let all = CGEventFlags(rawValue: flags)
        let modifiers: [(CGEventFlags, CGKeyCode)] = [(.maskControl, 59), (.maskAlternate, 58),
                                                      (.maskShift, 56), (.maskCommand, 55)]
            .filter { all.contains($0.0) }
        func send(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { return }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: InputBlocker.marker)
            e.post(tap: .cghidEventTap)
        }
        var held = CGEventFlags()
        for (flag, key) in modifiers { held.insert(flag); send(key, down: true, flags: held) }
        send(keyCode, down: true, flags: all)
        send(keyCode, down: false, flags: all)
        for (flag, key) in modifiers.reversed() { held.remove(flag); send(key, down: false, flags: held) }
    }
}

/// Cosa chiudere prima di ripristinare, su ogni desktop toccato dalla scena.
enum CloseMode: String, CaseIterable, Identifiable {
    case notIncluded  // tutte le finestre tranne quelle della scena già aperte al loro posto
    case scene        // le finestre delle app che fanno parte della scena
    case all          // tutte le finestre di tutte le app
    var id: String { rawValue }
    var label: String {
        switch self {
        case .scene: return "the scene's windows"
        case .all: return "all windows"
        case .notIncluded: return "windows not in the scene"
        }
    }
}

final class Prefs: ObservableObject {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    @Published var left: Shortcut { didSet { save(left, "shortcutLeft") } }
    @Published var right: Shortcut { didSet { save(right, "shortcutRight") } }
    /// Pausa dopo ogni cambio di desktop (animazione), in secondi.
    @Published var settleDelay: Double { didSet { d.set(settleDelay, forKey: "settleDelay") } }
    @Published var closeFirst: Bool { didSet { d.set(closeFirst, forKey: "closeFirst") } }
    @Published var closeMode: CloseMode { didSet { d.set(closeMode.rawValue, forKey: "closeMode") } }

    private init() {
        let d = UserDefaults.standard
        func load(_ k: String) -> Shortcut? {
            d.data(forKey: k).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
        }
        left = load("shortcutLeft") ?? .defaultLeft
        right = load("shortcutRight") ?? .defaultRight
        settleDelay = d.object(forKey: "settleDelay") as? Double ?? 0.45
        closeFirst = d.bool(forKey: "closeFirst")
        closeMode = CloseMode(rawValue: d.string(forKey: "closeMode") ?? "") ?? .notIncluded
    }

    private func save(_ s: Shortcut, _ k: String) {
        d.set(try? JSONEncoder().encode(s), forKey: k)
    }
}
