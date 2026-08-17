import AppKit
import DICOMCore
import ImplantKit
import MeasureKit
import SwiftUI
import UniformTypeIdentifiers
import VolumeKit

// Ispettore.
//
// Due sezioni, come nei mockup: i controlli di visualizzazione in alto e l'elenco delle misure
// sotto. Ogni valore di densità porta l'unità corretta — GV, mai HU: vedi il Contratto 4 in
// docs/architecture.md.

struct InspectorPanel: View {

    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.spacingLarge) {
                // I controlli seguono il riquadro attivo: finestra e livello non hanno senso
                // sul 3D, dove conta la transfer function, e viceversa. Mostrarli entrambi
                // sempre riempirebbe l'ispettore di comandi inerti.
                // Con uno strumento implantare attivo, o con un impianto selezionato, i
                // controlli che servono sono quelli, non finestra e livello.
                if model.activeTool == .implant || model.activeTool == .nerve
                    || model.selectedImplant != nil
                {
                    implantSection
                    Divider().overlay(Palette.separator)
                    SafetyPanel(
                        report: model.selectedImplantID.flatMap { model.safetyReports[$0] },
                        implant: model.selectedImplant)
                } else if model.layout == .panoramic {
                    visualizationSection
                    Divider().overlay(Palette.separator)
                    archSection
                } else if model.focusedSlot == .volume3D {
                    renderingSection
                    Divider().overlay(Palette.separator)
                    orientationSection
                } else {
                    visualizationSection
                }
                Divider().overlay(Palette.separator)
                measurementsSection
            }
            .padding(Metrics.spacingLarge)
        }
        .background(Palette.chrome)
    }

    // MARK: Visualizzazione

    private var visualizationSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing + 2) {
            SectionHeader("VISUALIZZAZIONE")

            LabeledSlider(
                label: "Finestra",
                value: $model.windowLevel.width,
                range: 1...8000,
                format: "%.0f")

            LabeledSlider(
                label: "Livello",
                value: $model.windowLevel.level,
                range: -1200...4000,
                format: "%.0f")

            LabeledControl("Preset") {
                Menu(presetName) {
                    ForEach(DensityWindow.presets, id: \.name) { preset in
                        Button(preset.name) { model.windowLevel = preset.value }
                    }
                    Divider()
                    Button("Automatico dai dati") {
                        if let volume = model.volume {
                            model.windowLevel = DensityWindow.automatic(from: volume)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
            }

            LabeledControl("Spessore") {
                Menu(slabLabel) {
                    ForEach(slabOptions, id: \.self) { thickness in
                        Button(slabLabel(for: thickness)) { model.slabThicknessMM = thickness }
                    }
                }
                .menuStyle(.borderlessButton)
            }

            LabeledControl("Proiezione") {
                Menu(model.projection.localizedName) {
                    ForEach(SlabProjection.allCases, id: \.self) { projection in
                        Button(projection.localizedName) { model.projection = projection }
                    }
                }
                .menuStyle(.borderlessButton)
                // Con una slice singola la proiezione non ha nulla da combinare: disabilitare
                // dice all'utente che il controllo dipende dallo spessore, invece di lasciarlo
                // sperimentare senza vedere cambiamenti.
                .disabled(model.slabThicknessMM <= 0)
            }
        }
    }

    private var presetName: String {
        for preset in DensityWindow.presets where preset.value == model.windowLevel {
            return preset.name
        }
        return "Personalizzato"
    }

    private var slabOptions: [Double] { [0, 0.5, 1, 2, 3, 5, 10, 20] }

    private var slabLabel: String { slabLabel(for: model.slabThicknessMM) }

    private func slabLabel(for thickness: Double) -> String {
        thickness <= 0
            ? "Slice singola"
            : String(format: "%.1f mm", thickness).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: Impianti e nervo

    private var implantSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing + 2) {
            SectionHeader("IMPIANTO")

            if let implant = model.selectedImplant {
                LabeledControl("Diametro") {
                    Menu(
                        String(format: "%.1f mm", implant.model.diameterMM)
                            .replacingOccurrences(of: ".", with: ",")
                    ) {
                        ForEach(ImplantModel.commonDiameters, id: \.self) { diameter in
                            Button(
                                String(format: "%.1f mm", diameter)
                                    .replacingOccurrences(of: ".", with: ",")
                            ) {
                                model.updateSelectedImplant { placement in
                                    placement.model = ImplantModel(
                                        manufacturer: placement.model.manufacturer,
                                        line: placement.model.line,
                                        diameterMM: diameter,
                                        lengthMM: placement.model.lengthMM)
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                }

                LabeledControl("Lunghezza") {
                    Menu(
                        String(format: "%.0f mm", implant.model.lengthMM)
                    ) {
                        ForEach(ImplantModel.commonLengths, id: \.self) { length in
                            Button(String(format: "%.1f mm", length)) {
                                model.updateSelectedImplant { placement in
                                    placement.model = ImplantModel(
                                        manufacturer: placement.model.manufacturer,
                                        line: placement.model.line,
                                        diameterMM: placement.model.diameterMM,
                                        lengthMM: length)
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                }

                HStack {
                    Text("Etichetta")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary)
                        .frame(width: 78, alignment: .leading)
                    Text(implant.label)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                }

                Button(role: .destructive) {
                    model.removeSelectedImplant()
                } label: {
                    Label("Elimina impianto", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            } else {
                Text("Scegli lo strumento Impianto dalla toolbar e fai clic sulla cresta per "
                    + "collocarne uno.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Palette.separator)
            SectionHeader("CANALE ALVEOLARE")

            if model.nerveCanals.isEmpty {
                Text("Nessun canale tracciato. Senza, gli allarmi di prossimità non possono "
                    + "essere calcolati.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.nerveCanals) { canal in
                    HStack(spacing: Metrics.spacing) {
                        Circle()
                            .fill(Color(hexString: canal.colorHex) ?? Palette.danger)
                            .frame(width: 9, height: 9)
                        Text(canal.side.localizedName)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textPrimary)
                        Spacer()
                        Text("\(canal.nodes.count) punti")
                            .font(Typography.numericSmall)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }

            if model.tracingNerveID != nil {
                Button {
                    model.finishTracingNerve()
                } label: {
                    Label("Termina tracciamento", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }

            Text(
                "Soglie: critico sotto \(formatted(model.safetyThresholds.dangerMM)), "
                    + "attenzione sotto \(formatted(model.safetyThresholds.cautionMM)). "
                    + "Sono valori impostabili, non prescrizioni."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary.opacity(0.8))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func formatted(_ millimetres: Double) -> String {
        String(format: "%.1f mm", millimetres).replacingOccurrences(of: ".", with: ",")
    }

    // MARK: Arcata, panorex e sezioni

    private var archSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing + 2) {
            SectionHeader("PANOREX")

            LabeledSlider(
                label: "Spessore", value: $model.panoramicSlabThicknessMM,
                range: 0...40, format: "%.0f")

            LabeledSlider(
                label: "Altezza", value: $model.panoramicHeightMM,
                range: 30...120, format: "%.0f")

            LabeledControl("Proiezione") {
                Menu(model.panoramicProjection.localizedName) {
                    ForEach(SlabProjection.allCases, id: \.self) { projection in
                        Button(projection.localizedName) { model.panoramicProjection = projection }
                    }
                }
                .menuStyle(.borderlessButton)
            }

            Text(
                "Uno spessore sotto i 10 mm mostra una fetta sola e i denti fuori dalla curva "
                    + "spariscono; sopra i 30 tutto si sovrappone."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Palette.separator)
            SectionHeader("SEZIONI TRASVERSALI")

            LabeledControl("Intervallo") {
                Menu(
                    String(format: "%.1f mm", model.crossSectionIntervalMM)
                        .replacingOccurrences(of: ".", with: ",")
                ) {
                    ForEach([0.5, 1.0, 1.5, 2.0, 3.0, 5.0], id: \.self) { interval in
                        Button(
                            String(format: "%.1f mm", interval)
                                .replacingOccurrences(of: ".", with: ",")
                        ) {
                            model.crossSectionIntervalMM = interval
                            model.rebuildCrossSections()
                        }
                    }
                }
                .menuStyle(.borderlessButton)
            }

            LabeledSlider(
                label: "Larghezza", value: $model.crossSectionWidthMM,
                range: 10...60, format: "%.0f")

            LabeledSlider(
                label: "Altezza", value: $model.crossSectionHeightMM,
                range: 20...80, format: "%.0f")

            HStack {
                Text("Sezioni")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Text("\(model.crossSections.count)")
                    .font(Typography.numeric)
                    .foregroundStyle(Palette.textSecondary)
            }

            Button {
                model.rebuildCrossSections()
            } label: {
                Label("Rigenera sezioni", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Rendering 3D

    private var renderingSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing + 2) {
            SectionHeader("RENDERING 3D")

            LabeledControl("Preset") {
                Menu(model.transferPresetName) {
                    ForEach(TransferFunction.presets, id: \.name) { preset in
                        Button(preset.name) { model.applyTransferPreset(named: preset.name) }
                    }
                }
                .menuStyle(.borderlessButton)
            }

            LabeledControl("Qualità") {
                Menu(model.renderQuality.localizedName) {
                    ForEach(RenderQuality.allCases, id: \.self) { quality in
                        Button(quality.localizedName) { model.renderQuality = quality }
                    }
                }
                .menuStyle(.borderlessButton)
            }

            LabeledSlider(
                label: "Illuminazione", value: $model.lighting.diffuse,
                range: 0...1.5, format: "%.2f")
            LabeledSlider(
                label: "Ambiente", value: $model.lighting.ambient,
                range: 0...1, format: "%.2f")
            LabeledSlider(
                label: "Opacità", value: $model.transferFunction.opacityScale,
                range: 0...3, format: "%.2f")
        }
    }

    private var orientationSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            SectionHeader("ORIENTAMENTO")
            HStack(spacing: Metrics.spacingSmall) {
                orientationButton("Anteriore", "person.crop.rectangle") {
                    model.camera = model.camera.facingAnterior()
                }
                orientationButton("Laterale", "person.crop.circle") {
                    model.camera = model.camera.facingLateral()
                }
                orientationButton("Superiore", "circle.dashed") {
                    model.camera = model.camera.facingSuperior()
                }
            }
            Button {
                if let geometry = model.volume?.geometry {
                    model.camera = VolumeCamera.fitted(to: geometry)
                }
            } label: {
                Label("Adatta alla finestra", systemImage: "arrow.up.left.and.arrow.down.right")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func orientationButton(
        _ title: String, _ symbol: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: Metrics.spacingSmall) {
                Image(systemName: symbol).font(.system(size: 16))
                Text(title).font(Typography.label)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metrics.spacing)
            .background(Palette.chromeElevated, in: .rect(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.textPrimary)
    }

    // MARK: Misure

    private var measurementsSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            SectionHeader("MISURE")

            if model.annotations.isEmpty {
                Text("Nessuna misura. Scegli uno strumento dalla toolbar e fai clic su un riquadro.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.annotations) { annotation in
                    MeasurementRow(
                        annotation: annotation,
                        statistics: model.roiStatistics[annotation.id],
                        isSelected: annotation.id == model.selectedAnnotationID
                    )
                    .contentShape(.rect)
                    .onTapGesture { model.selectedAnnotationID = annotation.id }
                }

                Button {
                    exportCSV()
                } label: {
                    Label("Esporta CSV", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .padding(.top, Metrics.spacingSmall)
            }
        }
    }

    private func exportCSV() {
        let document = model.makePlanDocument()
        let csv = document.measurementsCSV(unit: model.densityUnit)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "misure.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Componenti

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(Typography.sectionHeader)
            .foregroundStyle(Palette.textSecondary)
    }
}

struct LabeledControl<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 78, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

struct LabeledSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            Text(label)
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 78, alignment: .leading)

            Text(String(format: format, value).replacingOccurrences(of: "-", with: "−"))
                .font(Typography.numeric)
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 52, alignment: .trailing)
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(Palette.chromeElevated, in: .rect(cornerRadius: 4))

            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }
}

struct MeasurementRow: View {

    let annotation: Annotation
    let statistics: ROIStatistics?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            Circle()
                .fill(Color(hexString: annotation.metadata.colorHex) ?? Palette.accent)
                .frame(width: 8, height: 8)

            Image(systemName: annotation.systemImageName)
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 16)

            Text(displayValue)
                .font(Typography.numeric)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.spacing)
        .padding(.vertical, 7)
        .background(
            isSelected ? Palette.accent.opacity(0.18) : Palette.chromeElevated,
            in: .rect(cornerRadius: 5)
        )
        .help(helpText)
    }

    /// Per una ROI conta la densità, non l'area: è il numero che si va a cercare.
    private var displayValue: String {
        if let statistics { return statistics.summary }
        return annotation.formattedValue
    }

    private var helpText: String {
        guard let statistics else { return annotation.kindName }
        var lines = [annotation.kindName]
        for row in statistics.detailRows {
            lines.append("\(row.label): \(row.value)")
        }
        lines.append("")
        lines.append(statistics.unit.explanation)
        return lines.joined(separator: "\n")
    }
}
