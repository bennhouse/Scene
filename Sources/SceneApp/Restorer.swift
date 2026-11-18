import Cocoa

/// Ripristino di una scena. Le finestre non vengono mai spostate da uno Space all'altro.
/// Sequenza:
///   1. chiude le finestre (se richiesto), su tutti i desktop
///   2. passa agli altri desktop e ci riapre/posiziona le loro finestre
///   3. torna ai desktop di partenza
///   4. riapre/posiziona le finestre dei desktop di partenza
@MainActor
final class Restorer: ObservableObject {
    @Published var status = ""
    @Published var isRunning = false
    /// App che stanno chiedendo qualcosa (es. salvare) prima di chiudere una finestra.
    @Published var waitingApps: [String] = []

    private var spaceChanges = 0
    private var observer: NSObjectProtocol?
    private var used = Set<CGWindowID>()
    private var skipWaiting = false
    private var abortRequested = false
    private let blocker = InputBlocker.shared

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.spaceChanges += 1 }
        }
    }

    /// Continua senza aspettare le finestre che non si sono chiuse.
    func skipWait() { skipWaiting = true }
    /// Interrompe il ripristino (torna comunque al desktop di partenza).
    func abort() { abortRequested = true; skipWaiting = true }

    private func note(_ s: String) { Log.write(s) }
    private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    // MARK: - Ripristino

    func restore(_ scene: SavedScene, closeFirst: Bool, mode: CloseMode = .scene) async {
        guard !isRunning else { return }
        guard AX.isTrusted else {
            status = "Scene needs Accessibility access (System Settings > Privacy & Security)."
            note("Restore cancelled: Accessibility access missing")
            AX.requestTrust()
            return
        }
        guard CGS.supported else {
            status = "Scene can't read desktops on this version of macOS, so it can't restore scenes."
            note("Restore cancelled: private APIs unavailable (\(CGS.missing.joined(separator: ", ")))")
            return
        }
        isRunning = true
        used = []
        abortRequested = false; skipWaiting = false
        let t0 = Date()
        blocker.begin(maxSeconds: InputBlocker.cap)
        defer { blocker.end(); isRunning = false }

        let displays = Topology.displays()
        let start = Dictionary(uniqueKeysWithValues: displays.map { ($0.uuid, $0.currentOrdinal ?? 1) })
        let pointer = CGEvent(source: nil)?.location ?? .zero
        let targets = displays.map {
            Mapping.TargetDisplay(uuid: $0.uuid, isBuiltin: $0.isBuiltin, visibleFrame: $0.visibleFrame,
                                  desktopCount: $0.desktopCount, currentOrdinal: $0.currentOrdinal ?? 1)
        }
        // Dalla più arretrata alla più in primo piano.
        let plan = Mapping.plan(scene, on: targets).sorted { $0.window.zIndex > $1.window.zIndex }
        note("Restoring «\(scene.name)» [\(scene.config.label) > \(Topology.config(of: displays).label)], \(plan.count) windows, close first: \(closeFirst ? mode.label : "no")")

        // 1) Chiusura su tutti i desktop. Se l'Accessibilità non risponde non si chiude nulla:
        // senza poter leggere le finestre non si saprebbe quali tenere.
        if closeFirst && !AX.waitResponsive() {
            note("Accessibility not responding: closing windows skipped")
        } else if closeFirst {
            status = "Closing windows…"
            switch mode {
            case .scene: await closeEverywhere(apps: Set(scene.windows.map(\.bundleID)))
            case .all: await closeEverywhere(apps: nil)
            case .notIncluded:
                let keep = keptWindows(plan)
                note("Scene windows already open in place: \(keep.count)")
                await closeEverywhere(apps: nil, keep: keep)
            }
        }

        // 2) Gli altri desktop, monitor per monitor.
        var failed = 0
        outer: for d in displays {
            let ords = Set(plan.filter { $0.displayUUID == d.uuid && $0.ordinal != start[d.uuid] }.map(\.ordinal)).sorted()
            for o in ords {
                if abortRequested { break outer }
                status = "Desktop \(o), \(d.name)…"
                guard await switchDesktop(d.uuid, to: o) else {
                    note("Could not switch to desktop \(o) on \(d.name)")
                    failed += 1
                    continue
                }
                await place(plan.filter { $0.displayUUID == d.uuid && $0.ordinal == o })
            }
        }

        // 3) Ritorno ai desktop di partenza.
        status = "Returning to the starting desktop…"
        for d in displays {
            if let s = start[d.uuid], Topology.display(uuid: d.uuid)?.currentOrdinal != s {
                _ = await switchDesktop(d.uuid, to: s)
            }
        }

        // 4) Desktop di partenza (tutti i monitor sono visibili insieme).
        if !abortRequested {
            status = "Current desktop…"
            await place(plan.filter { start[$0.displayUUID] == $0.ordinal }, allVisible: true)
        }
        warp(to: pointer)

        let placed = used.count
        if abortRequested {
            status = "Restore stopped: \(placed) of \(plan.count) windows"
        } else {
            status = "Restored «\(scene.name)»: \(placed) of \(plan.count) windows in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s"
                + (failed > 0 ? ", \(failed) desktops not reached" : "")
        }
        note(status)
    }

    /// Prova a secco di «le finestre non incluse»: elenca cosa resterebbe e cosa verrebbe chiuso.
    func describeNotIncluded(_ scene: SavedScene) -> [String] {
        let displays = Topology.displays()
        let targets = displays.map {
            Mapping.TargetDisplay(uuid: $0.uuid, isBuiltin: $0.isBuiltin, visibleFrame: $0.visibleFrame,
                                  desktopCount: $0.desktopCount, currentOrdinal: $0.currentOrdinal ?? 1)
        }
        let keep = keptWindows(Mapping.plan(scene, on: targets))
        let userSpaces = Set(displays.flatMap(\.desktopSpaces))
        var out: [String] = []
        for app in targetApps(nil) {
            for (wid, sp) in cgWindows(pid: app.processIdentifier) where userSpaces.contains(sp) {
                let d = Topology.locate(space: sp, in: displays)
                out.append("\(keep.contains(wid) ? "KEEP " : "CLOSE") \(app.localizedName ?? "?") window \(wid) desktop \(d?.1 ?? 0) \(d?.0.isBuiltin == true ? "Mac" : "Ext")")
            }
        }
        return out.sorted()
    }

    // MARK: - Desktop

    func warp(to p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)
        let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
        e?.setIntegerValueField(.eventSourceUserData, value: InputBlocker.marker)
        e?.post(tap: .cghidEventTap)
    }

    /// Porta il monitor `uuid` al desktop `target` premendo ⌥1/⌥2 (o le scorciatoie scelte).
    func switchDesktop(_ uuid: String, to target: Int) async -> Bool {
        guard var disp = Topology.display(uuid: uuid), var cur = disp.currentOrdinal else { return false }
        guard target >= 1, target <= disp.desktopCount else { return false }
        var steps = 0
        while cur != target && steps < 8 {
            steps += 1
            // Il puntatore sul monitor giusto: le scorciatoie agiscono sul monitor attivo.
            warp(to: CGPoint(x: disp.frame.midX, y: disp.frame.midY))
            await sleep(0.12)
            let before = disp.currentSpace
            let n0 = spaceChanges
            (target > cur ? Prefs.shared.right : Prefs.shared.left).post()

            let deadline = Date().addingTimeInterval(2.5)
            var now: DisplayInfo?
            while Date() < deadline {
                await sleep(0.05)
                if spaceChanges > n0, let d = Topology.display(uuid: uuid), d.currentSpace != before { now = d; break }
            }
            if now == nil, let d = Topology.display(uuid: uuid), d.currentSpace != before {
                note("Space change notification not received, change confirmed by CGS")
                now = d
            }
            guard let d = now, let o = d.currentOrdinal else { return false }
            disp = d; cur = o
            await sleep(Prefs.shared.settleDelay)
        }
        return cur == target
    }

    /// Prima di aprire o posizionare: se il desktop è cambiato (es. dopo il tetto degli 8 s), ci torna.
    private func ensureDesktop(_ uuid: String, _ ordinal: Int) async -> Bool {
        if Topology.display(uuid: uuid)?.currentOrdinal == ordinal { return true }
        note("Desktop changed during restore, going back to desktop \(ordinal)")
        return await switchDesktop(uuid, to: ordinal)
    }

    // MARK: - Chiusura

    private struct Closing {
        let el: AXUIElement
        let pid: pid_t
        let wid: CGWindowID
        let app: String
    }

    /// Finestre "vere" (livello 0, non minuscole) di un processo, con il loro Space.
    private func cgWindows(pid: pid_t) -> [(CGWindowID, CGSSpaceID)] {
        let info = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                    as? [[String: Any]]) ?? []
        return info.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let wid = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  b.width >= 60, b.height >= 60,
                  ((w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let sp = CGS.spaces(forWindow: wid).first else { return nil }
            return (wid, sp)
        }
    }

    private func targetApps(_ apps: Set<String>?) -> [NSRunningApplication] {
        let own = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != own && $0.activationPolicy == .regular
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && (apps == nil || apps!.contains($0.bundleIdentifier ?? ""))
        }
    }

    /// Chiude le finestre su tutti i desktop senza cambiare desktop quando possibile.
    /// Le finestre che AX non raggiunge da remoto vengono chiuse passando dal loro desktop.
    /// `apps == nil` → tutte le app (Scene esclusa).
    private func closeEverywhere(apps: Set<String>?, keep: Set<CGWindowID> = []) async {
        let ds = Topology.displays()
        let userSpaces = Set(ds.flatMap(\.desktopSpaces))
        var items: [Closing] = []
        var missing: [CGSSpaceID: Int] = [:]
        for app in targetApps(apps) {
            let pid = app.processIdentifier
            let cg = cgWindows(pid: pid).filter { userSpaces.contains($0.1) && !keep.contains($0.0) }
            guard !cg.isEmpty else { continue }
            var found = Set<CGWindowID>()
            for w in AX.allWindows(pid: pid) {
                guard let id = AX.windowID(w), !keep.contains(id),
                      let sp = CGS.spaces(forWindow: id).first, userSpaces.contains(sp) else { continue }
                found.insert(id)
                items.append(Closing(el: w, pid: pid, wid: id, app: app.localizedName ?? "App"))
            }
            for (wid, sp) in cg where !found.contains(wid) { missing[sp, default: 0] += 1 }
        }
        await closeAndWait(items)

        // Finestre non raggiungibili da remoto: si va sul loro desktop.
        for (space, count) in missing.sorted(by: { $0.key < $1.key }) {
            if abortRequested { return }
            guard let (d, o) = Topology.locate(space: space, in: Topology.displays()) else { continue }
            note("\(count) windows not reachable remotely on desktop \(o) of \(d.name): visiting it")
            guard await switchDesktop(d.uuid, to: o) else { continue }
            var more: [Closing] = []
            for app in targetApps(apps) {
                for w in AX.windows(pid: app.processIdentifier) {
                    guard let id = AX.windowID(w), !keep.contains(id), CGS.spaces(forWindow: id).first == space else { continue }
                    more.append(Closing(el: w, pid: app.processIdentifier, wid: id, app: app.localizedName ?? "App"))
                }
            }
            await closeAndWait(more)
        }
    }

    /// Chiude finestre precise dell'app: da remoto se AX le raggiunge, altrimenti passando dal loro desktop.
    private func closeWindows(_ ids: Set<CGWindowID>, bundleID: String, appName: String) async {
        var remaining = ids
        var items: [Closing] = []
        for pid in pids(bundleID) {
            for el in AX.allWindows(pid: pid) {
                guard let id = AX.windowID(el), remaining.contains(id) else { continue }
                items.append(Closing(el: el, pid: pid, wid: id, app: appName))
                remaining.remove(id)
            }
        }
        await closeAndWait(items)
        for id in remaining {
            guard let sp = CGS.spaces(forWindow: id).first,
                  let (d, o) = Topology.locate(space: sp, in: Topology.displays()),
                  await switchDesktop(d.uuid, to: o) else { continue }
            for pid in pids(bundleID) {
                if let el = AX.windows(pid: pid).first(where: { AX.windowID($0) == id }) {
                    await closeAndWait([Closing(el: el, pid: pid, wid: id, app: appName)])
                }
            }
        }
    }

    /// «Le finestre non incluse»: le finestre già aperte che corrispondono a una finestra della
    /// scena e stanno già sul desktop giusto. Queste restano; il resto viene chiuso.
    private func keptWindows(_ plan: [Mapping.Placement]) -> Set<CGWindowID> {
        let ds = Topology.displays()
        var kept = Set<CGWindowID>()
        var generic: [(Mapping.Placement, [CGWindowID])] = []
        for p in plan {
            guard let d = ds.first(where: { $0.uuid == p.displayUUID }),
                  p.ordinal >= 1, p.ordinal <= d.desktopSpaces.count else { continue }
            let space = d.desktopSpaces[p.ordinal - 1]
            var ids: [CGWindowID] = []
            var els: [CGWindowID: AXUIElement] = [:]
            for pid in pids(p.window.bundleID) {
                ids += cgWindows(pid: pid).filter { $0.1 == space && !kept.contains($0.0) }.map(\.0)
                for el in AX.allWindows(pid: pid) { if let id = AX.windowID(el) { els[id] = el } }
            }
            let w = p.window, c = w.content
            let match: (AXUIElement) -> Bool
            if let doc = c.documentPath {
                match = { AX.shows($0, document: doc) }
            } else if let path = c.folderPath {
                let name = FileManager.default.displayName(atPath: path)
                match = { AX.title($0) == name || AX.title($0) == w.title }
            } else if let t = w.title, !t.isEmpty {
                match = { AX.title($0) == t }
            } else {
                match = { _ in false }
            }
            if let id = ids.first(where: { els[$0].map(match) ?? false }) {
                kept.insert(id)
            } else if let id = ids.first(where: { els[$0] == nil && !kept.contains($0) }) {
                // Finestra dell'app giusta sul desktop giusto ma non leggibile: nel dubbio si tiene.
                kept.insert(id)
            } else if c.isEmpty {
                generic.append((p, ids))   // finestra senza contenuto: va bene una qualunque dell'app
            }
        }
        for (_, ids) in generic {
            if let id = ids.first(where: { !kept.contains($0) }) { kept.insert(id) }
        }
        return kept
    }

    private func stillOpen(_ c: Closing) -> Bool {
        guard NSRunningApplication(processIdentifier: c.pid)?.isTerminated == false else { return false }
        return !((CGWindowListCopyWindowInfo([.optionIncludingWindow], c.wid) as? [[String: Any]]) ?? []).isEmpty
    }

    /// Preme il pulsante rosso. Se un'app chiede qualcosa (salvare, terminare un processo…)
    /// il ripristino va in pausa finché la finestra non si chiude davvero.
    private func closeAndWait(_ items: [Closing]) async {
        guard !items.isEmpty else { return }
        var accepted = Set<CGWindowID>()
        for i in items where AX.close(i.el) { accepted.insert(i.wid) }
        await sleep(0.7)
        // Alcune app terminano chiudendo l'ultima finestra e l'azione AX risponde con un errore:
        // conta il risultato, cioè se la finestra c'è ancora.
        let failed = items.filter { !accepted.contains($0.wid) && stillOpen($0) }
        for f in failed { note("\(f.app): window \(f.wid) has no usable close button") }
        let pressed = items.filter { accepted.contains($0.wid) }
        note("Closed \(items.count - failed.count) windows")
        guard !pressed.isEmpty else { return }
        let previous = status
        var shown = Set<CGWindowID>()
        var ignored = Set<CGWindowID>()
        var noPromptSince: [CGWindowID: Date] = [:]
        while !skipWaiting {
            var pending = pressed.filter { !ignored.contains($0.wid) && stillOpen($0) }
            // Finestra ancora aperta ma senza nessuna richiesta: riprova una volta, poi lasciala.
            for p in pending where !AX.hasPrompt(p.el, pid: p.pid) {
                let since = noPromptSince[p.wid] ?? Date()
                noPromptSince[p.wid] = since
                let age = Date().timeIntervalSince(since)
                if age > 1.5 && age < 1.9 { AX.close(p.el) }
                if age > 3 {
                    ignored.insert(p.wid)
                    note("\(p.app): window \(p.wid) did not close and shows no prompt, leaving it")
                }
            }
            pending.removeAll { ignored.contains($0.wid) }
            if pending.isEmpty { break }
            guard pending.contains(where: { AX.hasPrompt($0.el, pid: $0.pid) }) else {
                await sleep(0.3); continue
            }
            blocker.pause()   // l'utente deve poter rispondere
            var names: [String] = []
            for p in pending where !names.contains(p.app) { names.append(p.app) }
            if waitingApps != names {
                waitingApps = names
                status = "Waiting for a reply in \(names.joined(separator: ", "))"
                note("Waiting for: \(names.joined(separator: ", "))")
            }
            // Mostra la richiesta: se la finestra sta su un desktop non visibile, ci si sposta lì.
            if let f = pending.first, !shown.contains(f.wid) {
                shown.insert(f.wid)
                let ds = Topology.displays()
                if let sp = CGS.spaces(forWindow: f.wid).first, !ds.map(\.currentSpace).contains(sp),
                   let (d, o) = Topology.locate(space: sp, in: ds) {
                    _ = await switchDesktop(d.uuid, to: o)
                }
                AXUIElementPerformAction(f.el, kAXRaiseAction as CFString)
            }
            await sleep(0.3)
        }
        if !waitingApps.isEmpty {
            note(skipWaiting ? "Wait skipped" : "Prompts answered, resuming")
            blocker.resume()
        }
        waitingApps = []
        if !abortRequested { skipWaiting = false }
        status = previous
        await sleep(0.3)
    }

    // MARK: - Apertura e posizionamento

    private func pids(_ bundleID: String) -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }.map(\.processIdentifier)
    }

    /// Space su cui una finestra di questo passo può stare. Sui desktop di partenza tutti i
    /// monitor sono visibili (una finestra nuova può nascere sull'altro e venire spostata).
    private func allowedSpaces(for p: Mapping.Placement, allVisible: Bool) -> Set<CGSSpaceID> {
        Set(Topology.displays().filter { allVisible || $0.uuid == p.displayUUID }.map(\.currentSpace))
    }

    private func place(_ items: [Mapping.Placement], allVisible: Bool = false) async {
        for p in items {
            if abortRequested { return }
            guard await ensureDesktop(p.displayUUID, p.ordinal) else { continue }
            let allowed = allowedSpaces(for: p, allVisible: allVisible)
            guard let el = await obtainWindow(for: p.window, allowed: allowed,
                                              target: (p.displayUUID, p.ordinal)) else {
                note("No window for \(p.window.appName) «\(p.window.title ?? "")»"); continue
            }
            // Mai posizionare una finestra che non sta sul desktop giusto.
            if let id = AX.windowID(el), let sp = CGS.spaces(forWindow: id).first,
               !Set(Topology.displays().map(\.currentSpace)).contains(sp) {
                note("\(p.window.appName) window is on another desktop, skipping it"); continue
            }
            AX.setFrame(el, p.frame)
            if let id = AX.windowID(el) { used.insert(id) }
            note("OK \(p.window.appName) «\(p.window.title ?? "")» > desktop \(p.ordinal) \(Int(p.frame.minX)),\(Int(p.frame.minY)) \(Int(p.frame.width))x\(Int(p.frame.height))")
        }
    }

    /// App da aprire. Una scena può arrivare da un file importato, quindi non ci si fida del
    /// percorso salvato: si apre solo l'app registrata in LaunchServices con quell'identificativo.
    private func appURL(_ w: SavedWindow) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: w.bundleID)
    }

    /// Solo indirizzi web o file locali. Esclude schemi come javascript: e, per Firefox,
    /// argomenti che inizierebbero con «-» e verrebbero letti come opzioni.
    nonisolated static func safeURLs(_ urls: [String]) -> [String] {
        urls.filter { s in
            guard !s.hasPrefix("-"), let u = URL(string: s), let scheme = u.scheme?.lowercased() else { return false }
            return ["http", "https", "file"].contains(scheme)
        }
    }

    private func openConfig(activates: Bool = false, newInstance: Bool = false) -> NSWorkspace.OpenConfiguration {
        let c = NSWorkspace.OpenConfiguration()
        c.activates = activates
        c.addsToRecentItems = false
        c.createsNewApplicationInstance = newInstance
        return c
    }

    /// Finestre di tutte le istanze dell'app, sugli Space consentiti e non ancora usate.
    private func candidates(_ bundleID: String, allowed: Set<CGSSpaceID>) -> [AXUIElement] {
        pids(bundleID).flatMap { AX.windows(pid: $0) }.filter { el in
            guard let id = AX.windowID(el), !used.contains(id) else { return false }
            guard let s = CGS.spaces(forWindow: id).first else { return true }
            return allowed.contains(s)
        }
    }

    private func windowIDs(_ bundleID: String) -> Set<CGWindowID> {
        Set(pids(bundleID).flatMap { cgWindows(pid: $0).map(\.0) })
    }

    private func obtainWindow(for w: SavedWindow, allowed: Set<CGSSpaceID>,
                              target: (uuid: String, ordinal: Int)) async -> AXUIElement? {
        let c = w.content
        let bid = w.bundleID

        // Documento
        if let doc = c.documentPath, FileManager.default.fileExists(atPath: doc), let app = appURL(w) {
            if let m = candidates(bid, allowed: allowed).first(where: { AX.shows($0, document: doc) }) { return m }
            let url = URL(fileURLWithPath: doc)
            var appIgnoredFile = false
            var strays = Set<CGWindowID>()   // finestre nate dal nostro tentativo sul desktop sbagliato
            for attempt in 0..<2 {
                // Il documento è aperto altrove (prima del ripristino, per un cambio di desktop durante
                // l'apertura, o nell'unica finestra di un'app a finestra singola): chiudilo là.
                var elsewhere = Set(pids(bid).flatMap { pid in
                    AX.allWindows(pid: pid).compactMap { el -> CGWindowID? in
                        guard AX.shows(el, document: doc), let id = AX.windowID(el), !used.contains(id),
                              !allowed.contains(CGS.spaces(forWindow: id).first ?? 0) else { return nil }
                        return id
                    }
                })
                elsewhere.formUnion(strays)
                if !elsewhere.isEmpty {
                    note("«\((doc as NSString).lastPathComponent)» is open on another desktop: closing it there")
                    await closeWindows(elsewhere, bundleID: bid, appName: w.appName)
                }
                guard await ensureDesktop(target.uuid, target.ordinal) else { return nil }
                if attempt == 1 && elsewhere.isEmpty && !appIgnoredFile { return nil }
                // Alcune app aprono file solo all'avvio: se l'app aperta ha ignorato il file, nuova istanza.
                let newInstance = attempt == 1 && appIgnoredFile && !pids(bid).isEmpty
                if newInstance { note("\(w.appName) did not open the file, trying a new instance") }
                let running = !pids(bid).isEmpty
                let before = windowIDs(bid)
                _ = try? await NSWorkspace.shared.open([url], withApplicationAt: app,
                                                       configuration: openConfig(newInstance: newInstance))
                if let n = await waitNewWindow(bid, excluding: before, allowed: allowed, timeout: running ? 4 : 8,
                                               target: target, match: { AX.shows($0, document: doc) }) { return n }
                let nowAllowed = Set(Topology.displays().map(\.currentSpace))
                let created = pids(bid).flatMap { cgWindows(pid: $0) }.filter { !before.contains($0.0) }
                strays = Set(created.filter { !nowAllowed.contains($0.1) }.map(\.0))
                // Nessuna finestra nuova e il file non è visibile da nessuna parte: l'app l'ha ignorato.
                appIgnoredFile = created.isEmpty && !pids(bid).contains { pid in
                    AX.allWindows(pid: pid).contains { AX.shows($0, document: doc) }
                }
            }
            return nil
        }

        // Cartella del Finder
        if bid == Scripting.finder, let path = c.folderPath {
            let name = FileManager.default.displayName(atPath: path)
            if let m = candidates(bid, allowed: allowed).first(where: { AX.title($0) == name || AX.title($0) == w.title }) { return m }
            if FileManager.default.fileExists(atPath: path) {
                let before = windowIDs(bid)
                Scripting.openFinderWindow(path: path)
                if let n = await waitNewWindow(bid, excluding: before, allowed: allowed, target: target) { return n }
            }
        }

        // Schede di Safari / Chrome / Firefox, con la scheda attiva (Chrome anche in incognito)
        if let urls = c.urls.map(Restorer.safeURLs), !urls.isEmpty,
           [Scripting.safari, Scripting.chrome, BrowserAX.firefox].contains(bid), let app = appURL(w) {
            if let t = w.title, let m = candidates(bid, allowed: allowed).first(where: { AX.title($0) == t }) { return m }
            if pids(bid).isEmpty {
                _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: openConfig())
                await sleep(1.5)
            }
            let before = windowIDs(bid)
            switch bid {
            case Scripting.safari:
                Scripting.openSafariWindow(urls: urls, activeTab: c.activeTab)
            case Scripting.chrome:
                Scripting.openChromeWindow(urls: urls, activeTab: c.activeTab, incognito: c.privateWindow == true)
            default:
                // Firefox: prima scheda in una finestra nuova, poi le altre come schede di quella finestra.
                // safeURLs esclude gli indirizzi che inizierebbero con «-» (opzioni di Firefox).
                BrowserAX.runFirefox(app: app, ["--new-window", urls[0]])
                guard let n = await waitNewWindow(bid, excluding: before, allowed: allowed, target: target) else { break }
                for u in urls.dropFirst() {
                    BrowserAX.runFirefox(app: app, ["--new-tab", u])
                    await sleep(0.35)
                }
                await sleep(0.4)
                if let a = c.activeTab { BrowserAX.selectTab(n, index: a) }
                return n
            }
            if let n = await waitNewWindow(bid, excluding: before, allowed: allowed, target: target) { return n }
        }

        // Finestra generica
        var fresh = candidates(bid, allowed: allowed)
        if let t = w.title, !t.isEmpty, let m = fresh.first(where: { AX.title($0) == t }) { return m }
        if let m = fresh.first(where: { AX.documentPath($0) == nil }) ?? fresh.first { return m }
        guard let app = appURL(w) else { return nil }

        if pids(bid).isEmpty {
            status = "Launching \(w.appName)…"
            let before = windowIDs(bid)
            _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: openConfig())
            if let n = await waitNewWindow(bid, excluding: before, allowed: allowed, timeout: 8, target: target) { return n }
            fresh = candidates(bid, allowed: allowed)
            if let m = fresh.first { return m }
        }
        // L'app è aperta ma senza finestre qui. Se non ne ha su nessun desktop, attivarla
        // non fa cambiare desktop e la fa aprire una finestra nuova (come un clic nel Dock).
        let before = windowIDs(bid)
        let none = before.isEmpty
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: openConfig(activates: none))
        return await waitNewWindow(bid, excluding: before, allowed: allowed, timeout: 3, target: target)
    }

    private func waitNewWindow(_ bundleID: String, excluding before: Set<CGWindowID>, allowed: Set<CGSSpaceID>,
                               timeout: Double = 6, target: (uuid: String, ordinal: Int)? = nil,
                               match: ((AXUIElement) -> Bool)? = nil) async -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await sleep(0.2)
            if let target, Topology.display(uuid: target.uuid)?.currentOrdinal != target.ordinal {
                _ = await ensureDesktop(target.uuid, target.ordinal)
            }
            let new = candidates(bundleID, allowed: allowed).filter { el in
                AX.windowID(el).map { !before.contains($0) } ?? false
            }
            if let match {
                if let m = new.first(where: match) { return m }
                // App a finestra singola (es. WordCraft): il file sostituisce il contenuto della finestra esistente.
                if let m = candidates(bundleID, allowed: allowed).first(where: match) { return m }
            } else if let m = new.first {
                await sleep(0.3)
                return m
            }
        }
        return nil
    }
}
