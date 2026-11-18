import Cocoa

/// Blocca tastiera e gesti del trackpad mentre Scene cambia desktop, così l'utente non può
/// spostarsi di desktop a metà ripristino. Gli eventi generati da Scene portano un marcatore
/// e passano. Tetto massimo di 8 secondi per ripristino; il blocco sparisce comunque se
/// l'app termina o va in crash, perché l'event tap vive nel processo.
/// Tap e timer girano su un thread dedicato: funzionano anche se il main thread è occupato.
final class InputBlocker {
    static let shared = InputBlocker()
    static let marker: Int64 = 0x5CE1E
    /// Tetto del blocco per ogni ripristino, in secondi.
    static var cap: TimeInterval = 8

    /// Tastiera + gesti (29 = gesture, 30 = dock swipe: i cambi desktop col trackpad).
    private static let mask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) |
        (1 << CGEventType.flagsChanged.rawValue) | (1 << 29) | (1 << 30)

    private let lock = NSLock()
    private var tap: CFMachPort?
    private var thread: Thread?
    private var enabled = false
    private var budget: TimeInterval = 8
    private var since: Date?
    private var generation = 0

    private init() {}

    /// Inizia un nuovo ripristino: azzera il tempo disponibile.
    func begin(maxSeconds: TimeInterval = 8) {
        lock.lock(); budget = maxSeconds; lock.unlock()
        resume()
    }

    /// Riattiva il blocco per il tempo rimasto (dopo una pausa).
    func resume() {
        lock.lock(); defer { lock.unlock() }
        guard !enabled, budget > 0.05 else { return }
        if tap == nil { startThread() }
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        enabled = true
        since = Date()
        generation += 1
        let gen = generation, remaining = budget
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + remaining) { [weak self] in
            self?.pause(onlyGeneration: gen)
        }
    }

    /// Sospende il blocco (es. l'utente deve rispondere a una richiesta di salvataggio).
    func pause(onlyGeneration gen: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let gen, gen != generation { return }
        guard enabled else { return }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        enabled = false
        if let s = since { budget -= Date().timeIntervalSince(s) }
        since = nil
    }

    func end() {
        pause()
        lock.lock(); budget = 0; lock.unlock()
    }

    var isBlocking: Bool { lock.lock(); defer { lock.unlock() }; return enabled }

    private func startThread() {
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: InputBlocker.mask, callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if InputBlocker.shared.isBlocking, let t = InputBlocker.shared.tap {
                        CGEvent.tapEnable(tap: t, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                if event.getIntegerValueField(.eventSourceUserData) == InputBlocker.marker {
                    return Unmanaged.passUnretained(event)
                }
                return nil
            }, userInfo: nil)
            self?.tap = tap
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            }
            ready.signal()
            if tap != nil { CFRunLoopRun() }
        }
        t.name = "Scene.InputBlocker"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        ready.wait()
        if tap == nil { Log.write("Keyboard lock unavailable (event tap not created)") }
    }
}
