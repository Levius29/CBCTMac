import DICOMCore
import MeshKit
import SegmentKit
import SwiftUI

// Il pannello della separazione dei tessuti.
//
// # Che cosa promette, e che cosa no
//
// Promette il modello di un dente e quello dell'osso senza i denti dentro, in un file che una
// stampante accetta. Non promette di trovare i denti da solo, ed è scritto qui perché sia chiaro
// guardando: i marcatori li mette chi guarda, uno per oggetto. Il riconoscimento automatico su
// una CBCT con otturazioni metalliche sbaglia in modi che non si vedono nel risultato, e un
// modello sbagliato in silenzio è peggio di nessun modello.
//
// # Le tre cose che il pannello dice e prima non diceva
//
// **Che l'osso si marca in più punti.** Il motore lo accetta da sempre; l'interfaccia lo
// impediva, perché il tipo del marcatore era implicito nell'ordine. Adesso è un comando.
//
// **Che la separazione si può confinare.** Dove radice e osso si toccano alla stessa densità non
// c'è nel dato nessun confine da trovare, e senza un limite esterno il dente si prende la
// mandibola. Il riquadro di lettura è quel limite.
//
// **Se il solido è chiuso.** Prima si scopriva dallo slicer, che rifiuta il file senza dire
// perché. Adesso si legge qui, prima di salvare.
struct TissueSeparationPanel: View {

    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            SectionHeader("SEPARA I TESSUTI")

