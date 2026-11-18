import SwiftUI
import UniformTypeIdentifiers

/// Misure fisse della finestra, usate per allineare i testi delle due colonne.
enum Layout {
    static let footerHeight: CGFloat = 37
    /// Check + menu più lungo + testo + margini della barra in basso, con un po' di respiro.
    static let detailMinWidth: CGFloat = 470
}

struct ContentView: View {
    @EnvironmentObject var store: SceneStore
    @EnvironmentObject var restorer: Restorer
    @EnvironmentObject var prefs: Prefs
    @State private var selection: UUID?
    @State private var naming: NameSheet?
    @State private var confirmDelete: SavedScene?
    @State private var confirmOverwrite: SavedScene?
    @State private var editingTitle = false
    @FocusState private var sidebarFocused: Bool
    @State private var columns: NavigationSplitViewVisibility = .all
    @State private var trusted = AX.isTrusted
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    struct NameSheet: Identifiable {
        let id = UUID()
        var renaming: UUID?
        var name: String
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.scenes) { s in
                            SceneRow(scene: s, setup: store.setupIndex(s))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                // Selezione: fondo grigio tenue al posto del blu di sistema.
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Color.primary.opacity(selection == s.id ? 0.11 : 0))
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { selection = s.id; sidebarFocused = true }
                                // VoiceOver: ogni riga è un pulsante selezionabile.
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(s.name), \(s.windows.count) windows, \(s.config.label)")
                                .accessibilityAddTraits(selection == s.id ? [.isButton, .isSelected] : .isButton)
                                .accessibilityAction { selection = s.id }
                                .contextMenu {
                                    Button("Restore") { restore(s) }
                                    Button("Rename") { selection = s.id; editingTitle = true }
                                    Button("Update with Current Windows…") { confirmOverwrite = s }
                                    Button("Export…") { SceneFiles.export(store, only: [s.id], suggested: s.name) }
                                    Divider()
                                    Button("Delete", role: .destructive) { confirmDelete = s }
                                }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    // Tutta l'altezza della colonna: un clic nella parte vuota toglie la selezione.
                    // I clic sulle righe hanno un loro gesto, che ha la precedenza su questo.
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture { selection = nil; editingTitle = false; sidebarFocused = true }
                }
                // Frecce su/giù per scorrere le scene, come in un elenco normale.
                .focusable()
                .focusEffectDisabled()
                .focused($sidebarFocused)
                .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
                .onKeyPress(.downArrow) { moveSelection(1); return .handled }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 380)
            .toolbar(removing: .sidebarToggle)
            .overlay {
                if store.scenes.isEmpty {
                    // Il blocco intero è centrato alla stessa altezza di «Nessuna scena selezionata»:
                    // stesso spazio verticale (la colonna ha già il margine della barra del titolo;
                    // si aggiunge quello della barra in basso, che qui non c'è).
                    VStack(spacing: 6) {
                        Text("No Scenes").tone(.secondary)
                        Text("Press + to save the open windows.")
                            .font(.caption).tone(.tertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 170)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, Layout.footerHeight)
                        .allowsHitTesting(false)
                }
            }
        } detail: {
            Group {
                if let s = store.scenes.first(where: { $0.id == selection }) {
                    SceneDetail(scene: s, restore: { restore(s) })
                } else {
                    Text("No Scene Selected").tone(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Barra in basso solo sotto la colonna di destra: la barra laterale arriva fino in fondo.
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
            // Larghezza minima della colonna: la barra in basso resta sempre su una riga.
            .navigationSplitViewColumnWidth(min: Layout.detailMinWidth, ideal: 600)
            .navigationTitle("Scene")
            .toolbar(removing: .title)
            .background(ToolbarSpacer())
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    TitleEditor(scene: selected, editing: $editingTitle,
                                onRename: { new in if let s = selected { store.rename(s.id, to: new) } },
                                onIcon: { icon in if let s = selected { store.setIcon(s.id, icon: icon) } })
                }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { naming = NameSheet(renaming: nil, name: store.nextDefaultName()) } label: {
                    Label("New Scene", systemImage: "plus").toolbarIcon()
                }
                .keyboardShortcut("n")
                .disabled(restorer.isRunning)
                .help("New scene from the open windows (⌘N)")
                Button { confirmOverwrite = selected } label: {
                    Label("Update", systemImage: "arrow.clockwise").toolbarIcon()
                }
                .disabled(selected == nil || restorer.isRunning)
                .help("Update the selected scene with the open windows")
                Menu {
                    Button("Export Selected Scene…") {
                        if let s = selected { SceneFiles.export(store, only: [s.id], suggested: s.name) }
                    }
                    .disabled(selected == nil)
                    Button("Export All Scenes…") { SceneFiles.export(store, only: nil, suggested: "Scene") }
                        .disabled(store.scenes.isEmpty)
                    Divider()
                    Button("Import Scenes…") { SceneFiles.importScenes(store, restorer: restorer) }
                } label: {
                    Label("Export and Import", systemImage: "square.and.arrow.up").toolbarIcon()
                }
                .menuIndicator(.hidden)
                .help("Export or import scenes")
                Button(role: .destructive) { confirmDelete = selected } label: {
                    Label("Delete", systemImage: "trash").toolbarIcon()
                }
                // Non mentre si rinomina: nel campo ⌘⌫ cancella il testo, non la scena.
                .keyboardShortcut(editingTitle ? nil : KeyboardShortcut(.delete))
                .disabled(selected == nil)
                .help("Delete the selected scene (⌘⌫)")
            }
        }
        }
        .onChange(of: columns) { _, v in if v != .all { columns = .all } }
        // Testi senza uno stile proprio: stesso grigio delle altre scritte a finestra non attiva.
        .tone(.primary)
        .onChange(of: selection) { _, _ in editingTitle = false }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !trusted { PermissionBanner() }
        }
        .sheet(item: $naming) { sheet in
            NamePrompt(title: sheet.renaming == nil ? "New Scene" : "Rename Scene",
                       action: sheet.renaming == nil ? "Save" : "Rename",
                       name: sheet.name) { name in
                if let id = sheet.renaming { store.rename(id, to: name) }
                else {
                    Task {
                        // Lascia chiudere il foglio prima di aggiornare la lista.
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        let s = await Capture.full(name: name, restorer: restorer)
                        var t = Transaction(); t.disablesAnimations = true
                        withTransaction(t) { store.add(s); selection = s.id }
                        restorer.status = "Saved «\(name)»: \(s.windows.count) windows (\(s.config.label))"
                    }
                }
            }
        }
        .confirmationDialog("Delete «\(confirmDelete?.name ?? "")»?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let s = confirmDelete { store.delete(s.id); if selection == s.id { selection = nil } }
            }
        } message: {
            Text("The scene will be removed. Open apps and windows are not affected.")
        }
        .alert("Replace «\(confirmOverwrite?.name ?? "")»?", isPresented: Binding(
            get: { confirmOverwrite != nil }, set: { if !$0 { confirmOverwrite = nil } })) {
            Button("Replace", role: .destructive) { if let s = confirmOverwrite { overwrite(s) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved scene will be replaced with the apps and windows open now. This can't be undone.")
        }
        .onReceive(timer) { _ in trusted = AX.isTrusted }
        .onAppear {
            if selection == nil { selection = store.scenes.first?.id }
            if !store.canSave {
                restorer.status = "The scene archive could not be read. It was set aside and changes are not being saved."
            }
        }
    }

    private var selected: SavedScene? { store.scenes.first { $0.id == selection } }

    private func moveSelection(_ step: Int) {
        guard !store.scenes.isEmpty else { return }
        let i = store.scenes.firstIndex { $0.id == selection } ?? (step > 0 ? -1 : store.scenes.count)
        let j = min(max(i + step, 0), store.scenes.count - 1)
        selection = store.scenes[j].id
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            if !restorer.waitingApps.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle.fill").tone(.orange)
                    Text("Paused: answer the prompt in \(restorer.waitingApps.joined(separator: ", ")). Restoring resumes when the window closes.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Continue Without Waiting") { restorer.skipWait() }
                    Button("Stop", role: .destructive) { restorer.abort() }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
                Divider()
            }
            // Linea di base comune: il testo del check, quello dentro il menu e quello dopo
            // stanno sulla stessa riga.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Toggle("Close", isOn: $prefs.closeFirst)
                    .fixedSize()
                    .help("Before restoring, close windows on every desktop. Apps can ask to save.")
                Picker("What to close", selection: $prefs.closeMode) {
                    ForEach(CloseMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                Text("before restoring a scene")
                    .lineLimit(1)
                    .fixedSize()
                Spacer()
                if restorer.isRunning { ProgressView().controlSize(.small) }
                Text(restorer.status).font(.callout).tone(.secondary).lineLimit(1).truncationMode(.middle)
                    .layoutPriority(-1)
            }
            .padding(.horizontal, 12)
            .frame(height: Layout.footerHeight - 1)
        }
        // Nessuno sfondo proprio: si vede quello della colonna di destra
        // («Nessuna scena selezionata»), quindi il colore è identico.
    }

    private func restore(_ s: SavedScene) {
        Task { await restorer.restore(s, closeFirst: prefs.closeFirst, mode: prefs.closeMode) }
    }

    private func overwrite(_ s: SavedScene) {
        Task {
            var n = await Capture.full(name: s.name, restorer: restorer)
            n.id = s.id
            n.icon = s.icon
            store.replace(n)
            restorer.status = "Updated «\(s.name)»: \(n.windows.count) windows"
        }
    }
}

