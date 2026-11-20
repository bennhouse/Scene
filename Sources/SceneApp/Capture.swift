import Cocoa

/// Legge lo stato attuale: app, finestre, monitor, desktop, contenuti.
enum Capture {
    /// Cattura completa. Le finestre sugli altri desktop si leggono tramite AX remoto, senza
    /// cambiare desktop. Solo se qualcuna resta irraggiungibile (AX non l'ha mai vista) Scene
    /// passa brevemente da quel desktop per leggerne titolo e documento, poi torna indietro.
    @MainActor
    static func full(name: String, restorer: Restorer) async -> SavedScene {
        restorer.status = "Reading windows…"
        ProgressOverlay.shared.show(title: "Capturing «\(name)»", status: restorer.$status,
                                   appPaths: NSWorkspace.shared.runningApplications
                                       .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                                       .compactMap { $0.bundleURL?.path })
        defer { restorer.status = ""; ProgressOverlay.shared.hide() }
        if AX.isTrusted, !(await offMain { AX.waitResponsive() }) {
            Log.write("Capture: Accessibility not responding, titles and documents not read")
        }
        // Lettura delle finestre fuori dal thread principale: l'interfaccia resta reattiva.
        var (scene, wids) = await offMain { () -> (SavedScene, [UUID: CGWindowID]) in
            var ids: [UUID: CGWindowID] = [:]
            let s = current(name: name, windowIDs: &ids)
            return (s, ids)
        }
        guard AX.isTrusted, !restorer.isRunning else { return scene.withoutPanels() }
        let start = Dictionary(uniqueKeysWithValues: scene.displays.map { ($0.uuid, $0.currentOrdinal) })
        // Da leggere sul loro desktop: le finestre senza titolo e quelle di Firefox di cui non si
        // sono lette le schede (Firefox le mostra solo per le finestre del desktop visibile).
        func needsVisit(_ w: SavedWindow) -> Bool {
            w.title == nil || (w.bundleID == BrowserAX.firefox && (w.content.urls ?? []).isEmpty)
        }
        let pending = scene.windows.filter { $0.desktopOrdinal != start[$0.displayUUID] && needsVisit($0) }
        guard !pending.isEmpty else { return scene.withoutPanels() }

        restorer.isRunning = true
        InputBlocker.shared.begin(maxSeconds: InputBlocker.cap)
        defer { InputBlocker.shared.end(); restorer.isRunning = false }
        let pointer = CGEvent(source: nil)?.location ?? .zero
        let stops = Set(pending.map { "\($0.displayUUID)|\($0.desktopOrdinal)" }).sorted()
        for stop in stops {
            let parts = stop.split(separator: "|")
            let uuid = String(parts[0]), ord = Int(parts[1]) ?? 1
            guard await restorer.switchDesktop(uuid, to: ord) else { continue }
            for (i, w) in scene.windows.enumerated()
            where w.displayUUID == uuid && w.desktopOrdinal == ord && needsVisit(w) {
                guard let wid = wids[w.id],
                      let el = NSRunningApplication.runningApplications(withBundleIdentifier: w.bundleID)
                        .flatMap({ AX.windows(pid: $0.processIdentifier) }).first(where: { AX.windowID($0) == wid })
                else { continue }
                let t = AX.title(el) ?? w.title
                scene.windows[i].title = t
                if w.bundleID == BrowserAX.firefox, (w.content.urls ?? []).isEmpty {
                    var pid: pid_t = 0
                    AXUIElementGetPid(el, &pid)
                    if BrowserAX.tabButtons(el).isEmpty {
                        BrowserAX.enableAccessibility(pid: pid)
                        for _ in 0..<20 where BrowserAX.tabButtons(el).isEmpty { try? await Task.sleep(nanoseconds: 150_000_000) }
                    }
                    if let tabs = BrowserAX.readTabs(el) {
                        scene.windows[i].content.urls = tabs.urls
                        scene.windows[i].content.activeTab = tabs.active
                    }
                    BrowserAX.disableEnhancedUI(pid: pid)
                    continue
                }
                if scene.windows[i].content.documentPath == nil {
                    if let d = AX.documentPath(el) {
                        scene.windows[i].content.documentPath = d
                    } else if let t, !AX.isUnsavedDocument(el),
                              let d = DocResolver.resolve(title: t, appName: w.appName, appURL: URL(fileURLWithPath: w.appPath)) {
                        scene.windows[i].content.documentPath = d
                        scene.windows[i].content.documentFromTitle = true
                    }
                }
            }
        }
        for (uuid, o) in start where Topology.display(uuid: uuid)?.currentOrdinal != o {
            _ = await restorer.switchDesktop(uuid, to: o)
        }
        restorer.warp(to: pointer)
        Log.write("Capture «\(name)»: \(pending.count) windows read by visiting their desktop")
        return scene.withoutPanels()
    }

