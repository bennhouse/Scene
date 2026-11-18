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
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    @discardableResult
    static func run(_ source: String) -> String? {
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
                    set out to out & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & RS & (name of w) & RS & (index of current tab of w) & RS & u & linefeed
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
                    set out to out & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & RS & (title of active tab of w) & RS & (active tab index of w) & RS & u & RS & (mode of w) & linefeed
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

    static func openSafariWindow(urls: [String], activeTab: Int?) {
        guard let first = urls.first else { return }
        var s = "tell application id \"com.apple.Safari\"\n"
        s += "make new document with properties {URL:\(quote(first))}\n"
        s += "tell front window\n"
        for u in urls.dropFirst() { s += "make new tab at end of tabs with properties {URL:\(quote(u))}\n" }
        if let a = activeTab, a >= 1, a <= urls.count { s += "set current tab to tab \(a)\n" }
        s += "end tell\nend tell"
        run(s)
    }

    static func openChromeWindow(urls: [String], activeTab: Int?, incognito: Bool = false) {
        guard let first = urls.first else { return }
        var s = "tell application id \"com.google.Chrome\"\n"
        s += incognito ? "set w to make new window with properties {mode:\"incognito\"}\n" : "set w to make new window\n"
        s += "set URL of active tab of w to \(quote(first))\n"
        for u in urls.dropFirst() { s += "tell w to make new tab with properties {URL:\(quote(u))}\n" }
        if let a = activeTab, a >= 1, a <= urls.count { s += "set active tab index of w to \(a)\n" }
        s += "end tell"
        run(s)
    }
}