/// Pannelli di esportazione e importazione (usati dalla barra degli strumenti e dal menu Archivio).
enum SceneFiles {
    @MainActor
    static func export(_ store: SceneStore, only ids: Set<UUID>?, suggested: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggested + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportData(ids).write(to: url, options: .atomic) }
        catch { NSAlert(error: error).runModal() }
    }

    @MainActor
    static func importScenes(_ store: SceneStore, restorer: Restorer) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var total = 0
        for url in panel.urls {
            do { total += try store.importData(Data(contentsOf: url)) }
            catch {
                let a = NSAlert()
                a.messageText = "Couldn't import «\(url.lastPathComponent)»"
                a.informativeText = "The file doesn't contain valid scenes."
                a.runModal()
            }
        }
        if total > 0 { restorer.status = total == 1 ? "Imported 1 scene" : "Imported \(total) scenes" }
    }
}

struct SceneRow: View {
    let scene: SavedScene
    let setup: Int
    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            SceneIconView(icon: scene.icon, size: 19)
            VStack(alignment: .leading, spacing: 3) {
                Text(scene.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    ConfigBadge(scene: scene, setup: setup, compact: true)
                    Text("\(scene.windows.count) windows").tone(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Bolla della configurazione di monitor. Colore pastello diverso per ogni configurazione
/// (monitor diversi); nella barra laterale solo l'icona, nel dettaglio icona e scritta.
struct ConfigBadge: View {
    let scene: SavedScene
    let setup: Int
    var compact = false

    private static let monitorColors: [Color] = [.blue, .green, .purple, .teal, .pink, .indigo, .mint, .cyan]
    private static let macColors: [Color] = [.orange, .yellow, .red, .brown, .pink, .mint]

    private var color: Color {
        let list = scene.config == .monitorPlusMac ? Self.monitorColors : Self.macColors
        return list[setup % list.count]
    }

    private var symbol: String { scene.config == .monitorPlusMac ? "display.2" : "laptopcomputer" }

    /// Nomi dei monitor, mostrati passando col mouse sulla bolla.
    private var displayNames: String {
        scene.displays.sorted { !$0.isBuiltin && $1.isBuiltin }.map(\.name).joined(separator: " + ")
    }

    var body: some View {
        Group {
            if compact {
                Image(systemName: symbol)
            } else {
                Label(scene.config.label, systemImage: symbol)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, compact ? 5 : 6).padding(.vertical, 1)
        .background(Capsule().fill(color.opacity(0.17)))
        .help(displayNames)
    }
}

struct SceneDetail: View {
    let scene: SavedScene
    let restore: () -> Void
    @EnvironmentObject var restorer: Restorer
    @EnvironmentObject var store: SceneStore

    private struct Group: Identifiable {
        var id: String { "\(display.uuid)-\(ordinal)" }
        let display: SavedDisplay
        let ordinal: Int
        let windows: [SavedWindow]
    }

    private var groups: [Group] {
        scene.displays.sorted { !$0.isBuiltin && $1.isBuiltin }.flatMap { d in
            Set(scene.windows.filter { $0.displayUUID == d.uuid }.map(\.desktopOrdinal)).sorted().map { o in
                Group(display: d, ordinal: o,
                      windows: scene.windows.filter { $0.displayUUID == d.uuid && $0.desktopOrdinal == o })
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 8) {
                        ConfigBadge(scene: scene, setup: store.setupIndex(scene))
                        Text(scene.created.formatted(date: .abbreviated, time: .shortened))
                            .tone(.secondary)
                    }.font(.callout)
                    Spacer()
                    Button(action: restore) { Label("Restore", systemImage: "play.fill") }
                        .keyboardShortcut("r")
                        .help("Restore the scene (⌘R)")
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(restorer.isRunning)
                }
                ForEach(groups) { g in
                    VStack(alignment: .leading, spacing: 6) {
                        Label("\(g.display.name) · Desktop \(g.ordinal)",
                              systemImage: g.display.isBuiltin ? "laptopcomputer" : "display")
                            .font(.headline)
                        ForEach(g.windows) { w in WindowRow(window: w) }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
                }
            }
            .padding(20)
        }
    }
}

struct WindowRow: View {
    let window: SavedWindow

    /// Titolo senza il nome dell'app ripetuto in fondo («Documento - App» → «Documento»).
    private var shortTitle: String? {
        guard var t = window.title, t != window.appName else { return nil }
        for sep in [" - ", " \u{2013} ", " \u{2014} ", " | "] where t.hasSuffix(sep + window.appName) {
            t = String(t.dropLast(sep.count + window.appName.count))
        }
        return t.trimmingCharacters(in: CharacterSet(charactersIn: " •"))
    }
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: window.appPath))
                .resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(window.appName)
                    if let t = shortTitle, !t.isEmpty {
                        Text(t).tone(.secondary)
                    }
                }
                .lineLimit(1)
                if let s = window.content.summary {
                    Text(s + (window.content.documentFromTitle == true ? " (from title)" : ""))
                        .font(.caption).tone(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Text(verbatim: "\(Int(window.frame.width))×\(Int(window.frame.height))")
                .font(.caption.monospacedDigit()).tone(.tertiary)
        }
    }
}

struct PermissionBanner: View {
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").tone(.yellow)
            Text("Scene needs Accessibility access to move windows and switch desktops.")
            Spacer()
            Button("Open Settings") {
                AX.requestTrust()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
        .font(.callout)
        .padding(10)
        .background(Color.yellow.opacity(0.15))
    }
}

struct NamePrompt: View {
    let title: String
    let action: String
    @State var name: String
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    init(title: String, action: String, name: String, onDone: @escaping (String) -> Void) {
        self.title = title; self.action = action; _name = State(initialValue: name); self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 300)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action, action: commit).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func commit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        onDone(n); dismiss()
    }
}

