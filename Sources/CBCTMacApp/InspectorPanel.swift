import AppKit
import DICOMCore
import ImplantKit
import MeasureKit
import StudyKit
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
                if model.workMode == .review {
                    // In rilettura l'ispettore non è un pannello di comandi: è il piano.
                    ReviewPanel(model: model)
                } else if model.activeTool == .prostheticTooth || model.selectedTooth != nil {
                    prostheticSection
                } else if model.activeTool == .implant || model.activeTool == .nerve
                    || model.selectedImplant != nil
                {
                    implantSection
                    Divider().overlay(Palette.separator)
                    ProstheticVerdict(model: model)
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
                    Divider().overlay(Palette.separator)
                    scrollSection
                }
                if model.workMode != .review {
                    Divider().overlay(Palette.separator)
                    measurementsSection
                }
            }
            .padding(Metrics.spacingLarge)
        }
        .background(Palette.chrome)
    }

    // MARK: Rotella

    @AppStorage(InteractiveMetalView.ScrollPreference.invertedKey)
    private var scrollInverted = false
    @AppStorage(InteractiveMetalView.ScrollPreference.speedKey)
    private var scrollSpeed = 1.0

    /// Come si comporta la rotella. Sta in fondo alla visualizzazione perché è una preferenza,
    /// non un parametro del caso: si imposta una volta e non si tocca più.
    private var scrollSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Toggle("Inverti la direzione della rotella", isOn: $scrollInverted)
                .font(Typography.label)
                .toggleStyle(.checkbox)

            LabeledSlider(
                label: "Velocità",
                value: $scrollSpeed,
                range: 0.25...4,
                format: "%.2f×")

            Text(
                "Un mouse a scatti muove più fette per scatto di un trackpad. Lo zoom con ⌘ non "
                + "si inverte: «avanti» significa ingrandire su ogni programma esistente."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
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

    // MARK: Denti protesici

    private var prostheticSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing + 2) {
            SectionHeader("DENTE PROTESICO")

            Text("Il dente si posa **prima** dell'impianto: la protesi decide dov'è il posto "
                + "giusto, l'impianto la serve.")
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledControl("Numero") {
                Menu("\(model.pendingToothNumber)") {
                    ForEach(Self.fdiQuadrants, id: \.name) { quadrant in
                        Menu(quadrant.name) {
                            ForEach(quadrant.numbers, id: \.self) { number in
                                Button("\(number)") { model.pendingToothNumber = number }
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
            }

            if let tooth = model.selectedTooth {
                // Modificabili, non solo leggibili. Erano tre righe di testo, e la nota sotto
                // diceva «da correggere quando l'anatomia lo chiede» senza offrire un modo di
                // correggerle: un'istruzione a fare una cosa che il pannello non permette.
                LabeledControl("Larghezza") {
                    SteppedValue(
                        label: "", value: tooth.widthMM, step: 0.2, format: "%.1f"
                    ) { newValue in
                        model.updateSelectedTooth { $0.widthMM = max(newValue, 0.5) }
                    }
                }
                LabeledControl("Altezza") {
                    SteppedValue(
                        label: "", value: tooth.heightMM, step: 0.2, format: "%.1f"
                    ) { newValue in
                        model.updateSelectedTooth { $0.heightMM = max(newValue, 0.5) }
                    }
                }
                LabeledControl("Spessore") {
                    SteppedValue(
                        label: "", value: tooth.depthMM, step: 0.2, format: "%.1f"
                    ) { newValue in
                        model.updateSelectedTooth { $0.depthMM = max(newValue, 0.5) }
                    }
                }

                // Le misure sono medie di popolazione, non di questo paziente: dirlo qui, dove
                // si leggono, invece che soltanto nella documentazione.
                Text("Misure medie per il dente \(tooth.toothNumber), da correggere quando "
                    + "l'anatomia lo chiede.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.archCurve.isUsable {
                    Label(
                        "Orientata sulla curva d'arcata.",
                        systemImage: "checkmark.circle")
                        .font(Typography.label)
                        .foregroundStyle(Palette.safe)
                } else {
                    Label(
                        "Senza curva d'arcata la rotazione attorno all'asse è convenzionale: "
                            + "l'ingombro è giusto, il verso no.",
                        systemImage: "exclamationmark.triangle")
                        .font(Typography.label)
                        .foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(role: .destructive) {
                    model.removeSelectedTooth()
                } label: {
                    Label("Elimina dente", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
            } else {
                Text("Scegli il numero e fai clic dove deve stare la superficie masticante.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private static let fdiQuadrants: [(name: String, numbers: [Int])] = [
        ("Superiore destro (1×)", Array(11...18)),
        ("Superiore sinistro (2×)", Array(21...28)),
        ("Inferiore sinistro (3×)", Array(31...38)),
        ("Inferiore destro (4×)", Array(41...48)),
    ]

    /// Lo spazio protesico più stretto, con la soglia che lo rende leggibile.
    ///
    /// Dieci millimetri è la cifra comunemente citata per una protesi avvitata su barra —
    /// struttura, resina e dente — ed è **orientativa**: dipende dal materiale, dal tipo di
    /// protesi e dal caso. Il programma segnala, non decide.
    private func spaceNote(_ millimetresValue: Double, tooth: Int) -> String {
        let value = String(format: "%.1f", millimetresValue)
            .replacingOccurrences(of: ".", with: ",")
        if millimetresValue < 10 {
            return "Spazio protesico più stretto: \(value) mm sul \(tooth). Sotto i dieci "
                + "millimetri circa la protesi si assottiglia: valuta di affondare gli impianti."
        }
        return "Spazio protesico più stretto: \(value) mm sul \(tooth)."
    }

    private static func millimetres(_ value: Double) -> String {
        String(format: "%.1f mm", value).replacingOccurrences(of: ".", with: ",")
    }

    /// Quanto si stringe l'impianto, in millimetri e in gradi per lato.
    private func taperNote(_ model: ImplantModel) -> String {
        let narrowing = model.platformDiameterMM - model.apexDiameterMM
        guard model.lengthMM > 0 else { return "" }
        // Mezza differenza sulla lunghezza: è la pendenza del fianco, cioè l'angolo per lato,
        // che è come la conicità si legge su un catalogo.
        let radians = Foundation.atan((narrowing * 0.5) / model.lengthMM)
        let degrees = radians * 180 / .pi
        if abs(narrowing) < 0.05 { return "Cilindrico." }
        let direction = narrowing > 0 ? "si stringe" : "si allarga"
        // I due numeri si formattano da soli e poi si compongono. Applicare la sostituzione
        // della virgola decimale all'intera frase cambierebbe anche il punto finale — che è
        // punteggiatura, non un separatore decimale.
        let amount = Self.millimetres(abs(narrowing))
        let angle = String(format: "%.1f°", abs(degrees))
            .replacingOccurrences(of: ".", with: ",")
        return "Conicità: \(direction) di \(amount) verso l'apice, \(angle) per lato."
    }

    // MARK: Impianti e nervo

    private var implantSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing + 2) {
            SectionHeader("IMPIANTO")

            if let implant = model.selectedImplant {
                // Tre misure, e ciascuna cambia da sé senza disfare le altre.
                //
                // Prima erano due menu che **ricostruivano il modello da capo**: scegliere una
                // lunghezza rifaceva l'impianto con il diametro corrente e i valori predefiniti
                // per tutto il resto, quindi cancellava in silenzio ogni personalizzazione del
                // profilo. Adesso passano tutte da `resize`, che cambia quel che si chiede e
                // rigenera il profilo dalle tre misure insieme.
                LabeledControl("Testa Ø") {
                    Menu(Self.millimetres(implant.model.platformDiameterMM)) {
                        ForEach(ImplantModel.commonDiameters, id: \.self) { diameter in
                            Button(Self.millimetres(diameter)) {
                                model.updateSelectedImplant {
                                    $0.model.resize(platformDiameterMM: diameter)
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                }

                LabeledControl("Apice Ø") {
                    Menu(Self.millimetres(implant.model.apexDiameterMM)) {
                        ForEach(ImplantModel.commonApexDiameters, id: \.self) { diameter in
                            Button(Self.millimetres(diameter)) {
                                model.updateSelectedImplant {
                                    $0.model.resize(apexDiameterMM: diameter)
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                }

                LabeledControl("Lunghezza") {
                    Menu(Self.millimetres(implant.model.lengthMM)) {
                        ForEach(ImplantModel.commonLengths, id: \.self) { length in
                            Button(Self.millimetres(length)) {
                                model.updateSelectedImplant { $0.model.resize(lengthMM: length) }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                }

                // La conicità è una conseguenza delle due misure, non un quarto parametro: dirla
                // evita di doverla calcolare a mente quando si sceglie fra due impianti.
                Text(taperNote(implant.model))
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

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
            SectionHeader("BARRA PROTESICA")

            if let bar = model.selectedBar {
                LabeledControl("Diametro") {
                    SteppedValue(
                        label: "", value: bar.diameterMM, step: 0.5, format: "%.1f"
                    ) { newValue in
                        model.updateBar(id: bar.id) { $0.diameterMM = max(newValue, 0.5) }
                    }
                }
                LabeledControl("Sopra le teste") {
                    SteppedValue(
                        label: "", value: bar.offsetMM, step: 0.5, format: "%.1f"
                    ) { newValue in
                        model.updateBar(id: bar.id) { $0.offsetMM = newValue }
                    }
                }

                let spaces = model.prostheticSpace(for: bar)
                if let tightest = spaces.first {
                    // Lo spazio **minimo**, non la media: la protesi si rompe dove è più
                    // sottile, e una media che nascondesse un punto da sei millimetri
                    // direbbe che va tutto bene proprio dove non va.
                    Text(spaceNote(tightest.spaceMM, tooth: tightest.tooth.toothNumber))
                        .font(Typography.label)
                        .foregroundStyle(tightest.spaceMM < 10 ? Palette.warning : Palette.safe)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.teeth.isEmpty {
                    Text("Posa i denti protesici per sapere quanto spazio resta sopra la barra.")
                        .font(Typography.label)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(role: .destructive) {
                    model.removeBar(id: bar.id)
                } label: {
                    Label("Elimina barra", systemImage: "trash").frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    model.addProstheticBar()
                } label: {
                    Label("Unisci gli impianti con una barra", systemImage: "link")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.implants.filter(\.isVisible).count < 2)
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

            // I passi fini partono da 150 µm, non da mezzo millimetro. Non è un vezzo: su una
            // cresta stretta due sezioni a un millimetro possono cadere una davanti e una dietro
            // la corticale vestibolare senza mostrarla, e il difetto si scambia per assenza di
            // osso. A 150 µm si vede.
            LabeledControl("Intervallo") {
                Menu(Self.spacingText(model.crossSectionIntervalMM)) {
                    ForEach(AppModel.crossSectionIntervalPresetsMM, id: \.self) { interval in
                        Button(Self.spacingText(interval)) {
                            model.crossSectionIntervalMM = interval
                            model.rebuildCrossSections()
                        }
                    }
                }
                .menuStyle(.borderlessButton)
            }

            // Spessore della singola sezione: c'era nel modello e non aveva un comando. Una
            // trasversale a fetta singola è rumorosa e la corticale si perde nel granulo; qualche
            // decimo di millimetro di media la fa emergere senza sfumare il profilo.
            LabeledControl("Spessore") {
                Menu(
                    model.crossSectionThicknessMM <= 0
                        ? "Fetta singola" : Self.spacingText(model.crossSectionThicknessMM)
                ) {
                    Button("Fetta singola") {
                        model.crossSectionThicknessMM = 0
                        model.rebuildCrossSections()
                    }
                    Divider()
                    ForEach([0.15, 0.3, 0.5, 1.0, 2.0], id: \.self) { value in
                        Button(Self.spacingText(value)) {
                            model.crossSectionThicknessMM = value
                            model.rebuildCrossSections()
                        }
                    }
                }
                .menuStyle(.borderlessButton)
            }

            // Quante sezioni per fila. È la «1×N» delle barre dei visori commerciali: poche e
            // grandi per giudicare una cresta, molte e piccole per scorrere un'arcata intera.
            LabeledControl("Per fila") {
                Menu("\(model.crossSectionBrowser.visibleCount)") {
                    ForEach([1, 3, 5, 7, 10, 14], id: \.self) { count in
                        Button("\(count)") { model.crossSectionBrowser.visibleCount = count }
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

    /// Un passo in millimetri o in micrometri, secondo quale dei due si legge meglio.
    ///
    /// Sotto il millimetro i micrometri evitano lo zero iniziale — «150 µm» invece di «0,15 mm» —
    /// e a colpo d'occhio si distinguono meglio fra loro, che è tutto ciò che serve in un menu di
    /// sei voci.
    static func spacingText(_ value: Double) -> String {
        value < 1
            ? "\(Int((value * 1000).rounded())) µm"
            : String(format: "%.1f mm", value).replacingOccurrences(of: ".", with: ",")
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

                    // La curva sotto la riga della linea selezionata, non in una finestra a
                    // parte: il profilo è il **valore** di quella misura, come i millimetri lo
                    // sono per una distanza, e va letto accanto a ciò che lo produce.
                    // Sotto la riga selezionata: che cosa vale davvero quel numero.
                    if annotation.id == model.selectedAnnotationID,
                        let context = annotation.metadata.acquisition
                    {
                        MeasurementQualityNote(annotation: annotation, context: context)
                            .padding(.leading, Metrics.spacing)
                    }

                    if annotation.id == model.selectedAnnotationID,
                        case .profileLine = annotation,
                        let samples = model.profileSamples[annotation.id], samples.count > 1
                    {
                        ProfileChart(samples: samples, unit: model.densityUnit)
                            .padding(.leading, Metrics.spacing)
                    }
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


// MARK: - Curva del profilo

/// Le densità lette lungo una linea di profilo.
///
/// # Perché una curva e non un numero
///
/// Un profilo risponde a domande che una media non può: dove comincia la corticale, quanto è
/// spessa, se sotto c'è spongiosa o un vuoto. Sono tutte domande sull'**andamento**, e ridurle a
/// un valore le cancella. Per questo la linea di profilo è uno strumento a sé e non una variante
/// del righello.
struct ProfileChart: View {

    let samples: [ProfileSample]
    let unit: DensityUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Canvas { context, size in
                guard samples.count > 1 else { return }
                let values = samples.map(\.value)
                let low = values.min() ?? 0
                let high = values.max() ?? 1
                let span = max(high - low, 1)
                let total = max(samples[samples.count - 1].distanceMM, 1e-6)

                func point(_ sample: ProfileSample) -> CGPoint {
                    CGPoint(
                        x: sample.distanceMM / total * size.width,
                        y: (1 - (sample.value - low) / span) * size.height)
                }

                var path = Path()
                path.move(to: point(samples[0]))
                for sample in samples.dropFirst() { path.addLine(to: point(sample)) }
                context.stroke(
                    path, with: .color(Palette.accent),
                    style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

                // Una riga alla quota zero quando l'intervallo la contiene: su una CBCT lo zero
                // GV è all'incirca l'acqua, ed è il riferimento rispetto a cui si legge se un
                // tratto è osso o tessuto molle.
                if low < 0, high > 0 {
                    let y = (1 - (0 - low) / span) * size.height
                    var axis = Path()
                    axis.move(to: CGPoint(x: 0, y: y))
                    axis.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(
                        axis, with: .color(Palette.textSecondary.opacity(0.4)),
                        style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                }
            }
            .frame(height: 64)
            .background(Palette.chrome, in: .rect(cornerRadius: 4))

            HStack {
                Text(range)
                Spacer()
                Text(
                    String(format: "%.1f mm", samples[samples.count - 1].distanceMM)
                        .replacingOccurrences(of: ".", with: ",")
                )
            }
            .font(Typography.numericSmall)
            .foregroundStyle(Palette.textSecondary)
        }
    }

    private var range: String {
        let values = samples.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        return String(format: "%.0f – %.0f %@", low, high, unit.symbol)
            .replacingOccurrences(of: "-", with: "−")
    }
}


// MARK: - Che cosa vale un numero

/// Incertezza e avvertimenti della misura selezionata.
///
/// # Perché sta sotto la riga e non in un pannello a parte
///
/// Perché è **parte del numero**, non un'informazione accessoria. Un pannello separato si chiude,
/// e allora resta la cifra sola: chi legge `12,5 mm` senza sapere che viene da una proiezione di
/// venti millimetri sta leggendo un limite inferiore credendo di leggere una distanza. Il
/// Contratto 5 dice che nessun numero dichiara più precisione di quanta ne abbia, e nasconderne
/// le condizioni sarebbe lo stesso difetto travestito.
struct MeasurementQualityNote: View {

    let annotation: Annotation
    let context: AcquisitionContext

    private var quality: MeasurementQuality {
        MeasurementUncertainty.quality(ofLengthMM: lengthMM, context: context)
    }

    /// La lunghezza su cui l'eccesso da slab si calcola. Per ciò che non è una lunghezza si usa
    /// zero, e l'avvertimento resta quello generico dello spessore.
    private var lengthMM: Double {
        switch annotation {
        case .distance(let a): return a.lengthMM
        case .profileLine(let a): return a.lengthMM
        case .polyline(let a): return a.lengthMM
        case .freehand(let a): return a.lengthMM
        default: return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Incertezza")
                    .foregroundStyle(Palette.textSecondary)
                Text(uncertaintyText)
                    .foregroundStyle(Palette.textPrimary)
                Text(voxelText)
                    .foregroundStyle(Palette.textSecondary)
            }
            .font(Typography.numericSmall)

            ForEach(Array(quality.caveats.enumerated()), id: \.offset) { _, caveat in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: caveat.invalidatesLength
                        ? "exclamationmark.triangle.fill" : "info.circle")
                        .font(.system(size: 9))
                        .foregroundStyle(
                            caveat.invalidatesLength ? Palette.warning : Palette.textSecondary)
                    Text(caveat.localizedDescription)
                        .font(Typography.label)
                        .foregroundStyle(
                            caveat.invalidatesLength ? Palette.warning : Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var uncertaintyText: String {
        let rounded = MeasurementUncertainty.roundedUncertaintyMM(quality.standardUncertaintyMM)
        let decimals = MeasurementUncertainty.decimals(
            forUncertaintyMM: quality.standardUncertaintyMM)
        return String(format: "± %.\(decimals)f mm", rounded)
            .replacingOccurrences(of: ".", with: ",")
    }

    /// Da dove viene l'incertezza, detto invece che lasciato indovinare.
    private var voxelText: String {
        String(format: "· voxel %.2f mm", context.governingSpacingMM)
            .replacingOccurrences(of: ".", with: ",")
    }
}

// MARK: - Verdetto protesico

/// Dice se l'impianto selezionato serve davvero il dente che gli sta sopra.
///
/// # Perché sta accanto agli allarmi di sicurezza e non in un pannello a parte
///
/// Sono le due domande che si pongono insieme su ogni impianto, e hanno risposte che tirano in
/// direzioni opposte: allontanarsi dal nervo spesso significa inclinare, e inclinare peggiora
/// l'emergenza. Vederle una sotto l'altra è ciò che rende visibile il compromesso; su due
/// pannelli separati si ottimizza l'una rovinando l'altra senza accorgersene.
struct ProstheticVerdict: View {

    @Bindable var model: AppModel

    private var constraint: ProstheticConstraint? {
        model.selectedImplant.flatMap { model.prostheticConstraint(for: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            SectionHeader("VERIFICA PROTESICA")

            if let constraint {
                HStack(spacing: Metrics.spacing) {
                    Circle()
                        .fill(color(for: constraint.severity))
                        .frame(width: 8, height: 8)
                    Text(constraint.severity.localizedName)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                }

                Text(constraint.summary)
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !constraint.emergesWithinCrown {
                    Text("L'asse emerge fuori dal perimetro della corona: nessun moncone "
                        + "angolato recupera questo, va spostato l'impianto.")
                        .font(Typography.label)
                        .foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    model.alignSelectedImplantToTooth()
                } label: {
                    Label("Allinea l'asse al dente", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                        .frame(maxWidth: .infinity)
                }
                .help("Ruota l'impianto fino a renderlo parallelo al dente, tenendo ferma la "
                    + "piattaforma. Ricontrolla la distanza dal nervo dopo averlo fatto.")
            } else if model.teeth.isEmpty {
                Text("Nessun dente posato. Senza una sagoma protesica il programma non può "
                    + "dire se l'impianto emerge dove serve — e quella è la verifica che "
                    + "decide se il piano è realizzabile.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Nessun dente abbastanza vicino a questo impianto.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func color(for severity: ConstraintSeverity) -> Color {
        switch severity {
        case .acceptable: return Palette.safe
        case .caution: return Palette.caution
        case .unacceptable: return Palette.danger
        }
    }
}