            Text(
                // Niente asterischi di enfasi: `Text` interpreta il markdown solo quando
                // riceve una `LocalizedStringKey`, cioè una stringa **letterale**. Qui i due
                // rami sono concatenati con `+`, quindi il tipo è `String` e gli asterischi si
                // vedrebbero tali e quali. Erano lì da prima, e si vedevano.
                model.tissueSeeds.isEmpty
                    ? "Prendi il marcatore e fai clic dentro l'osso, di fianco alla radice. "
                        + "Poi uno dentro ogni dente da separare."
                    : "Un marcatore per dente, al centro della corona. Poi «Separa»."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            marker
            seedList
            confinement
            densityAndSurface
            finishing
            actions
            notes
        }
    }

    /// Soglia e passo di campionamento.
    ///
    /// In una proprietà a sé come le altre sezioni, e non per necessità: dall'SDK di macOS 14
    /// `ViewBuilder` ha un `buildBlock` variadico e il vecchio limite dei dieci figli non c'è
    /// più. È per leggere: un corpo di quaranta righe non si tiene a mente, e questo pannello
    /// ha sei sezioni che si guardano una alla volta.
    private var densityAndSurface: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Divider().overlay(Palette.separator)
            SectionHeader("DENSITÀ E SUPERFICIE")
            LabeledSlider(
                label: "Soglia minima", value: $model.tissueLowerGV,
                range: 200...2500, format: "%.0f GV")
            LabeledSlider(
                label: "Passo superficie", value: $model.tissueSpacingMM,
                range: 0.2...1.5, format: "%.2f mm")
        }
    }

    private var actions: some View {
        HStack(spacing: Metrics.spacingSmall) {
            Button(model.isSeparatingTissues ? "Separazione…" : "Separa") {
                Task { await model.separateTissues() }
            }
            .disabled(
                model.isSeparatingTissues || model.tissueSeeds.isEmpty || model.volume == nil)
            Button("Azzera") { model.clearTissueSeeds() }
                .disabled(model.tissueSeeds.isEmpty)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if let message = model.tissueMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(Typography.label)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Detto una volta, dove si guarda il risultato: quel che gli artefatti hanno
            // cancellato non torna. Su una corona metallica la dentina attorno è bruciata, e lì
            // non c'è dato da segmentare — il modello avrà un buco, e non è un difetto del
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

    /// Che cosa marca il prossimo clic, e il comando per prenderlo in mano.
    private var marker: some View {
        HStack(spacing: Metrics.spacingSmall) {
            Button(
                model.activeTool == .tissueSeed ? "Marcatore in mano" : "Prendi il marcatore"
            ) {
                model.activeTool = .tissueSeed
            }
            .disabled(model.volume == nil || model.activeTool == .tissueSeed)

            Menu(markerTitle) {
                Button("Osso") { model.pendingTissueKind = .bone }
                Menu("Dente") {
                    ForEach(fdiNumbers, id: \.self) { number in
                        Button("\(number)") {
                            model.pendingTissueKind = .tooth
                            model.pendingTissueToothNumber = number
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var markerTitle: String {
        switch model.pendingTissueKind {
        case .bone: return "Osso"
        case .tooth: return "Dente \(model.pendingTissueToothNumber)"
        }
    }

    @ViewBuilder private var seedList: some View {
        if !model.tissueSeeds.isEmpty {
            ForEach(model.tissueSeeds) { seed in
                HStack(spacing: Metrics.spacingSmall) {
                    Circle()
                        .fill(Color(hexString: seed.colorHex) ?? Palette.textPrimary)
                        .frame(width: 9, height: 9)
                    Text(seed.name).font(Typography.label)
                    Spacer(minLength: 0)
                    if let mesh = model.tissueMeshes[seed.label] {
                        integrityBadge(for: seed.label)
                        Text("\(mesh.triangles.count) △")
                            .font(Typography.numericSmall)
                            .foregroundStyle(Palette.textSecondary)
                        Menu {
                            Button("STL…") {
                                model.exportTissue(label: seed.label, format: .stlBinary)
                            }
                            Button("OBJ…") {
                                model.exportTissue(label: seed.label, format: .obj)
                            }
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Esporta \(seed.name) come STL o OBJ.")
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
    }

    /// Chiuso o aperto, con il numero che lo dice.
    ///
    /// Un pallino e non una parola: la riga è già piena, e il colore lo si legge senza fermarsi.
    /// Il numero dei bordi aperti sta nel suggerimento, dove serve solo a chi vuole capire
    /// quanto è grave.
    @ViewBuilder private func integrityBadge(for label: SegmentLabel) -> some View {
        if let report = model.tissueIntegrity[label] {
            Image(systemName: report.isWatertight ? "checkmark.seal" : "exclamationmark.triangle")
                .font(Typography.label)
                .foregroundStyle(report.isWatertight ? Palette.safe : Palette.warning)
                .help(
                    report.isWatertight
                        ? "Solido chiuso: lo slicer lo accetta."
                        : "Non chiuso: \(report.openEdgeCount) bordi aperti, "
                            + "\(report.nonManifoldEdgeCount) spigoli non-manifold. "
                            + "Lo slicer potrebbe rifiutarlo."
                )
        }
    }

    private var confinement: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            Toggle("Limita al riquadro di lettura", isOn: $model.tissueConfinesToClipBox)
                .font(Typography.body)
                .toggleStyle(.checkbox)

            // Il testo cambia con lo stato perché la stessa casella spunta significa due cose
            // diverse a seconda che il riquadro sia acceso o no, e la differenza è tutta la
            // funzione: spenta, la crescita non ha limiti.
            if model.tissueConfinesToClipBox && model.activeClipBox == nil {
                HStack(spacing: Metrics.spacingSmall) {
                    Text("Il riquadro è spento: la crescita non ha limiti.")
                        .font(Typography.label)
                        .foregroundStyle(Palette.warning)
                    Button("Accendilo") { model.beginClipping() }
                        .buttonStyle(.link)
                        .font(Typography.label)
                }
                .fixedSize(horizontal: false, vertical: true)
            } else if model.tissueConfinesToClipBox {
                Text(
                    "Fuori dal riquadro non si assegna niente. Stringilo attorno al dente "
                    + "trascinandone i lati sulle viste: è ciò che impedisce alla radice di "
                    + "tirarsi dietro la mandibola, ed è anche ciò che rende l'operazione "
                    + "immediata."
                )
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var finishing: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            SectionHeader("FINITURA PER LA STAMPA")

            LabeledSlider(
                label: "Lisciatura", value: $model.tissueSmoothingPasses,
                range: 0...20, format: "%.0f passate")
            LabeledSlider(
                label: "Tetto △", value: $model.tissueTriangleBudgetThousands,
                range: 0...500, format: "%.0f mila")

            Text(
                "La lisciatura toglie i gradini dei voxel senza assottigliare il modello. Il "
                + "tetto a zero lascia la superficie com'è: alzalo se lo slicer fatica ad "
                + "aprire il file."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// I numeri FDI dei denti permanenti.
    private var fdiNumbers: [Int] {
        (1...4).flatMap { quadrant in (1...8).map { quadrant * 10 + $0 } }
    }
}