// MARK: - Impostazioni

struct SettingsView: View {
    @EnvironmentObject var prefs: Prefs
    var body: some View {
        Form {
            Section {
                ShortcutField(label: "Desktop to the left", shortcut: $prefs.left)
                ShortcutField(label: "Desktop to the right", shortcut: $prefs.right)
                Text("These must match System Settings › Keyboard › Keyboard Shortcuts › Mission Control.")
                    .font(.caption).tone(.secondary)
                Button("Use the System Shortcuts") { prefs.left = .defaultLeft; prefs.right = .defaultRight }
            } header: { Text("Shortcuts for switching desktops") }
            Section {
                HStack {
                    Slider(value: $prefs.settleDelay, in: 0.1...1.5, step: 0.05)
                    Text(String(format: "%.2f s", prefs.settleDelay)).monospacedDigit().frame(width: 60)
                }
            } header: { Text("Pause after each desktop switch") }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}

struct ShortcutField: View {
    let label: String
    @Binding var shortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Button(recording ? "Press the shortcut…" : shortcut.display) { recording ? stop() : start() }
                .frame(minWidth: 150)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }   // Esc annulla
            if let s = Shortcut(event: e) { shortcut = s; stop(); return nil }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

/// Icona e nome della scena nella barra del titolo.
/// Clic sull'icona: scelta dell'icona. Clic sul nome: rinomina.
struct TitleEditor: View {
    let scene: SavedScene?
    @Binding var editing: Bool
    let onRename: (String) -> Void
    let onIcon: (String) -> Void
    @State private var iconPopover = IconPopover()
    @State private var fieldWidth: CGFloat = 120

    /// Larghezza del campo: quella del testo più il margine interno del campo.
    private static func width(for text: String) -> CGFloat {
        let w = (text as NSString).size(withAttributes: [.font: RenameField.font]).width
        return min(max(w + 12, 60), 360)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let scene {
                SceneIconView(icon: scene.icon, size: 22)
                    .overlay(ClickArea { view in
                        // Ancorato alla vista che riceve il clic: coincide con l'icona.
                        iconPopover.show(from: view) {
                            IconPicker(icon: scene.icon) { onIcon($0); iconPopover.close() }
                        }
                    })
                    .help("Change icon")
            }
            if editing, let name = scene?.name {
                RenameField(initial: name, onText: { fieldWidth = Self.width(for: $0) }) { result in
                    if let n = result?.trimmingCharacters(in: .whitespaces), !n.isEmpty, n != name { onRename(n) }
                    editing = false
                }
                .frame(width: fieldWidth, height: 22)
                // Il testo del campo resta esattamente dove stava il titolo: compensa il margine
                // interno del campo e disegna il riquadro all'esterno del testo.
                .offset(x: -RenameField.textInset)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                        .padding(.horizontal, -6)
                        .padding(.vertical, -3)
                        .offset(x: -RenameField.textInset)
                )
                .onAppear { fieldWidth = Self.width(for: name) }
            } else {
                Text(scene?.name ?? "Scene")
                    .font(Font(RenameField.font))
                    .lineLimit(1)
                    .overlay(ClickArea { _ in if scene != nil { editing = true } })
                    .help(scene != nil ? "Rename" : "")
            }
        }
        .tone(.primary)
        .padding(.leading, 6)
    }
}

