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
                        windowLevel: model.windowLevel)

                    CropBoxOverlay(
                        plan: Binding(
                            get: { self.plan ?? plan },
                            set: { self.plan = $0 }),
                        anatomical: anatomical,
                        geometry: geometry,
                        viewPlane: previewPlane(anatomical, geometry: geometry))
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
    private func previewPlane(_ anatomical: AnatomicalPlane, geometry: VolumeGeometry) -> MPRPlane {
        MPRPlane.fitted(plane: anatomical, geometry: geometry)
    }

    // MARK: Comandi

    @ViewBuilder
    private func controls(plan: ReformatPlan, geometry: VolumeGeometry) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Metrics.spacingLarge, verticalSpacing: 6) {
            GridRow {
                Text("Dimensione voxel").foregroundStyle(Palette.textSecondary)
                Picker(
                    "",
                    selection: Binding(
                        get: { plan.spacingMM },
                        set: { self.plan?.spacingMM = $0 })
                ) {
                    ForEach(VolumeResampler.spacingPresetsMM, id: \.self) { value in
                        Text(spacingText(value)).tag(value)
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

    private func apply() {
        guard let plan, let volume = model.volume else { return }
        isWorking = true
        failure = nil
        do {
            let resampled = try VolumeResampler.resampled(
                volume,
                request: ResampleRequest(spacingMM: plan.spacingMM, regionMM: plan.regionMM))
            model.adopt(volume: resampled, named: plan.name)
            dismiss()
        } catch {
            // L'errore si mostra qui e non si chiude la finestra: chiudere farebbe perdere il
            // riquadro appena regolato, e con esso il lavoro di regolarlo.
            failure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        isWorking = false
    }
}
