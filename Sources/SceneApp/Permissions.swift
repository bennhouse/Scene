import SwiftUI
import ApplicationServices

/// Permessi che servono a Scene, chiesti tutti insieme al primo avvio così macOS non li chiede
/// a metà di un ripristino.
enum Permissions {
    enum State: Equatable { case granted, denied, notAsked, appNotRunning, notInstalled }

    struct Browser: Identifiable {
        let id: String      // bundle ID
        let name: String
    }

    static let browsers = [Browser(id: Scripting.safari, name: "Safari"),
                           Browser(id: Scripting.chrome, name: "Google Chrome")]

    static let welcomeKey = "welcomeDone"
    /// Le cartelle sono già state chieste una volta: rileggerle non fa più comparire richieste.
    static let foldersAskedKey = "foldersAsked"

    // MARK: Accessibilità

    static var accessibility: State { AX.isTrusted ? .granted : .notAsked }

    // MARK: Automazione (Apple Events verso Finder, Safari, Chrome)

    /// Stato del permesso di controllare `bundleID`. Con `ask` macOS mostra la richiesta se serve
    /// (blocca finché l'utente risponde: va chiamata fuori dal thread principale).
    static func automation(_ bundleID: String, ask: Bool) -> State {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) == nil { return .notInstalled }
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, bytes, bytes.count, &target) == noErr else { return .notAsked }
        defer { AEDisposeDesc(&target) }
        // Con l'app chiusa macOS non sa rispondere: vale l'ultima risposta vista (per esempio
        // Safari aperto solo per chiedere il permesso e poi richiuso).
        let key = "automation." + bundleID
        switch AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask) {
        case noErr:
            UserDefaults.standard.set("granted", forKey: key); return .granted
        case OSStatus(errAEEventNotPermitted):
            UserDefaults.standard.set("denied", forKey: key); return .denied
        case OSStatus(procNotFound):
            switch UserDefaults.standard.string(forKey: key) {
            case "granted": return .granted
            case "denied": return .denied
            default: return .appNotRunning
            }
        default:
            UserDefaults.standard.removeObject(forKey: key); return .notAsked
        }
    }

    // MARK: Cartelle protette

    static let folders: [URL] = [
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first,
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
    ].compactMap { $0 }

    /// Legge le cartelle: la prima volta macOS chiede il permesso per ciascuna. Restituisce
    /// quante sono leggibili. Va chiamata fuori dal thread principale.
    static func touchFolders() -> Int {
        UserDefaults.standard.set(true, forKey: foldersAskedKey)
        return folders.filter { (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) != nil }.count
    }

    @MainActor static func openAccessibilitySettings() {
        WindowLevel.lowerUntilReactivated()
        AX.requestTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

/// La finestra di Scene sta sempre in primo piano, anche mentre si usano le altre app: è già a
/// quel livello prima del clic altrove, così non c'è il lampo di una finestra che le passa sopra
/// e poi torna dietro. Torna una finestra normale solo quando serve:
/// - mentre la si trascina per la barra del titolo (macOS la sposta tra i desktop solo se è
///   normale, e lo decide all'inizio del trascinamento);
/// - mentre è aperta un'altra finestra di Scene (Impostazioni, pannelli), che starebbe dietro;
/// - durante un ripristino o una cattura, per non coprire le richieste delle app («Vuoi salvare?»);
/// - quando si manda l'utente nelle Impostazioni di Sistema (fino al ritorno in Scene).
@MainActor
enum WindowLevel {
    private static weak var window: NSWindow?
    private static var observers: [NSObjectProtocol] = []
    private static var monitor: Any?
    private static var suspended = false
    private static var dragging = false

    static func attach(_ w: NSWindow) {
        window = w
        observers.forEach(NotificationCenter.default.removeObserver)
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { suspended = false; update() }
            },
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { update() }
            },
            nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { _ in
                // La finestra che si chiude è ancora visibile: si guarda subito dopo.
                DispatchQueue.main.async { MainActor.assumeIsolated { update() } }
            },
        ]
        if monitor == nil {
            // Il monitor locale vede il clic prima della finestra: il livello cambia in tempo.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in
                MainActor.assumeIsolated {
                    if let w = window, e.window === w, isTitleBar(e, in: w) { beginDrag() }
                }
                return e
            }
        }
        update()
    }

    /// Il clic è nella barra del titolo e degli strumenti (sopra il contenuto)?
    private static func isTitleBar(_ e: NSEvent, in w: NSWindow) -> Bool {
        e.locationInWindow.y >= w.contentLayoutRect.maxY
    }

    /// Finestra normale finché il pulsante del mouse resta premuto (macOS gestisce il
    /// trascinamento da sé e l'app non sempre riceve il rilascio, quindi si controlla).
    private static func beginDrag() {
        dragging = true
        update()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            t.invalidate()
            MainActor.assumeIsolated { dragging = false; update() }
        }
    }

    /// Da chiamare quando cambia qualcosa che conta (inizio e fine di un ripristino).
    static func refresh() { update() }

    private static func update() {
        guard let window else { return }
        let otherWindow = NSApp.windows.contains { w in
            w !== window && w.isVisible && !(w is NSPanel) && w.level == .normal && w.styleMask.contains(.titled)
        }
        let busy = Shared.restorer.isRunning
        let level: NSWindow.Level = (suspended || dragging || otherWindow || busy || NSApp.modalWindow != nil) ? .normal : .floating
        if window.level != level { window.level = level }
    }

    static func lowerUntilReactivated() {
        suspended = true
        update()
    }
}

