import AppKit
import DICOMCore
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
                visualizationSection
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
                    ForEach(WindowLevel.presets, id: \.name) { preset in
                        Button(preset.name) { model.windowLevel = preset.value }
                    }
                    Divider()
                    Button("Automatico dai dati") {
                        if let volume = model.volume {
                            model.windowLevel = WindowLevel.automatic(from: volume)
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
        for preset in WindowLevel.presets where preset.value == model.windowLevel {
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
