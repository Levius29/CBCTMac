import StudyKit
import SwiftUI

// La barra dei modi di lavoro.
//
// Cinque schede, non cinque disposizioni. La differenza si vede nel gesto che si risparmia: con
// un selettore di disposizione, passare dall'esame ortogonale alla valutazione della cresta
// significa cambiare disposizione, cambiare riquadro attivo, prendere lo strumento arcata e
// accendere il panorex. Con le schede è un clic, e quei quattro aggiustamenti *sono* la
// definizione del modo.
//
// Sta sotto il banner e sopra tutto il resto perché è la scelta più in alto nella gerarchia:
// decide che cosa mostrano i riquadri, e quindi va letta prima di essi.

struct WorkModeBar: View {

    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WorkMode.allCases) { mode in
                tab(mode)
            }
            Spacer(minLength: Metrics.spacingLarge)

            // A che serve il modo, in una riga. Due modi possono avere la stessa disposizione —
            // «personalizzato» e «obliquo» sono entrambi uno grande e tre — e senza una parola
            // che li distingua sembrerebbero due schede identiche.
            Text(model.workMode.hint)
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)

            if !model.workMode.isEditable {
                // Detto a parole e non solo con gli strumenti spenti: uno strumento che non
                // risponde senza spiegazione sembra un difetto del programma.
                Label("Sola lettura", systemImage: "lock")
                    .font(Typography.label)
                    .foregroundStyle(Palette.warning)
                    .padding(.leading, Metrics.spacing)
            }
        }
        .padding(.horizontal, Metrics.spacing)
        .frame(height: 34)
        .background(Palette.chrome)
    }

    @ViewBuilder
    private func tab(_ mode: WorkMode) -> some View {
        let isActive = model.workMode == mode
        Button {
            model.activate(mode: mode)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.systemImageName)
                    .font(.system(size: 11))
                Text(mode.shortName)
                    .font(Typography.label)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                isActive ? Palette.chromeElevated : Color.clear,
                in: .rect(cornerRadius: Metrics.cornerRadius))
            .overlay(alignment: .bottom) {
                // Il filo sotto la scheda attiva, non solo il fondo più chiaro: su un tema scuro
                // due grigi vicini si distinguono male, e quale scheda è attiva è la cosa che si
                // deve poter leggere con la coda dell'occhio.
                Rectangle()
                    .fill(isActive ? Palette.accent : .clear)
                    .frame(height: 2)
            }
            .foregroundStyle(isActive ? Palette.textPrimary : Palette.textSecondary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(mode.localizedName)
    }
}
