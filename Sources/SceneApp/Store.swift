import Foundation

/// Archivio delle scene in ~/Library/Application Support/Scene/scenes.json
final class SceneStore: ObservableObject {
    @Published private(set) var scenes: [SavedScene] = []

    private let url: URL = {
        // SCENE_STORE_DIR: cartella alternativa (per i test, senza toccare le scene vere).
        let dir = ProcessInfo.processInfo.environment["SCENE_STORE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Scene")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scenes.json")
    }()

    /// false se il file esiste ma non si riesce a leggere: in quel caso non si salva nulla,
    /// per non sovrascrivere le scene con un elenco vuoto.
    private(set) var canSave = true

    init() { load() }

    func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { scenes = []; return }
        do {
            let data = try Data(contentsOf: url)
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            scenes = try dec.decode([SavedScene].self, from: data)
            canSave = true
        } catch {
            // File illeggibile: lo si mette da parte intatto e non si scrive sopra.
            let aside = url.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: aside)
            Log.write("Scene archive unreadable (\(error)); copied to \(aside.lastPathComponent), saving suspended")
            scenes = []
            canSave = false
        }
    }

    private func persist() {
        guard canSave else { Log.write("Save skipped: archive was unreadable at launch"); return }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            // Copia di sicurezza della versione precedente.
            let backup = url.deletingPathExtension().appendingPathExtension("bak.json")
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: url, to: backup)
            }
            try enc.encode(scenes).write(to: url, options: .atomic)
        } catch { Log.write("Saving scenes failed: \(error)") }
    }

    func add(_ s: SavedScene) { scenes.insert(s, at: 0); persist() }

    func replace(_ s: SavedScene) {
        guard let i = scenes.firstIndex(where: { $0.id == s.id }) else { return }
        scenes[i] = s; persist()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = scenes.firstIndex(where: { $0.id == id }) else { return }
        scenes[i].name = name; persist()
    }

    func setIcon(_ id: UUID, icon: String) {
        guard let i = scenes.firstIndex(where: { $0.id == id }) else { return }
        scenes[i].icon = icon; persist()
    }

    func delete(_ id: UUID) { scenes.removeAll { $0.id == id }; persist() }

    func scene(named n: String) -> SavedScene? { scenes.first { $0.name == n } }

    // MARK: - Configurazioni di monitor

    /// Identità della configurazione in cui è stata salvata una scena: i monitor esterni
    /// (Monitor + Mac) oppure lo schermo del Mac (Solo Mac), riconosciuti dal loro UUID.
    static func setupKey(_ s: SavedScene) -> String {
        let external = s.config == .monitorPlusMac
        return s.config.rawValue + ":" + s.displays.filter { $0.isBuiltin != external }
            .map(\.uuid).sorted().joined(separator: ",")
    }

    /// Numero progressivo della configurazione tra le scene dello stesso tipo, in ordine di
    /// salvataggio: la prima configurazione è 0, una configurazione diversa è 1, e così via.
    func setupIndex(_ s: SavedScene) -> Int {
        var keys: [String] = []
        for x in scenes.filter({ $0.config == s.config }).sorted(by: { $0.created < $1.created }) {
            let k = Self.setupKey(x)
            if !keys.contains(k) { keys.append(k) }
        }
        return keys.firstIndex(of: Self.setupKey(s)) ?? 0
    }

    // MARK: - Esporta / importa

    private struct ExportFile: Codable {
        var format = "local.scenerecall.Scene"
        var version = 1
        var scenes: [SavedScene]
    }

    func exportData(_ ids: Set<UUID>? = nil) throws -> Data {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(ExportFile(scenes: scenes.filter { ids?.contains($0.id) ?? true }))
    }

    /// Aggiunge le scene del file. Una scena già presente (stesso id) viene sostituita;
    /// un nome già usato da un'altra scena riceve un numero.
    @discardableResult
    func importData(_ data: Data) throws -> Int {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let incoming: [SavedScene]
        if let f = try? dec.decode(ExportFile.self, from: data) { incoming = f.scenes }
        else if let list = try? dec.decode([SavedScene].self, from: data) { incoming = list }
        else { incoming = [try dec.decode(SavedScene.self, from: data)] }
        for var s in incoming {
            if let i = scenes.firstIndex(where: { $0.id == s.id }) { scenes[i] = s; continue }
            let base = s.name
            var n = 2
            while scenes.contains(where: { $0.name == s.name }) { s.name = "\(base) \(n)"; n += 1 }
            scenes.append(s)
        }
        persist()
        return incoming.count
    }

    func nextDefaultName() -> String {
        var i = scenes.count + 1
        while scenes.contains(where: { $0.name == "Scene \(i)" }) { i += 1 }
        return "Scene \(i)"
    }
}
