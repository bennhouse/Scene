import SwiftUI

@main
struct SceneMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var store = Shared.store
    @ObservedObject private var restorer = Shared.restorer
    @ObservedObject private var prefs = Prefs.shared

    init() {
        // Barra laterale stretta alla prima apertura. Si scrive solo se manca: appena l'utente
        // la ridimensiona, SwiftUI salva la sua larghezza con la stessa chiave e vale quella.
        let key = "NSSplitView Subview Frames main, SidebarNavigationSplitView"
        let d = UserDefaults.standard
        if d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] == nil {
            d.set(["0.000000, 0.000000, 200.000000, 540.000000, NO, NO",
                   "201.000000, 0.000000, 659.000000, 540.000000, NO, NO"], forKey: key)
        }
    }

    var body: some SwiftUI.Scene {
        Window("Scene", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(restorer)
                .environmentObject(prefs)
        }
        .defaultSize(width: 860, height: 540)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .importExport) {
                Button("Import Scenes…") { SceneFiles.importScenes(Shared.store, restorer: Shared.restorer) }
                Button("Export All Scenes…") { SceneFiles.export(Shared.store, only: nil, suggested: "Scene") }
            }
        }

        Settings {
            SettingsView().environmentObject(prefs)
        }
    }
}

@MainActor
enum Shared {
    static let store = SceneStore()
    static let restorer = Restorer()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Una sola istanza: due istanze sovrascriverebbero l'una le scene dell'altra.
        // (Gli avvii con argomenti sono i test automatici e usano il loro archivio.)
        let own = ProcessInfo.processInfo.processIdentifier
        if CLI.args.count <= 1, let other = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != own }) {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)   // icona nel Dock, nessuna voce nella menubar
        if CLI.args.count > 1 {
            Task { @MainActor in await CLI.run(store: Shared.store, restorer: Shared.restorer) }
        } else if !AX.isTrusted {
            AX.requestTrust()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { for w in sender.windows where w.canBecomeMain { w.makeKeyAndOrderFront(nil) } }
        return true
    }
}
