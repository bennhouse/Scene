import SwiftUI

/// Icone delle scene: un insieme compatto di simboli di sistema semplici.
enum SceneIcons {
    static let defaultIcon = "square.stack"

    static let pool: [String] = [
        // Lavoro
        "square.stack", "briefcase", "laptopcomputer", "desktopcomputer", "doc.text", "folder",
        "tray.full", "archivebox", "chart.bar", "chart.pie", "calendar", "clock",
        "envelope", "paperplane", "phone", "printer", "signature", "list.bullet",
        // Studio
        "book", "books.vertical", "graduationcap", "pencil", "highlighter", "lightbulb",
        "magnifyingglass", "brain.head.profile", "text.book.closed", "doc.richtext", "note.text", "bookmark",
        // Creatività
        "paintbrush", "paintpalette", "photo", "camera", "film", "video",
        "music.note", "headphones", "mic", "pianokeys", "scissors", "sparkles",
        // Sviluppo
        "terminal", "chevron.left.forwardslash.chevron.right", "cube", "hammer", "wrench.and.screwdriver", "gearshape",
        "server.rack", "cpu", "puzzlepiece", "ladybug", "network", "globe",
        // Tempo libero e persone
        "house", "gamecontroller", "tv", "cup.and.saucer", "fork.knife", "cart",
        "airplane", "car", "dumbbell", "leaf", "sun.max", "moon",
        "person", "person.2", "bubble.left.and.bubble.right", "heart", "star", "flag",
    ]

    /// Solo i simboli presenti in questa versione di macOS.
    static var available: [String] {
        pool.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
    }
}

/// Icona di una scena: solo il simbolo, dello stesso colore del testo.
struct SceneIconView: View {
    let icon: String?
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: icon ?? SceneIcons.defaultIcon)
            .font(.system(size: size * 0.72, weight: .medium))
            .tone(.primary)
            .frame(width: size, height: size)
    }
}

/// Selettore dell'icona: una griglia compatta, senza scorrimento.
struct IconPicker: View {
    let icon: String?
    let onChange: (String) -> Void
    @State private var hovered: String?

    private static let tile: CGFloat = 28
    private static let gap: CGFloat = 4
    private let columns = Array(repeating: GridItem(.fixed(IconPicker.tile), spacing: IconPicker.gap), count: 6)

    var body: some View {
        let current = icon ?? SceneIcons.defaultIcon
        LazyVGrid(columns: columns, spacing: Self.gap) {
            ForEach(SceneIcons.available, id: \.self) { name in
                let selected = name == current
                // Selezionata: fondo grigio tenue; al passaggio del mouse, ancora più tenue.
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.14 : (hovered == name ? 0.06 : 0)))
                    .overlay(
                        Image(systemName: name)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .tone(.primary)
                    )
                    .frame(width: Self.tile, height: Self.tile)
                    .contentShape(Rectangle())
                    .onHover { hovered = $0 ? name : (hovered == name ? nil : hovered) }
                    .onTapGesture { onChange(name) }
                    .accessibilityLabel(name)
            }
        }
        .padding(10)
        .fixedSize()
    }
}
