import Cocoa

/// Argomenti di avvio per test automatici:
///   --selftest                verifica la mappatura tra configurazioni e termina
///   --dump <file.json>        cattura lo stato attuale in un file e termina
///   --import <file.json>      importa scene (file esportato, elenco o scena singola)
///   --export <file.json>      esporta tutte le scene
///   --save <nome>             salva la scena attuale con quel nome
///   --restore <nome>          ripristina la scena (--close-first [--close-mode all|scene])
///   --switch <uuid> <n>       porta il monitor al desktop n e torna indietro
///   --dry-not-included <nome> elenca cosa terrebbe/chiuderebbe «le finestre non incluse»
///   --block-cap <s>           tetto del blocco tastiera (default 8 s)
///   --setups                  scrive nel log la configurazione di monitor di ogni scena
///   --snapshot <cartella>     salva l'immagine della finestra attiva e non attiva (--dark: modalità scura)
///   --quit                    termina al termine delle azioni
enum CLI {
    static let args = ProcessInfo.processInfo.arguments

    static func value(_ flag: String, _ offset: Int = 1) -> String? {
        guard let i = args.firstIndex(of: flag), i + offset < args.count else { return nil }
        return args[i + offset]
    }

    @MainActor
    static func run(store: SceneStore, restorer: Restorer) async {
        guard args.count > 1 else { return }
        Log.write("CLI: \(args.dropFirst().joined(separator: " ")) · AX=\(AX.isTrusted)")
        if args.contains("--selftest") {
            let r = MappingTests.run()
            Log.write("Desktop shortcuts: left \(Prefs.shared.left.display), right \(Prefs.shared.right.display)")
            Log.write("SELFTEST " + (r.isEmpty ? "OK" : "FAILED:\n" + r.joined(separator: "\n")))
            NSApp.terminate(nil); return
        }
        if let path = value("--dump") {
            let s = Capture.current(name: "dump")
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try? enc.encode(s).write(to: URL(fileURLWithPath: path))
            Log.write("DUMP written to \(path)")
            NSApp.terminate(nil); return
        }
        if let dir = value("--snapshot") {
            // Fotografa la finestra di Scene attiva e non attiva (per controllare i colori).
            if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 800_000_000)
            snapshot(to: dir + "/active.png")
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            snapshot(to: dir + "/inactive.png")
            NSApp.terminate(nil); return
        }
        if args.contains("--setups") {
            for sc in store.scenes {
                Log.write("SETUP «\(sc.name)» \(sc.config.label) setup #\(store.setupIndex(sc)) [\(SceneStore.setupKey(sc))]")
            }
        }
        // Solo per abbassare il tetto del blocco tastiera (test), mai per alzarlo oltre 8 s.
        if let c = value("--block-cap").flatMap(Double.init) { InputBlocker.cap = min(max(c, 0), 8) }
        if let path = value("--import"), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            do { Log.write("IMPORT: \(try store.importData(data)) scenes") }
            catch { Log.write("IMPORT failed: \(error)") }
        }
        if let path = value("--export") {
            do { try store.exportData().write(to: URL(fileURLWithPath: path)); Log.write("EXPORT: \(store.scenes.count) scenes") }
            catch { Log.write("EXPORT failed: \(error)") }
        }
        if !CGS.supported {
            Log.write("PRIVATE API unavailable: missing \(CGS.missing) · save and restore disabled")
        }
        if let name = value("--save"), CGS.supported {
            if let old = store.scene(named: name) { store.delete(old.id) }
            store.add(await Capture.full(name: name, restorer: restorer))
        }
        if let uuid = value("--switch"), let n = value("--switch", 2).flatMap(Int.init) {
            let start = Topology.display(uuid: uuid)?.currentOrdinal ?? 1
            let ok = await restorer.switchDesktop(uuid, to: n)
            Log.write("SWITCH → \(n): \(ok) ora=\(Topology.display(uuid: uuid)?.currentOrdinal ?? -1)")
            let back = await restorer.switchDesktop(uuid, to: start)
            Log.write("SWITCH ← \(start): \(back)")
        }
        if let name = value("--dry-not-included"), let s = store.scene(named: name) {
            for line in restorer.describeNotIncluded(s) { Log.write("DRY " + line) }
        }
        if let name = value("--restore"), let s = store.scene(named: name) {
            await restorer.restore(s, closeFirst: args.contains("--close-first"),
                                   mode: CloseMode(rawValue: value("--close-mode") ?? "") ?? .scene)
        }
        if args.contains("--quit") { NSApp.terminate(nil) }
    }
}