/// Schermata di benvenuto con l'elenco dei permessi e un pulsante per chiederli tutti.
struct WelcomeView: View {
    let onDone: () -> Void

    @State private var ax = Permissions.accessibility
    @State private var finder = Permissions.State.notAsked
    @State private var browsers: [String: Permissions.State] = [:]
    @State private var folders: Permissions.State = .notAsked
    @State private var asking = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        // Compatta: deve stare nella finestra al primo avvio (760×480) senza allungarla.
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Scene").font(.title3.weight(.semibold))
                    Text("Scene needs a few permissions to read, open and move your windows. Allow them now, so macOS doesn't ask in the middle of a restore.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                row("accessibility", "Accessibility",
                    "Read, move and close windows, and switch desktops. Required.",
                    ax) { Permissions.openAccessibilitySettings() }
                Divider()
                row("folder", "Finder", "Read which folder each Finder window shows.", finder) {
                    Task { finder = await offMain { Permissions.automation(Scripting.finder, ask: true) } }
                }
                ForEach(Permissions.browsers) { b in
                    if browsers[b.id] != .notInstalled {
                        Divider()
                        row("globe", b.name, "Read and reopen tabs.", browsers[b.id] ?? .notAsked) {
                            Task { await askBrowser(b.id) }
                        }
                    }
                }
                Divider()
                row("doc.on.doc", "Desktop, Documents and Downloads",
                    "Check that the documents in a scene still exist.", folders) {
                    Task { await askFolders() }
                }
            }
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))

            Text("Firefox and other apps need nothing more than Accessibility. You can open this window again from the Scene menu.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(allGranted ? "Done" : "Not Now") { finish() }
                    .keyboardShortcut(allGranted ? .defaultAction : .cancelAction)
                if !allGranted {
                    Button("Allow All") { Task { await allowAll() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(asking)
                }
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private var allGranted: Bool {
        ax == .granted && finder == .granted && folders == .granted
            && browsers.values.allSatisfy { $0 == .granted || $0 == .notInstalled }
    }

    @ViewBuilder
    private func row(_ symbol: String, _ title: String, _ detail: String, _ state: Permissions.State,
                     action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(stateNote(state) ?? detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            switch state {
            case .granted:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 16))
            case .denied:
                Button("Open Settings") {
                    WindowLevel.lowerUntilReactivated()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }.controlSize(.small)
            default:
                Button("Allow", action: action).controlSize(.small).disabled(asking)
            }
        }
        .padding(.vertical, 6)
    }

    private func stateNote(_ s: Permissions.State) -> String? {
        switch s {
        case .denied: return "Turned off. Turn it on in System Settings › Privacy & Security › Automation."
        case .appNotRunning: return "Opens the app in the background to ask, then closes it again."
        default: return nil
        }
    }

    // MARK: Azioni

    private func refresh() {
        ax = Permissions.accessibility
        Task {
            let f = await offMain { Permissions.automation(Scripting.finder, ask: false) }
            var b: [String: Permissions.State] = [:]
            for br in Permissions.browsers {
                b[br.id] = await offMain { Permissions.automation(br.id, ask: false) }
            }
            if finder != .granted || f == .granted { finder = f }
            browsers = b
            if UserDefaults.standard.bool(forKey: Permissions.foldersAskedKey) {
                let n = await offMain { Permissions.touchFolders() }
                folders = n == Permissions.folders.count ? .granted : .denied
            }
        }
    }

    private func askBrowser(_ id: String) async {
        asking = true
        defer { asking = false }
        // Il browser va aperto per poterlo chiedere. Se l'ha aperto Scene, dopo la risposta lo richiude;
        // se era già aperto resta com'era.
        var openedHere: NSRunningApplication?
        if Permissions.automation(id, ask: false) == .appNotRunning,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let c = NSWorkspace.OpenConfiguration()
            c.activates = false
            c.hides = true
            openedHere = try? await NSWorkspace.shared.openApplication(at: url, configuration: c)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        browsers[id] = await offMain { Permissions.automation(id, ask: true) }
        openedHere?.terminate()
    }

    private func askFolders() async {
        asking = true
        defer { asking = false }
        let n = await offMain { Permissions.touchFolders() }
        folders = n == Permissions.folders.count ? .granted : .denied
    }

    /// Chiede tutto in fila: le richieste di macOS compaiono una dopo l'altra.
    private func allowAll() async {
        asking = true
        if finder != .granted { finder = await offMain { Permissions.automation(Scripting.finder, ask: true) } }
        // Anche i browser chiusi: Scene li apre in background, chiede e li richiude.
        for b in Permissions.browsers where browsers[b.id] == .notAsked || browsers[b.id] == .appNotRunning {
            await askBrowser(b.id)
            asking = true
        }
        if folders != .granted {
            let n = await offMain { Permissions.touchFolders() }
            folders = n == Permissions.folders.count ? .granted : .denied
        }
        asking = false
        // Ultima: porta nelle Impostazioni di Sistema, quindi la finestra passa in secondo piano.
        if ax != .granted { Permissions.openAccessibilitySettings() }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Permissions.welcomeKey)
        onDone()
    }
}

extension Notification.Name {
    /// Riapre la schermata dei permessi (menu Scene › Permissions…).
    static let showWelcome = Notification.Name("SceneShowWelcome")
}
