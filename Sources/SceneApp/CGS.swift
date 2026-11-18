import Cocoa
import ApplicationServices

// MARK: - API private CGS / AX (solo lettura)
// SIP resta attivo: queste funzioni leggono soltanto lo stato del WindowServer.

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

// Le funzioni private non sono collegate in modo fisso: vengono cercate all'avvio.
// Se una versione futura di macOS ne toglie una, Scene si apre lo stesso e
// disattiva solo ciò che ne dipende (vedi CGS.missing e CGS.working).

private typealias FnMainConnection = @convention(c) () -> CGSConnectionID
private typealias FnActiveSpace = @convention(c) (CGSConnectionID) -> CGSSpaceID
private typealias FnManagedSpaces = @convention(c) (CGSConnectionID) -> Unmanaged<CFArray>?
private typealias FnSpacesForWindows = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
private typealias FnRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
private typealias FnGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

enum PrivateAPI {
    /// Per i test: SCENE_DISABLE_PRIVATE=nome1,nome2 finge che quei simboli non esistano.
    private static let disabled = Set((ProcessInfo.processInfo.environment["SCENE_DISABLE_PRIVATE"] ?? "")
        .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })

    /// RTLD_DEFAULT su macOS è (void *)-2: cerca in tutte le librerie già caricate.
    fileprivate static func load<T>(_ name: String, as _: T.Type) -> T? {
        guard !disabled.contains(name),
              let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else {
            missing.append(name)
            return nil
        }
        return unsafeBitCast(p, to: T.self)
    }

    /// Simboli privati che questa versione di macOS non ha.
    fileprivate(set) static var missing: [String] = []

    fileprivate static let mainConnection = load("CGSMainConnectionID", as: FnMainConnection.self)
    fileprivate static let activeSpace = load("CGSGetActiveSpace", as: FnActiveSpace.self)
    fileprivate static let managedSpaces = load("CGSCopyManagedDisplaySpaces", as: FnManagedSpaces.self)
    fileprivate static let spacesForWindows = load("CGSCopySpacesForWindows", as: FnSpacesForWindows.self)
    fileprivate static let remoteToken = load("_AXUIElementCreateWithRemoteToken", as: FnRemoteToken.self)
    fileprivate static let getWindow = load("_AXUIElementGetWindow", as: FnGetWindow.self)

    /// Carica tutto subito, così `missing` è completo.
    static func resolveAll() {
        _ = (mainConnection, activeSpace, managedSpaces, spacesForWindows, remoteToken, getWindow)
    }
}

/// Privata: crea un elemento AX da un token remoto (pid + id elemento). Permette di
/// raggiungere finestre su desktop non visibili, che kAXWindows non restituisce.
/// Facoltativa: senza, Scene visita i desktop per trovare le finestre.
func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>? {
    PrivateAPI.remoteToken?(token)
}

var remoteWindowsAvailable: Bool { PrivateAPI.remoteToken != nil }

/// Privata ma in sola lettura: ricava il CGWindowID di una finestra AX.
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError {
    PrivateAPI.getWindow?(element, wid) ?? .apiDisabled
}

enum CGS {
    static let cid: CGSConnectionID = PrivateAPI.mainConnection?() ?? 0

    /// Le funzioni indispensabili ci sono e rispondono in modo sensato? Se no, Scene non
    /// salva e non ripristina: senza sapere su quale desktop sta ogni finestra rischierebbe
    /// di chiudere o spostare le finestre sbagliate.
    static var working: Bool {
        PrivateAPI.resolveAll()
        let essential = PrivateAPI.missing.filter { $0 != "_AXUIElementCreateWithRemoteToken" }
        return essential.isEmpty && cid != 0 && activeSpace() != 0
            && managedDisplays().contains { !$0.desktops.isEmpty }
    }

    /// Calcolato una volta all'avvio.
    static let supported = working

    static var missing: [String] { PrivateAPI.resolveAll(); return PrivateAPI.missing }

    struct ManagedSpace {
        let id: CGSSpaceID
        let type: Int          // 0 = desktop utente, 4 = app a schermo intero
    }

    struct ManagedDisplay {
        let uuid: String
        let spaces: [ManagedSpace]
        let current: CGSSpaceID
        var desktops: [CGSSpaceID] { spaces.filter { $0.type == 0 }.map(\.id) }
    }

    static func activeSpace() -> CGSSpaceID { PrivateAPI.activeSpace?(cid) ?? 0 }

    static func managedDisplays() -> [ManagedDisplay] {
        guard let arr = PrivateAPI.managedSpaces?(cid)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            guard var uuid = d["Display Identifier"] as? String else { return nil }
            if uuid == "Main" {   // "Gli schermi hanno spazi separati" disattivato
                uuid = Topology.uuidString(for: CGMainDisplayID())
            }
            let spaces = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { s -> ManagedSpace? in
                guard let id = spaceID(s) else { return nil }
                return ManagedSpace(id: id, type: (s["type"] as? NSNumber)?.intValue ?? 0)
            }
            let cur = (d["Current Space"] as? [String: Any]).flatMap(spaceID) ?? 0
            return ManagedDisplay(uuid: uuid, spaces: spaces, current: cur)
        }
    }

    private static func spaceID(_ s: [String: Any]) -> CGSSpaceID? {
        if let n = s["id64"] as? NSNumber { return n.uint64Value }
        if let n = s["ManagedSpaceID"] as? NSNumber { return n.uint64Value }
        return nil
    }

    /// Space (desktop) a cui appartiene la finestra. mask 7 = tutti gli Space.
    static func spaces(forWindow wid: CGWindowID) -> [CGSSpaceID] {
        guard let res = PrivateAPI.spacesForWindows?(cid, 7, [NSNumber(value: wid)] as CFArray)?
            .takeRetainedValue() else { return [] }
        return (res as? [NSNumber])?.map(\.uint64Value) ?? []
    }
}
