import DICOMCore
import SegmentKit
import SwiftUI

// Segmentazione per soglia.
//
// # Che cosa promette e che cosa no
//
// Promette di isolare ciò che sta in una finestra di densità, tenere il pezzo più grande e
// mostrarne il confine. Non promette di trovare la mandibola, un dente o il canale: quella è
// segmentazione anatomica, richiede un modello addestrato e qui non c'è. La differenza va
// scritta dove si preme il pulsante, non in fondo a un manuale, perché una soglia chiamata
// «segmenta osso» fa credere di aver ottenuto l'osso — mentre ha ottenuto tutto ciò che è
// abbastanza denso, colonna vertebrale e otturazioni comprese.
//
// # Perché le soglie sono in GV e non in unità Hounsfield
//
// Contratto 4: i valori di una CBCT sono valori grigi, non unità Hounsfield. Le soglie di
// letteratura per l'osso corticale sono in HU e **non si trasferiscono**: variano fra apparecchi,
// fra protocolli e persino fra posizioni nel campo dello stesso apparecchio. I valori
// predefiniti qui sono un punto di partenza da correggere guardando l'istogramma di questo
// volume, non una raccomandazione.

struct SegmentationSheet: View {

    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingLarge) {
            Text("Segmentazione per soglia")
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.textPrimary)

            Text(
                "Isola i voxel compresi in una finestra di densità e ne ricostruisce il confine, "
                + "che compare sulle viste come contorno viola. Non riconosce strutture "
                + "anatomiche: seleziona per densità, quindi una soglia da osso prende anche la "
                + "colonna e le otturazioni."
            )
            .font(Typography.body)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            thresholds
            options

            if let statistics = model.segmentationStatistics {
                Divider().overlay(Palette.separator)
                summary(statistics)
            }

            if let message = model.segmentationMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(Typography.label)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Chiudi") { dismiss() }
                if model.segmentationMesh != nil {
                    Button("Cancella") { model.clearSegmentation() }
                }
                Spacer()
                if model.isSegmenting {
                    ProgressView().controlSize(.small)
                }
                Button("Segmenta") {
                    Task { await model.runSegmentation() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSegmenting || model.volume == nil)
            }
        }
        .padding(Metrics.spacingLarge)
        .frame(width: 560)
        .background(Palette.chrome)
    }

    private var thresholds: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            SectionHeader("FINESTRA DI DENSITÀ (\(unitSymbol))")

            // I preset prima dei numeri: nessuno conosce a memoria la soglia dello smalto, e
            // partire da un valore plausibile e correggerlo è molto più rapido che cercarlo
            // sull'istogramma da zero.
            LabeledControl("Preset") {
                Menu(currentPreset?.name ?? "Personalizzato") {
                    ForEach(ThresholdPreset.all) { preset in
                        Button(preset.name) {
                            model.segmentationLowerGV = preset.lowerGV
                            model.segmentationUpperGV = preset.upperGV
                            // Le vie aeree hanno bisogno del componente più grande più di ogni
                            // altra cosa: senza, prendono l'aria attorno alla testa.
                            if preset.id == "aeree" { model.segmentationKeepsLargest = true }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
            }

            if let caveat = currentPreset?.caveat {
                Text(caveat)
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledControl("Da") {
                TextField("", value: $model.segmentationLowerGV, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }
            LabeledControl("A") {
                TextField("", value: $model.segmentationUpperGV, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
            }

            Text(
                "I valori sono in \(unitSymbol) di questo volume. Le soglie di letteratura sono "
                + "in unità Hounsfield e non valgono qui: guarda l'istogramma nell'ispettore per "
                + "trovare quelle giuste per questa acquisizione."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            SectionHeader("RICOSTRUZIONE")

            Toggle("Tieni solo il pezzo più grande", isOn: $model.segmentationKeepsLargest)
                .font(Typography.body)
                .toggleStyle(.checkbox)

            LabeledControl("Passo") {
                Menu(millimetres(model.segmentationSpacingMM)) {
                    ForEach([0.3, 0.4, 0.6, 0.8, 1.2], id: \.self) { step in
                        Button(millimetres(step)) { model.segmentationSpacingMM = step }
                    }
                }
                .menuStyle(.borderlessButton)
            }

            // Il costo cresce col cubo del passo dimezzato: dirlo qui evita che si scelga 0,3 mm
            // su un campo grande e si concluda che il programma è bloccato.
            Text(
                "Il passo è quello con cui si campiona la superficie, non la risoluzione del "
                + "volume. Dimezzarlo moltiplica per otto il lavoro."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func summary(_ statistics: MaskStatistics) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            SectionHeader("RISULTATO")

            row("Volume", String(format: "%.2f cm³", statistics.volumeMM3 / 1000))
            row("Voxel", "\(statistics.voxelCount)")
            row(
                "Densità media",
                String(
                    format: "%.0f ± %.0f %@", statistics.meanDensity,
                    statistics.standardDeviation, statistics.densityUnitSymbol))
            row(
                "Intervallo",
                String(
                    format: "%.0f … %.0f %@", statistics.minimumDensity,
                    statistics.maximumDensity, statistics.densityUnitSymbol))
            if let mesh = model.segmentationMesh {
                row("Triangoli", "\(mesh.triangles.count)")
            }

            // Il volume è la somma dei voxel selezionati, e la selezione dipende dalla soglia:
            // spostarla di cinquanta GV lo cambia di parecchio. Un numero presentato senza
            // questa avvertenza verrebbe letto come una misura del paziente.
            Text(
                "Il volume conta i voxel dentro la soglia: dipende dalla soglia scelta almeno "
                + "quanto dall'anatomia, e non è una misura del paziente."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Metrics.spacingSmall)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: Metrics.spacing)
            Text(value.replacingOccurrences(of: ".", with: ","))
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textPrimary)
        }
    }

    /// Il preset che corrisponde alla finestra corrente, se ce n'è uno.
    ///
    /// Confrontato sui valori e non ricordato in una variabile: spostando una soglia a mano il
    /// menu deve tornare a dire «Personalizzato», e uno stato separato prima o poi direbbe
    /// «Osso» su una finestra che osso non è più.
    private var currentPreset: ThresholdPreset? {
        ThresholdPreset.all.first {
            abs($0.lowerGV - model.segmentationLowerGV) < 0.5
                && abs($0.upperGV - model.segmentationUpperGV) < 0.5
        }
    }

    private var unitSymbol: String { model.volume?.densityUnit.symbol ?? "GV" }

    private func millimetres(_ value: Double) -> String {
        String(format: "%.1f mm", value).replacingOccurrences(of: ".", with: ",")
    }
}
