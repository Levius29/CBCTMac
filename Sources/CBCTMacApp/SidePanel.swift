import SwiftUI

// Pannello richiudibile della colonna di sinistra.
//
// Quattro pannelli impilati — Regolazioni, Strumenti, Oggetti, Esporta — di cui in genere uno
// solo interessa. Tenerli tutti aperti riempirebbe la colonna e costringerebbe a scorrere per
// arrivare a quello che serve; tenerli tutti chiusi costringerebbe a un clic ogni volta.
//
// Lo stato di apertura **si ricorda**, ed è la parte che sembra un dettaglio e non lo è: chi
// lavora sugli impianti tiene aperto «Oggetti» e chiuso il resto, e ritrovare la propria
// disposizione a ogni avvio è la differenza fra un pannello che si usa e uno che si richiude ogni
// volta.

struct SidePanel<Content: View>: View {

    let title: String
    let systemImage: String
    /// Chiave di memoria. Stringa e non enum perché la memoria vive in `UserDefaults`, che di
    /// enum non sa nulla.
    let storageKey: String
    /// Se aperto la prima volta, prima che l'utente esprima una preferenza.
    var initiallyExpanded: Bool = true
    /// Riepilogo mostrato accanto al titolo quando il pannello è chiuso: dice che cosa contiene
    /// senza doverlo aprire.
    var badge: String?

    @ViewBuilder let content: () -> Content

    @AppStorage private var isExpanded: Bool

    init(
        title: String,
        systemImage: String,
        storageKey: String,
        initiallyExpanded: Bool = true,
        badge: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.storageKey = storageKey
        self.initiallyExpanded = initiallyExpanded
        self.badge = badge
        self.content = content
        _isExpanded = AppStorage(wrappedValue: initiallyExpanded, "panel.\(storageKey)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(Palette.textSecondary)
                    Image(systemName: systemImage)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                        .frame(width: 14)
                    Text(title.uppercased())
                        .font(Typography.sectionHeader)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer(minLength: 4)
                    if let badge, !isExpanded {
                        Text(badge)
                            .font(Typography.numericSmall)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .padding(.horizontal, Metrics.spacing + 2)
                .padding(.vertical, 7)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .padding(.horizontal, Metrics.spacing + 2)
                    .padding(.bottom, Metrics.spacing + 2)
            }

            Divider().overlay(Palette.separator)
        }
    }
}