/// Campo AppKit: prende il focus appena compare. Invio conferma, Esc annulla, clic altrove conferma.
struct RenameField: NSViewRepresentable {
    static let font = NSFont.systemFont(ofSize: 17, weight: .bold)
    /// Margine orizzontale tra il bordo del campo (senza riquadro) e il testo.
    static let textInset: CGFloat = 2
    let initial: String
    var onText: (String) -> Void = { _ in }
    let done: (String?) -> Void   // nil = annullato

    func makeCoordinator() -> Coordinator { Coordinator(onText: onText, done: done) }

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: initial)
        f.font = Self.font
        f.isBezeled = false
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.delegate = context.coordinator
        DispatchQueue.main.async {
            f.window?.makeFirstResponder(f)
            f.currentEditor()?.selectAll(nil)
        }
        return f
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {}

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let onText: (String) -> Void
        let done: (String?) -> Void
        private var finished = false
        init(onText: @escaping (String) -> Void, done: @escaping (String?) -> Void) {
            self.onText = onText; self.done = done
        }

        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSTextField { onText(f.stringValue) }
        }

        private func finish(_ value: String?) {
            guard !finished else { return }
            finished = true
            done(value)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) { finish(nil); return true }
            if selector == #selector(NSResponder.insertNewline(_:)) { finish(textView.string); return true }
            return false
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            finish((obj.object as? NSTextField)?.stringValue)
        }
    }
}

