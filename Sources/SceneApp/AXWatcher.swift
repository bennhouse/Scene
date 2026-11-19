import Cocoa
import ApplicationServices

/// Avvisi di Accessibilità (es. «finestra creata») per svegliare prima le attese del ripristino.
/// Non sostituisce i controlli a tempo: `wait(upTo:)` torna comunque allo scadere, quindi
/// un'app che non manda gli avvisi viene gestita come prima, solo senza il vantaggio.
@MainActor
final class AXWatcher {
    private let notification: String
    private var observers: [pid_t: AXObserver] = [:]
    private var fired = false

    init(_ notification: String = kAXWindowCreatedNotification) {
        self.notification = notification
    }

    /// Ascolta queste app (quelle già ascoltate vengono saltate).
    func watch(_ pids: [pid_t]) {
        for pid in pids where observers[pid] == nil {
            var obs: AXObserver?
            let callback: AXObserverCallback = { _, _, _, refcon in
                guard let refcon else { return }
                let w = Unmanaged<AXWatcher>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { w.fired = true }
            }
            guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { continue }
            let app = AXUIElementCreateApplication(pid)
            let me = Unmanaged.passUnretained(self).toOpaque()
            guard AXObserverAddNotification(obs, app, notification as CFString, me) == .success else { continue }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
            observers[pid] = obs
        }
    }

    /// Aspetta un avviso o, al massimo, `seconds`.
    func wait(upTo seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !fired && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        fired = false
    }

    /// Da chiamare a fine uso: toglie gli osservatori dal run loop.
    func stop() {
        for obs in observers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observers = [:]
    }
}
