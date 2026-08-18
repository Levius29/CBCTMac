import DICOMCore
import MeasureKit
import StudyKit
import SwiftUI
import VolumeKit

// La colonna di sinistra.
//
// Quattro pannelli richiudibili nell'ordine in cui si usano scendendo: che cosa si guarda
// (Regolazioni), con che cosa si lavora (Strumenti), che cosa si è fatto (Oggetti), che cosa se ne
// porta via (Esporta). Sotto, l'albero dello studio con i volumi.
//
// L'ordine non è casuale ed è lo stesso dei visori a cui somiglia: si scende dalla scelta più
// generale alla più specifica, e le due che si toccano di continuo — strumenti e oggetti — stanno
// in mezzo, dove il puntatore arriva senza percorrere la colonna.

struct LeftColumn: View {

    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                SidePanel(
                    title: "Regolazioni", systemImage: "slider.horizontal.3",
                    storageKey: "adjustments",
                    badge: model.transferPresetName
                ) {
                    AdjustmentsPanel(model: model)
                }

                SidePanel(
                    title: "Strumenti", systemImage: "wrench.and.screwdriver",
                    storageKey: "tools",
                    badge: model.activeTool.localizedName
                ) {
                    ToolPalette(model: model)
                }

                SidePanel(
                    title: "Oggetti", systemImage: "list.bullet",
                    storageKey: "objects",
                    badge: "\(model.registry.objects.count)"
                ) {
                    ObjectListPanel(model: model)
                }

                SidePanel(
                    title: "Esporta", systemImage: "square.and.arrow.up",
                    storageKey: "export", initiallyExpanded: false
                ) {
                    ExportPanel(model: model)
                }

                SidePanel(
                    title: "Studio", systemImage: "cube",
                    storageKey: "study", initiallyExpanded: false,
                    badge: "\(model.library.entries.count)"
                ) {
                    StudyTree(model: model)
                }

                // La versione, in fondo e in piccolo. Serve quando si segnala un
                // comportamento: «non funziona» senza un numero di versione costringe a
                // indovinare quale build si stia guardando.
                HStack {
                    Spacer()
                    Text("CBCTMac \(AppModel.appVersion)")
                        .font(Typography.label)
                        .foregroundStyle(Palette.textSecondary.opacity(0.6))
                    Spacer()
                }
                .padding(.vertical, Metrics.spacing)

                if !model.loadIssues.isEmpty {
                    VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                        ForEach(model.loadIssues, id: \.self) { issue in
                            Label(issue, systemImage: "exclamationmark.triangle.fill")
                                .font(Typography.label)
                                .foregroundStyle(Palette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(Metrics.spacing + 2)
                }
            }
        }
        .background(Palette.chrome)
    }
}

// MARK: - Regolazioni

struct AdjustmentsPanel: View {

