import Cocoa

/// Lettura/apertura di contenuti tramite AppleScript (Finder, Safari, Chrome).
/// Gli script vengono eseguiti solo se l'app è già in esecuzione, per non avviarla.
enum Scripting {
    static let finder = "com.apple.finder"
    static let safari = "com.apple.Safari"
    static let chrome = "com.google.Chrome"

    struct ScriptWindow {
        var bounds: CGRect      // CG globale
        var title: String
        var folderPath: String?
        var urls: [String] = []
        var activeTab: Int?
        var incognito = false
        var id: Int?            // id AppleScript della finestra
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    @discardableResult
    static func run(_ source: String) -> String? { MainThread.sync { runOnMain(source) } }

    private static func runOnMain(_ source: String) -> String? {
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err { Log.write("AppleScript error: \(err[NSAppleScript.errorMessage] ?? err)") }
        return result?.stringValue
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // Separatori: RS (30) tra campi, US (31) tra URL, LF tra finestre.
    private static let header = """
    set RS to character id 30
    set US to character id 31
    set out to ""
    """

    private static func parse(_ raw: String?) -> [[String]] {
        (raw ?? "").split(separator: "\n").map { $0.components(separatedBy: "\u{1E}") }
    }

    private static func rect(_ s: String) -> CGRect? {
        let n = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard n.count == 4 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2] - n[0], height: n[3] - n[1])
    }

    static func finderWindows() -> [ScriptWindow] {
        guard isRunning(finder) else { return [] }
        let src = header + """

        tell application id "com.apple.finder"
            repeat with i from 1 to (count of Finder windows)
                try
                    set w to Finder window i
                    set b to bounds of w
                    set p to ""
                    try
                        set p to POSIX path of ((target of w) as alias)
                    end try
                    set out to out & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & RS & (name of w) & RS & p & linefeed
                end try
            end repeat
        end tell
        return out
        """
        return parse(run(src)).compactMap { f in
            guard f.count >= 3, let r = rect(f[0]) else { return nil }
            return ScriptWindow(bounds: r, title: f[1], folderPath: f[2].isEmpty ? nil : f[2])
        }
    }

    static func safariWindows() -> [ScriptWindow] {
        guard isRunning(safari) else { return [] }
        let src = header + """

        tell application id "com.apple.Safari"
            repeat with i from 1 to (count of windows)
                try
                    set w to window i
                    set b to bounds of w
                    set u to ""
                    repeat with t in (get tabs of w)
                        try
                            set u to u & (URL of t) & US
                        end try
                    end repeat
                    set out to out & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & RS & (name of w) & RS & (index of current tab of w) & RS & u & RS & "normal" & RS & (id of w) & linefeed
                end try
            end repeat
        end tell
        return out
        """
        return parseBrowser(run(src))
    }

    static func chromeWindows() -> [ScriptWindow] {
        guard isRunning(chrome) else { return [] }
        let src = header + """

        tell application id "com.google.Chrome"
            repeat with i from 1 to (count of windows)
                try
                    set w to window i
                    set b to bounds of w
                    set u to ""
                    repeat with t in (get tabs of w)
                        set u to u & (URL of t) & US
                    end repeat
                    set out to out & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & RS & (title of active tab of w) & RS & (active tab index of w) & RS & u & RS & (mode of w) & RS & (id of w) & linefeed
                end try
            end repeat
        end tell
        return out
        """
        return parseBrowser(run(src))
    }

    private static func parseBrowser(_ raw: String?) -> [ScriptWindow] {
        parse(raw).compactMap { f in
            guard f.count >= 4, let r = rect(f[0]) else { return nil }
            let urls = f[3].components(separatedBy: "\u{1F}").filter { !$0.isEmpty && $0 != "missing value" }
            var sw = ScriptWindow(bounds: r, title: f[1], urls: urls, activeTab: Int(f[2]))
            sw.incognito = f.count > 4 && f[4].trimmingCharacters(in: .whitespaces) == "incognito"
            if f.count > 5 { sw.id = Int(f[5].trimmingCharacters(in: .whitespacesAndNewlines)) }
            return sw
        }
    }

    // MARK: - Apertura

    static func openFinderWindow(path: String) {
        run("""
        set t to (POSIX file \(quote(path))) as alias
        tell application id "com.apple.finder" to make new Finder window to t
        """)
    }

    // Finestre del browser (Safari, Chrome), per id. Scene guarda cosa contiene una finestra e
    // fa solo quello che manca: aggiunge le schede assenti, chiude quelle vuote e i doppioni.

    /// Finestra nuova; restituisce il suo id.
    static func newBrowserWindow(_ bid: String, incognito: Bool) -> Int? {
        let make: String
        if bid == chrome {
            make = incognito ? "set w to make new window with properties {mode:\"incognito\"}" : "set w to make new window"
        } else {
            make = "make new document\nset w to front window"
        }
        let r = run("tell application id \(quote(bid))\n\(make)\nreturn id of w\nend tell")
        return r.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func inWindow(_ bid: String, _ id: Int, _ body: String) -> String? {
        run("tell application id \(quote(bid))\nset w to window id \(id)\n\(body)\nend tell")
    }

    /// Indirizzi delle schede, in ordine (vuoto per una scheda senza pagina).
    static func tabURLs(_ bid: String, window id: Int) -> [String] {
        let body = """
        set out to ""
        repeat with t in tabs of w
            set u to ""
            try
                set u to URL of t
            end try
            if u is missing value then set u to ""
            set out to out & u & linefeed
        end repeat
        return out
        """
        guard let r = inWindow(bid, id, body) else { return [] }
        return r.components(separatedBy: "\n").dropLast().map { $0 }
    }

    static func addTabs(_ bid: String, window id: Int, urls: [String]) {
        guard !urls.isEmpty else { return }
        let lines = urls.map { u in
            bid == chrome ? "tell w to make new tab with properties {URL:\(quote(u))}"
                          : "tell w to make new tab at end of tabs with properties {URL:\(quote(u))}"
        }
        _ = inWindow(bid, id, lines.joined(separator: "\n"))
    }

    /// Chiude le schede indicate (1-based), dall'ultima alla prima così gli indici restano validi.
    static func closeTabs(_ bid: String, window id: Int, indexes: [Int]) {
        guard !indexes.isEmpty else { return }
        _ = inWindow(bid, id, indexes.sorted(by: >).map { "close tab \($0) of w" }.joined(separator: "\n"))
    }

    static func selectTab(_ bid: String, window id: Int, index: Int) {
        _ = inWindow(bid, id, bid == chrome ? "set active tab index of w to \(index)"
                                            : "set current tab of w to tab \(index) of w")
    }

    /// Scheda senza una pagina vera (nuova scheda, pagina iniziale, preferiti).
    static func isBlank(_ url: String) -> Bool {
        let u = url.trimmingCharacters(in: .whitespaces)
        return u.isEmpty || u == "missing value" || u.hasPrefix("about:") || u.hasPrefix("chrome://newtab")
            || u.hasPrefix("chrome://new-tab-page") || u.hasPrefix("favorites:") || u.hasPrefix("topsites:")
    }
}
