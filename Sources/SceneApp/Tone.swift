import SwiftUI

/// Colore di testi e simboli. Con la finestra attiva usa lo stile indicato; con la finestra
/// non attiva tutti diventano dello stesso grigio, come nel Finder.
struct Tone: ViewModifier {
    @Environment(\.controlActiveState) private var state
    @Environment(\.isEnabled) private var isEnabled
    let style: AnyShapeStyle

    static let inactive = Color(nsColor: .secondaryLabelColor)
    static let disabled = Color(nsColor: .tertiaryLabelColor)

    func body(content: Content) -> some View {
        // Disabilitato: sempre il grigio chiaro dei controlli disabilitati, attiva o no la finestra.
        if !isEnabled { return content.foregroundStyle(AnyShapeStyle(Self.disabled)) }
        return content.foregroundStyle(state == .inactive ? AnyShapeStyle(Self.inactive) : style)
    }
}

extension View {
    func tone<S: ShapeStyle>(_ style: S) -> some View { modifier(Tone(style: AnyShapeStyle(style))) }
}

/// Icone dei pulsanti della barra: il loro stile ignora il colore impostato, quindi a finestra
/// non attiva si schiariscono con la trasparenza, come il menu Esporta che macOS schiarisce da sé.
struct ToolbarDim: ViewModifier {
    @Environment(\.controlActiveState) private var state
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View {
        content.opacity(state == .inactive && isEnabled ? 0.6 : 1)
    }
}