    static func current(name: String) -> SavedScene {
        var ignored: [UUID: CGWindowID] = [:]
        return current(name: name, windowIDs: &ignored)
    }

    static func current(name: String, windowIDs: inout [UUID: CGWindowID]) -> SavedScene {
        let displays = Topology.displays()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let info = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]]) ?? []

        // Arricchimento AX (solo finestre sui desktop visibili): titolo e documento.
        var axByWID: [CGWindowID: (title: String?, doc: String?)] = [:]
        // Finestre di documenti mai salvati: non si cerca un file dal loro titolo.
        var unsaved = Set<CGWindowID>()
        // Finestre ridotte nel Dock: si salvano con titolo e documento, e tornano ridotte.
        var minimized = Set<CGWindowID>()
        var axFramesByPID: [pid_t: [(CGRect, String?, String?)]] = [:]
        if AX.isTrusted {
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != ownPID {
                for w in AX.windows(pid: app.processIdentifier, minimized: true) {
                    let t = AX.title(w), d = AX.documentPath(w)
                    if let wid = AX.windowID(w) {
                        axByWID[wid] = (t, d)
                        if AX.isUnsavedDocument(w) { unsaved.insert(wid) }
                        if AX.bool(w, kAXMinimizedAttribute) { minimized.insert(wid) }
                    }
                    if let f = AX.frame(w) { axFramesByPID[app.processIdentifier, default: []].append((f, t, d)) }
                }
            }
        }

        // Contenuti via AppleScript (anche per finestre su altri desktop).
        let scripted: [String: [Scripting.ScriptWindow]] = [
            Scripting.finder: Scripting.finderWindows(),
            Scripting.safari: Scripting.safariWindows(),
            Scripting.chrome: Scripting.chromeWindows(),
        ]

        var windows: [SavedWindow] = []
        var remoteDone = Set<pid_t>()
        var usedScript = Set<String>()
        var z = 0
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let wid = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let bDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: bDict),
                  bounds.width >= 60, bounds.height >= 60,
                  ((w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier,
                  let appURL = app.bundleURL
            else { continue }

            // Space di appartenenza → monitor + desktop (solo desktop utente, non schermo intero).
            guard let space = CGS.spaces(forWindow: wid).first,
                  let (disp, ordinal) = Topology.locate(space: space, in: displays) else { continue }

            var content = WindowContent()
            var title: String?
            if axByWID[wid] == nil, AX.isTrusted, !remoteDone.contains(pid) {
                remoteDone.insert(pid)
                for el in AX.remoteWindows(pid: pid) {
                    if let id = AX.windowID(el), axByWID[id] == nil {
                        axByWID[id] = (AX.title(el), AX.documentPath(el))
                        if AX.isUnsavedDocument(el) { unsaved.insert(id) }
                    }
                }
            }
            if let ax = axByWID[wid] {
                title = ax.title; content.documentPath = ax.doc
            } else if let m = axFramesByPID[pid]?.first(where: { near($0.0, bounds) }) {
                title = m.1; content.documentPath = m.2
            }
            // Finestra AppleScript corrispondente: stessa posizione e, se più finestre sono una
            // sopra l'altra, quella col titolo giusto. Ognuna si usa una volta sola, altrimenti due
            // finestre sovrapposte risulterebbero la stessa (e al ripristino diventerebbero due copie).
            let overlapping = (scripted[bundleID] ?? []).indices.filter {
                !usedScript.contains("\(bundleID)#\($0)") && Capture.near(scripted[bundleID]![$0].bounds, bounds)
            }
            let pick = overlapping.first { i in
                let st = scripted[bundleID]![i].title
                return !st.isEmpty && (title?.hasPrefix(st) == true || title == st)
            } ?? overlapping.first
            if let i = pick { usedScript.insert("\(bundleID)#\(i)") }
            if let i = pick, let sw = scripted[bundleID]?[i] {
                title = title ?? sw.title
                content.folderPath = sw.folderPath
                if !sw.urls.isEmpty { content.urls = sw.urls; content.activeTab = sw.activeTab }
                if sw.incognito { content.privateWindow = true }
            }
            // Firefox: schede lette via Accessibilità (anche su altri desktop, se raggiungibili).
            if bundleID == BrowserAX.firefox, AX.isTrusted,
               let el = (AX.windows(pid: pid) + AX.remoteWindows(pid: pid)).first(where: { AX.windowID($0) == wid }),
               let tabs = { () -> (urls: [String], active: Int?)? in
                   // Firefox appena avviato: le schede compaiono solo dopo averle chieste.
                   if BrowserAX.tabButtons(el).isEmpty {
                       BrowserAX.enableAccessibility(pid: pid)
                       for _ in 0..<20 where BrowserAX.tabButtons(el).isEmpty { usleep(150_000) }
                   }
                   defer { BrowserAX.disableEnhancedUI(pid: pid) }
                   return BrowserAX.readTabs(el)
               }() {
                content.urls = tabs.urls
                content.activeTab = tabs.active
            }

            // App che non espongono AXDocument: il file si ricava dal titolo (Spotlight).
            if content.documentPath == nil, content.folderPath == nil, (content.urls ?? []).isEmpty,
               !unsaved.contains(wid), let t = title, let path = DocResolver.resolve(title: t, appName: app.localizedName ?? "", appURL: appURL) {
                content.documentPath = path
                content.documentFromTitle = true
            }

            let vf = disp.visibleFrame
            let rel = CGRect(x: (bounds.minX - vf.minX) / vf.width, y: (bounds.minY - vf.minY) / vf.height,
                             width: bounds.width / vf.width, height: bounds.height / vf.height)
            let saved = SavedWindow(bundleID: bundleID, appName: app.localizedName ?? bundleID,
                                       appPath: appURL.path, title: title,
                                       displayUUID: disp.uuid, displayIsBuiltin: disp.isBuiltin,
                                       desktopOrdinal: ordinal, frame: bounds, relFrame: rel,
                                       content: content, zIndex: z,
                                       minimized: minimized.contains(wid) ? true : nil)
            windows.append(saved)
            windowIDs[saved.id] = wid
            z += 1
        }

        let saved = displays.map {
            SavedDisplay(uuid: $0.uuid, isBuiltin: $0.isBuiltin, name: $0.name, frame: $0.frame,
                         visibleFrame: $0.visibleFrame, desktopCount: $0.desktopCount,
                         currentOrdinal: $0.currentOrdinal ?? 1)
        }
        let scene = SavedScene(name: name, created: Date(), config: Topology.config(of: displays),
                               displays: saved, windows: windows).withoutPanels()
        let panels = windows.count - scene.windows.count
        Log.write("Capture «\(name)»: \(scene.windows.count) windows\(panels > 0 ? " (\(panels) panels left out)" : ""), setup \(Topology.config(of: displays).label)")
        return scene
    }

    static func near(_ a: CGRect, _ b: CGRect, tol: CGFloat = 6) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol &&
        abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }
}