/// Immagine della finestra principale di Scene, disegnata dalla finestra stessa
/// (barra del titolo compresa; non serve il permesso di registrazione schermo).
@MainActor
private func snapshot(to path: String) {
    guard let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
          let frameView = w.contentView?.superview,
          let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
    frameView.cacheDisplay(in: frameView.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

/// Test della mappatura tra configurazioni (topologia simulata: non serve staccare il monitor).
enum MappingTests {
    static func run() -> [String] {
        var fails: [String] = []
        func check(_ c: Bool, _ m: String) { if !c { fails.append(m) } }

        let ext = SavedDisplay(uuid: "EXT", isBuiltin: false, name: "Monitor",
                               frame: CGRect(x: 0, y: 0, width: 2304, height: 1296),
                               visibleFrame: CGRect(x: 0, y: 25, width: 2304, height: 1271),
                               desktopCount: 2, currentOrdinal: 1)
        let mac = SavedDisplay(uuid: "MAC", isBuiltin: true, name: "MacBook",
                               frame: CGRect(x: 2304, y: 94, width: 1280, height: 800),
                               visibleFrame: CGRect(x: 2304, y: 94, width: 1280, height: 800),
                               desktopCount: 1, currentOrdinal: 1)
        func win(_ d: SavedDisplay, _ ord: Int, _ rel: CGRect) -> SavedWindow {
            let vf = d.visibleFrame
            let f = CGRect(x: vf.minX + rel.minX * vf.width, y: vf.minY + rel.minY * vf.height,
                           width: rel.width * vf.width, height: rel.height * vf.height)
            return SavedWindow(bundleID: "x", appName: "X", appPath: "/", title: nil, displayUUID: d.uuid,
                               displayIsBuiltin: d.isBuiltin, desktopOrdinal: ord, frame: f, relFrame: rel,
                               content: WindowContent(), zIndex: 0)
        }
        let half = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let both = SavedScene(name: "t", created: Date(), config: .monitorPlusMac, displays: [ext, mac],
                              windows: [win(ext, 1, half), win(ext, 2, half), win(mac, 1, half)])

        // Stessa configurazione: posizioni assolute, stesso desktop.
        let tExt = Mapping.TargetDisplay(uuid: "EXT", isBuiltin: false, visibleFrame: ext.visibleFrame, desktopCount: 2, currentOrdinal: 1)
        let tMac1 = Mapping.TargetDisplay(uuid: "MAC", isBuiltin: true, visibleFrame: mac.visibleFrame, desktopCount: 1, currentOrdinal: 1)
        var p = Mapping.plan(both, on: [tExt, tMac1])
        check(p.map(\.ordinal) == [1, 2, 1], "same setup: desktop \(p.map(\.ordinal))")
        check(p.map(\.displayUUID) == ["EXT", "EXT", "MAC"], "same setup: display")
        check(p[0].frame == both.windows[0].frame.integral, "same setup: absolute frame")

        // Monitor + Mac → Solo Mac (Mac con 2 desktop, sul desktop 2).
        let tMacSolo = Mapping.TargetDisplay(uuid: "MAC", isBuiltin: true,
                                             visibleFrame: CGRect(x: 0, y: 25, width: 1280, height: 775),
                                             desktopCount: 2, currentOrdinal: 2)
        p = Mapping.plan(both, on: [tMacSolo])
        check(p.map(\.displayUUID) == ["MAC", "MAC", "MAC"], "→Mac only: everything on the Mac")
        check(p.map(\.ordinal) == [1, 2, 2], "→Mac only: desktop \(p.map(\.ordinal)) (expected 1,2,current=2)")
        check(p[0].frame == CGRect(x: 640, y: 25, width: 640, height: 775), "→Mac only: proportions \(p[0].frame)")

        // Solo Mac → Monitor + Mac.
        let macSolo = SavedDisplay(uuid: "MAC", isBuiltin: true, name: "MacBook",
                                   frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                                   visibleFrame: CGRect(x: 0, y: 25, width: 1280, height: 775),
                                   desktopCount: 2, currentOrdinal: 1)
        let solo = SavedScene(name: "s", created: Date(), config: .macOnly, displays: [macSolo],
                              windows: [win(macSolo, 1, half), win(macSolo, 2, half)])
        p = Mapping.plan(solo, on: [tExt, tMac1])
        check(p.map(\.displayUUID) == ["EXT", "EXT"], "→Monitor+Mac: Mac desktops on the monitor")
        check(p.map(\.ordinal) == [1, 2], "→Monitor+Mac: desktop \(p.map(\.ordinal))")
        check(p[1].frame == CGRect(x: 1152, y: 25, width: 1152, height: 1271), "→Monitor+Mac: proportions \(p[1].frame)")

        // Monitor esterno diverso (UUID nuovo): stesso ruolo, proporzioni.
        let tOther = Mapping.TargetDisplay(uuid: "EXT2", isBuiltin: false, visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055), desktopCount: 2, currentOrdinal: 1)
        p = Mapping.plan(both, on: [tOther, tMac1])
        check(p.map(\.displayUUID) == ["EXT2", "EXT2", "MAC"], "other monitor: \(p.map(\.displayUUID))")

        // Indirizzi delle schede: solo web/file, niente opzioni né javascript:.
        check(Restorer.safeURLs(["https://a.it", "http://b.it/x", "file:///tmp/c.html", "-headless",
                                 "--profile /tmp/x", "javascript:alert(1)", "data:text/html,x", "ftp://d"])
              == ["https://a.it", "http://b.it/x", "file:///tmp/c.html"], "URL filter")

        // Finestra oltre i bordi: resta nell'area visibile.
        check(Mapping.fit(CGRect(x: 3000, y: 0, width: 400, height: 400), in: CGRect(x: 0, y: 25, width: 1280, height: 775))
              == CGRect(x: 880, y: 25, width: 400, height: 400), "fit")
        return fails
    }
}
