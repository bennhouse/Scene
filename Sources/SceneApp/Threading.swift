import Foundation

/// Il lavoro lento (Accessibilità sulle finestre degli altri desktop, Spotlight, schede del
/// browser) gira fuori dal thread principale: l'interfaccia resta reattiva e niente girandola.
/// Quello che AppKit vuole sul thread principale (schermi, AppleScript) ci torna con `MainThread.sync`.
enum MainThread {
    static func sync<T>(_ work: () -> T) -> T {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
}

/// Esegue `work` su un thread di sfondo e ne attende il risultato senza bloccare il chiamante.
func offMain<T>(_ work: @escaping () -> T) async -> T {
    await withCheckedContinuation { c in
        DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: work()) }
    }
}
