import Cocoa
import ApplicationServices

// MARK: - API private CGS / AX (solo lettura)
// SIP resta attivo: queste funzioni leggono soltanto lo stato del WindowServer.

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: CGSConnectionID) -> CGSSpaceID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray

@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int32, _ wids: CFArray) -> CFArray

/// Privata: crea un elemento AX da un token remoto (pid + id elemento). Permette di
/// raggiungere finestre su desktop non visibili, che kAXWindows non restituisce.
@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

/// Privata ma in sola lettura: ricava il CGWindowID di una finestra AX.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

enum CGS {
    static let cid = CGSMainConnectionID()

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

    static func activeSpace() -> CGSSpaceID { CGSGetActiveSpace(cid) }

    static func managedDisplays() -> [ManagedDisplay] {
        guard let arr = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }
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
        let res = CGSCopySpacesForWindows(cid, 7, [NSNumber(value: wid)] as CFArray)
        return (res as? [NSNumber])?.map(\.uint64Value) ?? []
    }
}
