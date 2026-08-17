import SwiftUI

// Pulsanti d'angolo di un riquadro: ingrandimento, inquadratura di ritorno, risoluzione.
//
// Sta in un file a parte da `ViewportChrome` per una ragione precisa: quella è una
// sovraimpressione con `allowsHitTesting(false)`, perché deve lasciare passare ogni clic alla
// vista Metal sotto. Questi invece devono ricevere i clic. Mescolarli significherebbe rendere
// cliccabile tutto il riquadro di sovraimpressione e perdere le interazioni sull'immagine.
//
// Restano semitrasparenti fino a quando il puntatore non entra nel riquadro. Sempre visibili a
// piena opacità distraevano dall'immagine, che è ciò che si deve guardare; comparire solo al
// passaggio del mouse li avrebbe resi invisibili a chi non sa che esistono. Il compromesso è
// mostrarli sempre, appena accennati.

struct ViewportActions: View {

    @Bindable var model: AppModel
    let slot: ViewportSlot

    @State private var isHovering = false

    private var isMaximized: Bool {
        model.layout == .single && model.focusedSlot == slot
    }

    var body: some View {
        HStack(spacing: 2) {
            if slot.anatomicalPlane != nil {
                resolutionMenu
                actionButton(
                    systemImage: "viewfinder",
                    help: "Inquadra tutto il volume"
                ) {
                    model.focusedSlot = slot
                    model.resetView(slot: slot)
                }
            }

            actionButton(
                systemImage: isMaximized
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                help: isMaximized ? "Torna alla griglia" : "Ingrandisci a piena finestra"
            ) {
                model.focusedSlot = slot
                model.layout = isMaximized ? .grid2x2 : .single
            }
        }
        .opacity(isHovering ? 1 : 0.35)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
        .padding(Metrics.spacingSmall)
        .padding(.top, Metrics.viewportBorderWidth)
    }

    private func actionButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 18, height: 18)
                .background(Palette.chrome.opacity(0.75), in: .rect(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.textSecondary)
        .help(help)
    }

    /// La risoluzione è una scelta globale, non per riquadro.
    ///
    /// Per riquadro sarebbe più flessibile e peggiore: con tre viste a risoluzioni diverse le
    /// immagini hanno nitidezza diversa a parità di zoom, e la differenza si legge come una
    /// differenza nei dati invece che nel rendering. Il comando sta su ogni riquadro perché è lì
    /// che serve averlo sotto mano, ma agisce su tutti.
    private var resolutionMenu: some View {
        Menu {
            Picker("Risoluzione", selection: $model.mprResolution) {
                ForEach(MPRResolution.allCases) { resolution in
                    Text(resolution.localizedName).tag(resolution)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "square.resize")
                .font(.system(size: 10, weight: .medium))
                .frame(width: 18, height: 18)
                .background(Palette.chrome.opacity(0.75), in: .rect(cornerRadius: 3))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(
            model.mprResolution == .full ? Palette.textSecondary : Palette.warning
        )
        .help("Risoluzione di rendering dei riquadri 2D")
    }
}
