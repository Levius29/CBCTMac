import DICOMCore
import MeshKit
import SegmentKit
import SwiftUI

// Il pannello della separazione dei tessuti.
//
// # Che cosa promette, e che cosa no
//
// Promette il modello di un dente e quello dell'osso senza i denti dentro. Non promette di
// trovare i denti da solo, ed è scritto qui perché sia chiaro guardando: i marcatori li mette
// chi guarda, uno per oggetto. Il riconoscimento automatico su una CBCT con otturazioni
// metalliche sbaglia in modi che non si vedono nel risultato, e un modello sbagliato in silenzio
// è peggio di nessun modello.
struct TissueSeparationPanel: View {

    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            SectionHeader("SEPARA I TESSUTI")

            Text(
                model.needsBoneSeed
                    ? "Prendi il marcatore e fai clic **dentro l'osso**. Poi uno dentro ogni "
                        + "dente da separare."
                    : "Un marcatore per dente, al centro della corona. Poi «Separa»."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Metrics.spacingSmall) {
                Button(model.activeTool == .tissueSeed ? "Marcatore in mano" : "Prendi il marcatore") {
                    model.activeTool = .tissueSeed
                }
                .disabled(model.volume == nil || model.activeTool == .tissueSeed)

                if !model.needsBoneSeed {
                    Text("Dente")
                        .font(Typography.label)
                        .foregroundStyle(Palette.textSecondary)
                    Menu("\(model.pendingTissueToothNumber)") {
                        ForEach(fdiNumbers, id: \.self) { number in
                            Button("\(number)") { model.pendingTissueToothNumber = number }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            if !model.tissueSeeds.isEmpty {
                ForEach(model.tissueSeeds) { seed in
                    HStack(spacing: Metrics.spacingSmall) {
                        Circle()
                            .fill(Color(hexString: seed.colorHex) ?? Palette.textPrimary)
                            .frame(width: 9, height: 9)
                        Text(seed.name).font(Typography.label)
                        Spacer(minLength: 0)
                        if let mesh = model.tissueMeshes[seed.label] {
                            Text("\(mesh.triangles.count) △")
                                .font(Typography.numericSmall)
                                .foregroundStyle(Palette.textSecondary)
                            Button {
                                model.exportTissue(label: seed.label)
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                            }
                            .buttonStyle(.plain)
                            .help("Esporta \(seed.name) come STL.")
                        }
                        Button {
                            model.removeTissueSeed(seed.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.danger)
                        .help("Togli questo marcatore.")
                    }
                }
            }

            LabeledSlider(
                label: "Soglia minima", value: $model.tissueLowerGV,
                range: 200...2500, format: "%.0f GV")
            LabeledSlider(
                label: "Passo superficie", value: $model.tissueSpacingMM,
                range: 0.2...1.5, format: "%.2f mm")

            HStack(spacing: Metrics.spacingSmall) {
                Button(model.isSeparatingTissues ? "Separazione…" : "Separa") {
                    Task { await model.separateTissues() }
                }
                .disabled(
                    model.isSeparatingTissues || model.tissueSeeds.count < 2
                        || model.volume == nil)
                Button("Azzera") { model.clearTissueSeeds() }
                    .disabled(model.tissueSeeds.isEmpty)
            }

            if let message = model.tissueMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(Typography.label)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Detto una volta, dove si guarda il risultato: quel che gli artefatti hanno
            // cancellato non torna. Su una corona metallica la dentina attorno è bruciata, e lì
            // non c'è dato da separare — il modello avrà un buco, e non è un difetto del
            // programma ma dell'immagine.
            Text(
                "Dove una corona metallica ha bruciato il dato, il modello resta incompleto: "
                + "lì non c'è nulla da segmentare."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// I numeri FDI dei denti permanenti.
    private var fdiNumbers: [Int] {
        (1...4).flatMap { quadrant in (1...8).map { quadrant * 10 + $0 } }
    }
}
