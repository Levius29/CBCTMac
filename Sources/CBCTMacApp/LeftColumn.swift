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

                // In cima, prima di ogni comando: è il controllo che si fa per primo, e che
                // vale più di qualunque regolazione se la risposta è «non è questo paziente».
                if model.hasOpenStudy {
                    SidePanel(
                        title: "Esame", systemImage: "person.text.rectangle",
                        storageKey: "esame"
                    ) {
                        ExamMetadataPanel(model: model)
                    }
                }

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

                // Accanto agli strumenti, perché comincia con uno strumento in mano: si
                // marcano gli oggetti cliccando, e i risultati si guardano qui.
                SidePanel(
                    title: "Tessuti", systemImage: "square.3.layers.3d",
                    storageKey: "tissues",
                    badge: model.tissueSeeds.isEmpty
                        ? nil : "\(model.tissueSeeds.count)"
                ) {
                    TissueSeparationPanel(model: model)
                }

                SidePanel(
                    title: "Oggetti", systemImage: "list.bullet",
                    storageKey: "objects",
                    badge: "\(model.registry.objects.count)"
                ) {
                    ObjectListPanel(model: model)
                }

                if model.hasOpenStudy {
                    SidePanel(
                        title: "Istantanee", systemImage: "photo.on.rectangle",
                        storageKey: "istantanee",
                        initiallyExpanded: false,
                        badge: model.snapshots.isEmpty ? nil : "\(model.snapshots.count)"
                    ) {
                        SnapshotGallery(model: model)
                    }
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
                    Text(AppModel.buildIdentity)
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
            // # Due filtri diversi, e la ragione per cui adesso sono etichettati
            //
            // I preset di rendering agiscono **solo sul riquadro 3D**; le viste 2D sono governate
            // dalla finestra di densità, che è un'altra cosa. Messi in un pannello chiamato
            // «Regolazioni» senza dirlo, sembravano un filtro generale: si sceglieva «Denti»,
            // le tre viste ortogonali non cambiavano, e la conclusione ragionevole era che il
            // comando fosse rotto. Non lo era — agiva altrove.
            //
            // La correzione non è spiegarlo in un aiuto: è mettere qui **entrambi** i filtri,
            // ciascuno sotto il proprio titolo, così si vede subito quale governa cosa.

            Text("VISTE 2D · FINESTRA DI DENSITÀ")
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.textSecondary)

            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(AppModel.densityWindowPresets, id: \.name) { preset in
                    WindowTile(
                        name: preset.name,
                        isActive: model.windowLevel == preset.value
                    ) {
                        model.windowLevel = preset.value
                    }
                }
            }

            HStack(spacing: 10) {
                Text(
                    String(
                        format: "W %.0f · L %.0f", model.windowLevel.width, model.windowLevel.level)
                )
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textSecondary)
                Spacer()
                Button("Automatica") { model.resetWindowLevel() }
                    .buttonStyle(.plain)
                    .font(Typography.label)
                    .foregroundStyle(Palette.accent)
                    .disabled(model.volume == nil)
            }

            Divider().overlay(Palette.separator)

            Text("RIQUADRO 3D · RESA DEI TESSUTI")
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.textSecondary)

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

            TiltControls(model: model)

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
                    model.isShowingArtifact = true
                } label: {
                    Label("Riduci le strie da metallo…", systemImage: "sparkles")
                        .font(Typography.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(model.volume == nil)

                Button {
                    model.activeTool = .occlusalPlane
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

                // Il riquadro di lettura, accanto al ritaglio vero e distinto da esso: quello
                // produce un volume nuovo, questo cambia solo che cosa si vede. Il testo lo dice,
                // perché è l'unica differenza che conta e non si vede dalle icone.
                Button {
                    model.toggleClipping()
                } label: {
                    Label(
                        model.clipBox.isActive
                            ? "Togli il riquadro di lettura"
                            : "Guarda solo una porzione…",
                        systemImage: model.clipBox.isActive
                            ? "rectangle.dashed" : "rectangle.dashed.badge.record")
                        .font(Typography.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(model.volume == nil)
                .help(
                    "Limita la vista a un riquadro trascinabile. Non modifica l'esame: "
                    + "l'archivio conserva il volume intero.")

                if model.clipBox.isActive {
                    Button {
                        model.resetClipBox()
                    } label: {
                        Label("Riquadro a tutto il volume", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(Typography.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help("Riapre il riquadro su tutto, senza spegnerlo.")
                }

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

/// Riquadro di un preset di finestra di densità.
///
/// Senza gradiente, a differenza dei preset di rendering: una finestra non ha colori, ha un
/// intervallo. Mostrare una striscia grigia suggerirebbe una somiglianza con l'altro pannello che
/// non c'è, e le due cose vanno tenute distinte proprio perché si erano confuse.
private struct WindowTile: View {

    let name: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(Typography.label)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    isActive ? Palette.accent.opacity(0.22) : Palette.chromeElevated,
                    in: .rect(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isActive ? Palette.accent : .clear, lineWidth: 1))
                .foregroundStyle(isActive ? Palette.accent : Palette.textSecondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(name)
    }
}

// MARK: - Inclinazione del taglio

/// Inclinare il taglio senza trascinare.
///
/// # Perché un pulsante accanto a un gesto che già c'è
///
/// L'inclinazione si fa afferrando una maniglia del mirino, ed è il modo giusto quando si cerca
/// un angolo guardando l'anatomia. Non è il modo giusto in altri due casi, ed entrambi capitano:
///
/// - quando serve un angolo **preciso e ripetibile** — cinque gradi, poi altri cinque — che
///   trascinando non si ottiene se non per tentativi;
/// - quando la maniglia **non c'è**, perché ingranditi su un molare il mirino è spesso fuori dal
///   riquadro e non c'è niente da afferrare.
///
/// # Perché serve anche il ritorno a zero
///
/// Perché l'obliquità si accumula senza che nulla la dichiari. Dopo dieci ritocchi da tre gradi
/// non si sa più di quanto si è storti rispetto agli assi della macchina, e l'unico modo di
/// tornare indietro era rifare l'inquadratura da capo — che perde anche zoom e panoramica.
struct TiltControls: View {

    @Bindable var model: AppModel

    /// Cinque gradi per pressione: abbastanza da vedere il cambiamento, abbastanza poco da
    /// arrivare al punto giusto in due o tre colpi.
    private let stepDegrees = 5.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("INCLINAZIONE DEL TAGLIO")
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.textSecondary)

            Text(targetNote)
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 5) {
                stepButton("rotate.left", degrees: -stepDegrees, help: "Inclina di 5° a sinistra")
                stepButton("rotate.right", degrees: stepDegrees, help: "Inclina di 5° a destra")

                Divider().frame(height: 18).overlay(Palette.separator)

                spinButton("arrow.counterclockwise", degrees: -stepDegrees, help: "Ruota l'immagine di 5°")
                spinButton("arrow.clockwise", degrees: stepDegrees, help: "Ruota l'immagine di 5°")

                Spacer(minLength: 0)

                Button {
                    model.resetAllViews()
                } label: {
                    Text("Azzera")
                        .font(Typography.label)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
                .help("Riporta i piani agli assi della macchina")
            }
            .disabled(model.volume == nil || model.focusedSlot.anatomicalPlane == nil)
        }
    }

    /// Su che cosa agiscono i pulsanti, oppure perché adesso non agiscono su niente.
    ///
    /// La seconda metà mancava: con il 3D a fuoco i pulsanti si spegnevano e nessuno diceva
    /// perché, e uno strumento che non risponde senza spiegazione sembra un difetto del
    /// programma. Che il riquadro a fuoco sia a schermo non serve più verificarlo qui: lo
    /// garantisce `WorkspaceSession`.
    private var targetNote: String {
        guard model.focusedSlot.anatomicalPlane != nil else {
            return "Il riquadro 3D non ha un taglio da inclinare: fai clic su una vista 2D."
        }
        return "Agisce sul riquadro attivo: \(model.focusedSlot.localizedName.lowercased())."
    }

    /// Inclina il **taglio**: ruota i due piani perpendicolari a quello mostrato.
    private func stepButton(_ icon: String, degrees: Double, help: String) -> some View {
        iconButton(icon, help: help) {
            model.tiltPlanes(perpendicularTo: model.focusedSlot, byRadians: degrees * .pi / 180)
        }
    }

    /// Gira l'**immagine** nel suo piano, senza cambiare fetta. È l'altra rotazione, e tenerle
    /// separate conta: la prima cambia *cosa* si taglia, la seconda *come lo si guarda*.
    private func spinButton(_ icon: String, degrees: Double, help: String) -> some View {
        iconButton(icon, help: help) {
            model.rotate(slot: model.focusedSlot, byRadians: degrees * .pi / 180)
        }
    }

    private func iconButton(
        _ icon: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 28, height: 24)
                .background(Palette.chromeElevated, in: .rect(cornerRadius: 4))
                .foregroundStyle(Palette.textPrimary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
