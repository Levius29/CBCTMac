import DICOMCore
import SegmentKit
import SwiftUI
import VolumeKit

// Ritaglio e ricampionamento del volume.
//
// Il motore c'era già — `SegmentKit` ritaglia e ricampiona, con i suoi test — e non c'era un solo
// pulsante che lo raggiungesse. Avere un motore senza interfaccia è peggio che non averlo: la
// funzione sembra mancante, e nessuno va a cercarla nel codice.
//
// A che serve. Una CBCT a pieno FOV occupa centinaia di megabyte e la maggior parte è cranio che
// non interessa. Ritagliare la regione su cui si lavora e portarla a 150 µm significa lavorare a
// piena risoluzione su ciò che conta, con un volume che sta comodamente in memoria — ed è la
// ragione per cui ogni visore commerciale ha questo strumento.

struct ReformatSheet: View {

    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var plan: ReformatPlan?
    @State private var isWorking = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingLarge) {
            Text("Ritaglia e ricampiona")
                .font(Typography.sectionHeader)

            if let geometry = model.volume?.geometry, let plan {
                previews(plan: plan, geometry: geometry)
                controls(plan: plan, geometry: geometry)
            } else {
                Text("Apri prima uno studio.")
                    .font(Typography.body)
                    .foregroundStyle(Palette.textSecondary)
            }

            if let failure {
                Text(failure)
                    .font(Typography.label)
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Tutto il volume") { resetPlan() }
                    .disabled(model.volume == nil)
                // «Ripristina» rimette il riquadro come si è aperta la finestra, senza chiuderla:
                // dopo aver trascinato quattro lati e essersi accorti di aver sbagliato regione,
                // l'alternativa è annullare e riaprire, che perde anche il passo scelto.
                Button("Ripristina") { resetPlan() }
                    .disabled(plan == nil)
                Spacer()
                Button("Annulla") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isWorking ? "Elaborazione…" : "Applica") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil || isWorking || !isPlanUsable)
            }
        }
        .padding(Metrics.spacingLarge)
        .frame(minWidth: 640, minHeight: 460)
        .onAppear { resetPlan() }
    }

    // MARK: Anteprime

    /// Dimensione del drawable di ciascuna vista, in pixel: è lo spazio in cui arrivano i clic.
    @State private var pixelSizes: [AnatomicalPlane: CGSize] = [:]
    /// Lato afferrato e vista in cui lo si è afferrato.
    @State private var grabbedEdge: CropBoxEdge?
    @State private var grabbedView: AnatomicalPlane?

    /// Quanto vicino a un lato bisogna premere perché lo si afferri, in **frazione del lato
    /// maggiore** della vista.
    ///
    /// Una frazione e non una misura in punti: gli eventi arrivano in pixel del drawable, i punti
    /// di schermo sono un'altra unità, e il fattore fra le due dipende dal display **e** dalla
    /// risoluzione di rendering scelta. Una frazione non ha bisogno di sapere nulla di tutto ciò
    /// e si comporta uguale a ogni dimensione della finestra.
    private let grabFraction = 0.025

    /// Decide alla pressione quale lato si è afferrato, prima che il primo movimento lo sposti.
    ///
    /// Alla pressione e non al primo spostamento: deciderlo dopo significherebbe che il lato
    /// scelto dipende da dove il mouse è già arrivato, e un movimento rapido ne afferrerebbe uno
    /// diverso da quello premuto.
    private func grabCropBox(
        at point: CGPoint, anatomical: AnatomicalPlane, geometry: VolumeGeometry
    ) {
        grabbedEdge = nil
        grabbedView = nil
        guard let plan, let size = pixelSizes[anatomical], size.width > 1, size.height > 1 else {
            return
        }

        let frame = CropBoxOverlay.frame(of: previewPlane(anatomical, geometry: geometry), size: size)
        let rect = CropBoxGeometry.rect(
            of: plan.regionMM, in: frame,
            width: Double(size.width), height: Double(size.height))

        let slop = Double(max(size.width, size.height)) * grabFraction

        grabbedEdge = CropBoxGeometry.edge(
            nearX: Double(point.x), y: Double(point.y), of: rect, slop: slop)
        grabbedView = grabbedEdge == nil ? nil : anatomical
    }

    private func dragCropBox(
        to point: CGPoint, anatomical: AnatomicalPlane, geometry: VolumeGeometry
    ) {
        guard let edge = grabbedEdge, grabbedView == anatomical, var current = plan,
            let size = pixelSizes[anatomical], size.width > 1, size.height > 1
        else { return }

        let frame = CropBoxOverlay.frame(of: previewPlane(anatomical, geometry: geometry), size: size)
        let valueMM = CropBoxGeometry.millimetres(
            atX: Double(point.x), y: Double(point.y), for: edge, in: frame,
            width: Double(size.width), height: Double(size.height))

        current.moveFace(
            CropBoxGeometry.face(for: edge, in: frame), toMM: valueMM, within: geometry)
        plan = current
    }

    /// Le tre viste ortogonali con il riquadro sovrapposto.
    ///
    /// I tre riquadri descrivono **un solo parallelepipedo**: muovendo un lato in una vista, le
    /// altre due si aggiornano perché leggono lo stesso `regionMM`. È il motivo per cui il piano
    /// sta nello stato e non tre rettangoli indipendenti — tre rettangoli separati possono
    /// discordare, e discorderebbero al primo trascinamento.
    @ViewBuilder
    private func previews(plan: ReformatPlan, geometry: VolumeGeometry) -> some View {
        HStack(spacing: Metrics.viewportGap) {
            ForEach(AnatomicalPlane.allCases, id: \.self) { anatomical in
                ZStack {
                    MPRViewportView(
                        plane: previewPlane(anatomical, geometry: geometry),
                        volumeTexture: model.volumeTexture,
                        renderer: model.mprRenderer,
                        windowLevel: model.windowLevel,
                        onScroll: { steps in
                            // Scorrere le fette **mentre** si sceglie il riquadro: senza, si
                            // decideva il ritaglio guardando una fetta di mezzo fissa, cioè
                            // controllando su un piano solo se il riquadro comprende ciò che
                            // deve comprendere.
                            scrollPreview(anatomical, by: steps, geometry: geometry)
                        },
                        // Queste anteprime scelgono un riquadro, non esplorano il volume: sono
                        // inquadrate sull'intero volume di proposito, perché il riquadro va visto
                        // rispetto a tutto ciò che c'è. Da qui le omissioni, che sono scelte.
                        //
                        // gesto-non-richiesto: onZoom — l'inquadratura completa è il punto
                        // gesto-non-richiesto: onPan — idem
                        // gesto-non-richiesto: onRotate — il ritaglio è allineato agli assi
                        // gesto-non-richiesto: onClick — nulla da selezionare
                        // gesto-non-richiesto: onDoubleClick — nessun riquadro da ingrandire
                        // gesto-non-richiesto: onHover — la lettura di densità sta nel visore
                        // gesto-non-richiesto: onCancel — non c'è misura in corso da annullare
                        onDrag: { point, _ in
                            dragCropBox(to: point, anatomical: anatomical, geometry: geometry)
                        },
                        onWindowLevelDrag: { model.adjustWindowLevel(byDelta: $0) },
                        onDragBegan: { point in
                            grabCropBox(at: point, anatomical: anatomical, geometry: geometry)
                        },
                        onDragEnded: { grabbedEdge = nil; grabbedView = nil },
                        onDrawableSize: { pixelSizes[anatomical] = $0 })

                    CropBoxOverlay(
                        plan: self.plan ?? plan,
                        viewPlane: previewPlane(anatomical, geometry: geometry),
                        grabbedEdge: grabbedView == anatomical ? grabbedEdge : nil)
                }
                .frame(minHeight: 220)
                .clipShape(.rect(cornerRadius: Metrics.cornerRadius))
                .overlay(alignment: .topLeading) {
                    Text(anatomical.localizedName)
                        .font(Typography.viewportLabel)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(Metrics.spacingSmall)
                }
            }
        }
    }

    /// Piano d'anteprima: sempre l'intero volume, centrato.
    ///
    /// Deliberatamente non segue il mirino né lo zoom dei riquadri principali. Qui si sceglie una
    /// regione **rispetto al volume intero**, e mostrarne una porzione già ingrandita renderebbe
    /// impossibile capire quanto si sta tagliando.
    /// Quanto la fetta di anteprima è scostata dal centro, per ciascuna vista.
    @State private var previewOffsetMM: [AnatomicalPlane: Double] = [:]

    private func previewPlane(_ anatomical: AnatomicalPlane, geometry: VolumeGeometry) -> MPRPlane {
        var plane = MPRPlane.fitted(plane: anatomical, geometry: geometry)
        if let offset = previewOffsetMM[anatomical], offset != 0 {
            plane.centerMM = plane.centerMM + plane.normalMM * offset
        }
        return plane
    }

    /// Sposta la fetta di anteprima lungo la propria normale, restando dentro il volume.
    ///
    /// Il limite non è prudenza: uscendo dal volume il riquadro mostrerebbe nero, e chi sta
    /// scegliendo un ritaglio penserebbe di aver sbagliato il riquadro invece della fetta.
    private func scrollPreview(
        _ anatomical: AnatomicalPlane, by steps: Double, geometry: VolumeGeometry
    ) {
        let spacing = geometry.spacingMM
        let step = max(min(spacing.x, min(spacing.y, spacing.z)), 0.05)
        let size = geometry.physicalSizeMM
        let halfExtent = max(size.x, max(size.y, size.z)) / 2

        let current = previewOffsetMM[anatomical] ?? 0
        previewOffsetMM[anatomical] = min(max(current + steps * step, -halfExtent), halfExtent)
    }

    // MARK: Comandi

    @ViewBuilder
    private func controls(plan: ReformatPlan, geometry: VolumeGeometry) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Metrics.spacingLarge, verticalSpacing: 6) {
            GridRow {
                Text("Dimensione voxel").foregroundStyle(Palette.textSecondary)
                // I passi **di questo volume**, non i nove fissi.
                //
                // Il menu offriva i preset e basta, e il piano nasceva col passo nativo — che da
                // un DICOM vero arriva come 0,2000000029802322 e non è nessuno dei nove. Il
                // menu quindi non mostrava alcuna scelta, e qualunque voce si toccasse portava
                // a un passo diverso dall'originale: la strada del ritaglio senza perdita, che
                // esiste e funziona, non era raggiungibile da nessun gesto. Si ritagliava
                // sempre ricampionando, ed è precisamente l'immagine più molle che si vedeva.
                Picker(
                    "",
                    selection: Binding(
                        get: { plan.spacingMM },
                        set: { self.plan?.spacingMM = $0 })
                ) {
                    ForEach(VolumeResampler.spacingOptionsMM(for: geometry), id: \.self) {
                        value in
                        Text(spacingLabel(value, geometry: geometry)).tag(value)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            GridRow {
                Text("Nome").foregroundStyle(Palette.textSecondary)
                TextField(
                    "Volume riformattato",
                    text: Binding(
                        get: { plan.name },
                        set: { self.plan?.name = $0 })
                )
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
            }
            GridRow {
                Text("Risultato").foregroundStyle(Palette.textSecondary)
                // La stima **prima** di procedere, non un errore dopo un'attesa: un ritaglio
                // generoso a 100 µm chiede facilmente diversi gigabyte, e scoprirlo dopo trenta
                // secondi di elaborazione è la peggiore delle risposte.
                Text(estimateText(plan: plan))
                    .font(Typography.numericSmall)
                    .foregroundStyle(isPlanUsable ? Palette.textPrimary : Palette.warning)
            }
        }

        let problems = plan.validate(against: geometry)
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(problems, id: \.self) { problem in
                    Text("• \(problem)")
                        .font(Typography.label)
                        .foregroundStyle(Palette.warning)
                }
            }
        }
    }

    private var isPlanUsable: Bool {
        guard let plan, let geometry = model.volume?.geometry else { return false }
        return plan.validate(against: geometry).isEmpty
            && plan.estimatedBytes() < 3_000_000_000
    }

    private func spacingText(_ value: Double) -> String {
        value < 1
            ? "\(Int((value * 1000).rounded())) µm"
            : String(format: "%.2f mm", value).replacingOccurrences(of: ".", with: ",")
    }

    /// Il passo, e se è quello del volume anche il perché sceglierlo.
    ///
    /// Detto, perché arrotondato non si distingue: il passo nativo di 0,2000000029802322 e il
    /// preset 0,2 si scrivono tutti e due «200 µm», e sono due operazioni diverse — una copia i
    /// voxel, l'altra li interpola. Senza etichetta la differenza è invisibile proprio nel punto
    /// in cui si decide.
    private func spacingLabel(_ value: Double, geometry: VolumeGeometry) -> String {
        VolumeResampler.isLosslessCrop(spacingMM: value, in: geometry)
            ? "\(spacingText(value)) — originale, senza perdita"
            : spacingText(value)
    }

    private func estimateText(plan: ReformatPlan) -> String {
        let voxels = plan.estimatedVoxelCount()
        let megabytes = Double(plan.estimatedBytes()) / 1_048_576
        let size = plan.regionMM.sizeMM
        return String(
            format: "%.0f × %.0f × %.0f mm · %@ voxel · %.0f MB",
            size.x, size.y, size.z, formatted(voxels), megabytes)
    }

    private func formatted(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "."
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // MARK: Azioni

    private func resetPlan() {
        guard let geometry = model.volume?.geometry else {
            plan = nil
            return
        }
        let spacing = min(geometry.spacingMM.x, min(geometry.spacingMM.y, geometry.spacingMM.z))
        plan = ReformatPlan.full(for: geometry, spacingMM: spacing)
        failure = nil
    }

    /// Fuori dal thread dell'interfaccia: vedi `ArtifactSheet.apply`.
    private func apply() {
        guard let plan, let volume = model.volume else { return }
        isWorking = true
        failure = nil

        let request = ResampleRequest(spacingMM: plan.spacingMM, regionMM: plan.regionMM)
        // La stessa domanda che si pone il ricampionatore, posta a lui. Qui stava scritta
        // `plan.spacingMM < smallestSpacing`, che è vera solo per i passi **più fini**
        // dell'originale: ogni ingrossamento — cioè ogni ricampionamento che sfoca davvero —
        // finiva nella catena di provenienza come «Ritaglio».
        let isResample = !VolumeResampler.isLosslessCrop(
            spacingMM: plan.spacingMM, in: volume.geometry)
        let name = plan.name

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try VolumeResampler.resampled(volume, request: request) }
            }.value

            isWorking = false
            switch outcome {
            case .success(let resampled):
                // L'operazione dichiarata distingue un ritaglio da un ricampionamento nella
                // catena di provenienza: sono due cose diverse e la relazione deve poterlo dire.
                model.adopt(
                    volume: resampled, named: name,
                    operation: isResample ? "Ricampionamento" : "Ritaglio")
                dismiss()
            case .failure(let error):
                // L'errore si mostra qui e non si chiude la finestra: chiudere farebbe perdere il
                // riquadro appena regolato, e con esso il lavoro di regolarlo.
                failure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }
    }
}
