import CoreGraphics

/// Dove va ogni finestra nella configurazione attuale. Funzione pura, testabile.
enum Mapping {
    struct TargetDisplay: Equatable {
        var uuid: String
        var isBuiltin: Bool
        var visibleFrame: CGRect
        var desktopCount: Int
        var currentOrdinal: Int
    }

    struct Placement: Equatable {
        var window: SavedWindow
        var displayUUID: String
        var ordinal: Int
        var frame: CGRect
    }

    static func plan(_ scene: SavedScene, on displays: [TargetDisplay]) -> [Placement] {
        guard !displays.isEmpty else { return [] }
        let hasExternal = displays.contains { !$0.isBuiltin }
        let current: ConfigKind = hasExternal ? .monitorPlusMac : .macOnly
        let builtin = displays.first { $0.isBuiltin }
        let external = displays.first { !$0.isBuiltin }

        return scene.windows.map { w in
            var target: TargetDisplay
            var ordinal = w.desktopOrdinal

            if w.displayIsBuiltin {
                switch (scene.config, current) {
                case (.monitorPlusMac, .macOnly):
                    // Finestre del Mac → desktop corrente del Mac.
                    target = builtin ?? displays[0]
                    ordinal = target.currentOrdinal
                case (.macOnly, .monitorPlusMac):
                    // Desktop 1/2 del Mac → desktop 1/2 del monitor esterno.
                    target = external ?? displays[0]
                default:
                    target = displays.first { $0.uuid == w.displayUUID } ?? builtin ?? displays[0]
                }
            } else {
                // Monitor esterno: stesso monitor, altrimenti un altro esterno,
                // altrimenti desktop 1/2 del monitor → desktop 1/2 del Mac.
                target = displays.first { $0.uuid == w.displayUUID } ?? external ?? builtin ?? displays[0]
            }
            ordinal = min(max(ordinal, 1), max(target.desktopCount, 1))

            let vf = target.visibleFrame
            let saved = scene.display(w.displayUUID)
            var frame: CGRect
            // Stesso monitor e stessa area utile (tollerando menubar/Dock): posizione assoluta.
            if target.uuid == w.displayUUID, let s = saved,
               abs(s.visibleFrame.width - vf.width) < 1, abs(s.visibleFrame.height - vf.height) <= 80 {
                frame = w.frame
            } else {
                // Ridimensionamento proporzionale.
                frame = CGRect(x: vf.minX + w.relFrame.minX * vf.width,
                               y: vf.minY + w.relFrame.minY * vf.height,
                               width: w.relFrame.width * vf.width,
                               height: w.relFrame.height * vf.height)
            }
            frame = fit(frame, in: vf)
            return Placement(window: w, displayUUID: target.uuid, ordinal: ordinal, frame: frame.integral)
        }
    }

    /// Tiene la finestra dentro l'area visibile del monitor.
    static func fit(_ r: CGRect, in vf: CGRect) -> CGRect {
        var f = r
        f.size.width = min(f.width, vf.width)
        f.size.height = min(f.height, vf.height)
        f.origin.x = min(max(f.minX, vf.minX), vf.maxX - f.width)
        f.origin.y = min(max(f.minY, vf.minY), vf.maxY - f.height)
        return f
    }
}
