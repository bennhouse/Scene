import Cocoa

/// Per le app che non espongono AXDocument (es. PdfCraft, WordCraft, GridCraft) ricava il file
/// aperto dal titolo della finestra, cercandolo con Spotlight. Il titolo può essere «file — App»
/// oppure solo il nome del file («Conti.xlsx»).
enum DocResolver {
    private static let separators = [" \u{2014} ", " \u{2013} ", " - ", " | "]

    /// Possibili nomi di file contenuti nel titolo, i più probabili per primi.
    static func names(in title: String, appName: String) -> [String] {
        var out: [String] = []
        func add(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard t.count >= 3, t.caseInsensitiveCompare(appName) != .orderedSame,
                  !t.localizedCaseInsensitiveContains(appName), !out.contains(t) else { return }
            out.append(t)
        }
        for sep in separators {
            let parts = title.components(separatedBy: sep)
            guard parts.count > 1 else { continue }
            for i in 1..<parts.count {
                add(parts[..<i].joined(separator: sep))
                add(parts[i...].joined(separator: sep))
            }
        }
        // Prima i nomi con estensione, poi i più lunghi.
        return Array(out.sorted {
            let a = !($0 as NSString).pathExtension.isEmpty, b = !($1 as NSString).pathExtension.isEmpty
            return a != b ? a : $0.count > $1.count
        }.prefix(6))
    }

    /// Titoli di documenti mai salvati: non corrispondono a un file.
    private static let placeholders = ["Untitled", "Senza titolo", "Sans titre", "Ohne Titel", "Sin título"]

    /// Il titolo sembra il nome di un file (ha un'estensione, anche prima di « — App»)?
    static func looksLikeFile(_ title: String) -> Bool {
        let first = separators.reduce(title) { $0.components(separatedBy: $1).first ?? $0 }
        let ext = (first.trimmingCharacters(in: .whitespaces) as NSString).pathExtension
        return (1...5).contains(ext.count) && ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Browser e web app: il titolo è quello della pagina, non di un file.
    private static let browsers = ["org.mozilla.firefox", "com.google.Chrome", "com.apple.Safari",
                                   "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser",
                                   "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "org.chromium.Chromium"]

    static func resolve(title: String, appName: String, appURL: URL) -> String? {
        let bid = Bundle(url: appURL)?.bundleIdentifier ?? ""
        if browsers.contains(bid) || bid.hasPrefix("com.apple.Safari.WebApp") || bid.hasPrefix("com.google.Chrome.app.") {
            return nil
        }
        let t = title.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3, !placeholders.contains(where: { t.localizedCaseInsensitiveContains($0) }) else { return nil }
        let hasSeparator = separators.contains { t.contains($0) }
        // Titolo senza separatori: è il nome del file. Con estensione basta che l'app sappia aprirlo;
        // senza estensione serve un solo file con quel nome, per non riaprire il file sbagliato.
        let candidates = hasSeparator ? names(in: t, appName: appName) : [t]
        for name in candidates {
            let hits = spotlight(name).filter { canOpen(appURL, $0) }
            if !hasSeparator && (name as NSString).pathExtension.isEmpty && hits.count != 1 { continue }
            if let best = hits.max(by: { lastUsed($0) < lastUsed($1) }) { return best.path }
        }
        return nil
    }

    private static func canOpen(_ app: URL, _ file: URL) -> Bool {
        NSWorkspace.shared.urlsForApplications(toOpen: file).contains {
            $0.standardizedFileURL.path == app.standardizedFileURL.path
        }
    }

    private static func lastUsed(_ u: URL) -> Date {
        if let d = NSMetadataItem(url: u)?.value(forAttribute: "kMDItemLastUsedDate") as? Date { return d }
        return (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func spotlight(_ name: String) -> [URL] {
        let esc = name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "*", with: "\\*")
        let query = "kMDItemFSName == \"\(esc)\"c || kMDItemFSName == \"\(esc).*\"c"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", NSHomeDirectory(), query]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(30)
            .map { URL(fileURLWithPath: String($0)) }
            .filter { u in
                let p = u.path
                if p.contains("/.Trash/") { return false }
                // ~/Library solo per Google Drive, iCloud Drive e simili.
                return !p.contains("/Library/") || p.contains("/Library/CloudStorage/") || p.contains("/Library/Mobile Documents/")
            }
    }
}