extension View {
    /// Icone della barra un po' più grandi del default.
    func toolbarIcon() -> some View {
        self.font(.system(size: 17, weight: .regular)).imageScale(.large).modifier(ToolbarDim())
    }
}


/// Popover AppKit (quello di SwiftUI non si apre dagli elementi della barra degli strumenti),
/// aperto sotto la vista indicata e centrato su di essa.
final class IconPopover: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?

    func show<Content: View>(from view: NSView, @ViewBuilder content: () -> Content) {
        if popover != nil { close(); return }
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        let host = NSHostingController(rootView: content())
        // Misura fissata prima di aprire: se SwiftUI la calcola dopo, il popover si allarga
        // da un lato solo e non resta centrato sull'icona.
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        host.preferredContentSize = size
        p.contentSize = size
        p.contentViewController = host
        p.delegate = self
        popover = p
        p.show(relativeTo: view.bounds, of: view, preferredEdge: view.isFlipped ? .maxY : .minY)
    }

    func close() { popover?.performClose(nil) }

    func popoverDidClose(_ notification: Notification) { popover = nil }
}

/// Zona cliccabile nella barra del titolo: un clic esegue l'azione e il trascinamento
/// non sposta la finestra (la barra è trascinabile solo fuori da icona e nome).
struct ClickArea: NSViewRepresentable {
    let action: (NSView) -> Void

    func makeNSView(context: Context) -> ClickView { ClickView(action: action) }
    func updateNSView(_ v: ClickView, context: Context) { v.action = action }

    final class ClickView: NSView {
        var action: (NSView) -> Void
        init(action: @escaping (NSView) -> Void) { self.action = action; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            if bounds.contains(convert(event.locationInWindow, from: nil)) { action(self) }
        }
    }
}

/// Spazio flessibile tra nome della scena e pulsanti: li spinge a destra, come farebbe il
/// titolo nativo (che qui è nascosto per mostrare icona e nome modificabili).
struct ToolbarSpacer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        // SwiftUI può ricostruire la barra: si ricontrolla a ogni aggiornamento.
        for delay in [0.0, 0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let tb = v.window?.toolbar, tb.items.count > 1,
                      !tb.items.contains(where: { $0.itemIdentifier == .flexibleSpace }) else { return }
                tb.insertItem(withItemIdentifier: .flexibleSpace, at: 1)
            }
        }
    }
}