    @Bindable var model: AppModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // I preset come riquadri cliccabili e non come voci di menu: sono scelte visive, e
            // una striscia di colore che mostra come renderà è più informativa del suo nome.
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(TransferFunction.presets, id: \.name) { preset in
                    PresetTile(
                        name: preset.name,
                        function: preset.value,
                        isActive: model.transferPresetName == preset.name
                    ) {
                        model.applyTransferPreset(named: preset.name)
                    }
                }
            }

            Divider().overlay(Palette.separator)

            LabeledControl("Risoluzione") {
                Picker("", selection: $model.mprResolution) {
                    ForEach(MPRResolution.allCases) { resolution in
                        Text(resolution.localizedName).tag(resolution)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            VStack(alignment: .leading, spacing: 5) {
                Button {
                    model.isShowingReorient = true
                } label: {
                    Label("Raddrizza sul piano occlusale…", systemImage: "level")
                        .font(Typography.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(model.volume == nil)

                Button {
                    model.isShowingReformat = true
                } label: {
                    Label("Ritaglia e ricampiona…", systemImage: "crop")
                        .font(Typography.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(model.volume == nil)

                Button {
                    model.resetAllViews()
                } label: {
                    Label("Rimetti tutte le viste a posto", systemImage: "arrow.counterclockwise")
                        .font(Typography.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.textSecondary)
        }
    }
}

/// Riquadro di un preset di rendering, con la sua striscia di colore.
private struct PresetTile: View {

    let name: String
    let function: TransferFunction
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                // La striscia è la transfer function stessa, campionata: mostra i colori e dove
                // l'opacità sale. È l'anteprima più onesta possibile a questa dimensione — un
                // rendering in miniatura costerebbe un raycast per riquadro a ogni ridisegno.
                LinearGradient(
                    stops: gradientStops, startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 18)
                .clipShape(.rect(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isActive ? Palette.accent : Palette.separator, lineWidth: 1)
                )

                Text(name)
                    .font(Typography.label)
                    .lineLimit(1)
                    .foregroundStyle(isActive ? Palette.accent : Palette.textSecondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(name)
    }

    private var gradientStops: [Gradient.Stop] {
        // Si campiona l'intervallo che i punti di controllo coprono davvero, non un intervallo
        // fisso: i preset vanno da «vie aeree» a «denti», e una scala comune schiaccerebbe i
        // primi in una striscia piatta.
        let densities = function.stops.map(\.density)
        let lower = densities.min() ?? 0
        let upper = densities.max() ?? 1
        let span = max(upper - lower, 1)

        let count = 12
        return (0..<count).map { index in
            let t = Double(index) / Double(count - 1)
            let sample = function.sample(at: lower + t * span)
            return Gradient.Stop(
                color: Color(
                    .sRGB, red: sample.color.red, green: sample.color.green,
                    blue: sample.color.blue,
                    opacity: max(sample.opacity, 0.12)),
                location: t)
        }
    }
}

// MARK: - Esporta

struct ExportPanel: View {

    @Bindable var model: AppModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ExportButton(icon: "camera", help: "Istantanea del riquadro attivo") {
                model.requestSnapshot()
            }
            ExportButton(icon: "doc.on.clipboard", help: "Copia le misure negli appunti") {
                model.copyMeasurementsToClipboard()
            }
            ExportButton(icon: "tablecells", help: "Esporta le misure in CSV") {
                model.exportMeasurementsCSV()
            }
            ExportButton(icon: "square.and.arrow.down", help: "Salva il piano") {
                model.savePlan()
            }
        }
    }
}

private struct ExportButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .frame(width: 30, height: 28)
                .background(Palette.chromeElevated, in: .rect(cornerRadius: 5))
                .foregroundStyle(Palette.textPrimary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Albero dello studio

struct StudyTree: View {

    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.library.entries.isEmpty {
                Text("Nessuno studio aperto.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
            }
            ForEach(model.library.entries) { entry in
                let isSelected = entry.id == model.library.selectedID
                HStack(spacing: 6) {
                    Image(systemName: entry.provenance.parentID == nil ? "cube" : "crop")
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? Palette.accent : Palette.textSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name)
                            .font(Typography.body)
                            .foregroundStyle(
                                isSelected ? Palette.textPrimary : Palette.textSecondary)
                            .lineLimit(1)
                        Text(entry.summary)
                            .font(Typography.numericSmall)
                            .foregroundStyle(Palette.textSecondary.opacity(0.75))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                // Il rientro segue la profondità nella catena: un ritaglio del ritaglio sta due
                // gradini dentro, e si vede da dove viene.
                .padding(.leading, CGFloat(model.library.depth(of: entry.id)) * 12)
                .padding(.vertical, 3)
                .padding(.horizontal, 5)
                .background(
                    isSelected ? Palette.accent.opacity(0.14) : .clear,
                    in: .rect(cornerRadius: 4))
                .contentShape(.rect)
                .onTapGesture { model.selectVolume(entry.id) }
                .contextMenu {
                    Button("Mostra questo volume") { model.selectVolume(entry.id) }
                    Button("Rimuovi", role: .destructive) { model.removeVolume(entry.id) }
                        .disabled(entry.provenance.parentID == nil)
                }
                .help(model.library.provenanceDescription(of: entry.id))
            }
        }
    }
}
