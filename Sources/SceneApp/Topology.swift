import Cocoa

/// Un monitor collegato, con i suoi desktop. Coordinate CG globali (origine in alto a sinistra).
struct DisplayInfo: Equatable {
    let displayID: CGDirectDisplayID
    let uuid: String
    let isBuiltin: Bool
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let desktopSpaces: [CGSSpaceID]
    let currentSpace: CGSSpaceID

    var desktopCount: Int { desktopSpaces.count }
    /// 1-based: 1 = desktop più a sinistra in Mission Control.
    var currentOrdinal: Int? { desktopSpaces.firstIndex(of: currentSpace).map { $0 + 1 } }
}

enum Topology {
    static func uuidString(for id: CGDirectDisplayID) -> String {
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "\(id)" }
        return CFUUIDCreateString(nil, u) as String
    }

    /// Altezza dello schermo principale: serve a convertire coordinate Cocoa ↔ CG.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
    }

    static func cocoaToCG(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func displays() -> [DisplayInfo] { MainThread.sync { readDisplays() } }

    private static func readDisplays() -> [DisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        let managed = CGS.managedDisplays()
        return ids.prefix(Int(n)).compactMap { id in
            // Escludi i mirror secondari.
            if CGDisplayIsInMirrorSet(id) != 0 && CGDisplayMirrorsDisplay(id) != 0 { return nil }
            let uuid = uuidString(for: id)
            let screen = NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
            }
            let frame = CGDisplayBounds(id)
            let visible = screen.map { cocoaToCG($0.visibleFrame) } ?? frame
            let m = managed.first { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }
            return DisplayInfo(displayID: id, uuid: uuid, isBuiltin: CGDisplayIsBuiltin(id) != 0,
                               name: screen?.localizedName ?? (CGDisplayIsBuiltin(id) != 0 ? "MacBook" : "Monitor"),
                               frame: frame, visibleFrame: visible,
                               desktopSpaces: m?.desktops ?? [], currentSpace: m?.current ?? 0)
        }
    }

    static func config(of ds: [DisplayInfo]) -> ConfigKind {
        ds.contains { !$0.isBuiltin } ? .monitorPlusMac : .macOnly
    }

    /// In quale monitor/desktop (1-based) si trova uno Space.
    static func locate(space: CGSSpaceID, in ds: [DisplayInfo]) -> (DisplayInfo, Int)? {
        for d in ds {
            if let i = d.desktopSpaces.firstIndex(of: space) { return (d, i + 1) }
        }
        return nil
    }

    static func display(uuid: String) -> DisplayInfo? {
        displays().first { $0.uuid == uuid }
    }
}
