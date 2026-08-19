import DICOMCore
import MeshKit
import SwiftUI

// Registrazione della scansione intraorale sulla CBCT.
//
// # Il flusso, e perché è in due tempi
//
// L'ICP converge verso il minimo locale **più vicino**: se le due superfici partono lontane
// converge sul dente sbagliato, e lo fa con uno scarto piccolo e convincente. Serve un
// allineamento iniziale che venga da fuori dell'algoritmo, e l'unico che lo sa dare è chi guarda:
// tre o più punti riconoscibili in entrambe le superfici.
//
// # Che cosa questa finestra **non** fa ancora, e va detto
//
// Non mostra la scansione in tre dimensioni, quindi i punti dal suo lato non si possono indicare
// col mouse: si scrivono in millimetri, leggendoli dal programma con cui la scansione è stata
// aperta. È scomodo e onesto — l'alternativa sarebbe un allineamento automatico che sembra
// funzionare e sbaglia dente, che è il modo peggiore di sbagliare.
//
// Il punto sulla CBCT invece si prende dal mirino, che è già posizionabile con precisione.

struct ScanRegistrationSheet: View {

    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var scanPoint = Vec3(0, 0, 0)
    @State private var regionHalfSizeMM = 20.0
    @State private var thresholdGV = 1200.0

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingLarge) {
            Text("Registra la scansione")
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.textPrimary)

            Text(
                "Indica almeno tre coppie di punti che riconosci in entrambe le superfici — "
                + "cuspidi, non superfici piatte. Poi la registrazione affina da sé, e ti dice "
                + "di quanto le due superfici distano dopo."
            )
            .font(Typography.body)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            landmarkEntry
            landmarkList
            regionControls

            if let outcome = model.scanRegistration {
                outcomeReport(outcome)
            }

            HStack {
                Button("Chiudi") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                // Importata la scansione sbagliata, o allineata male e da rifare da capo:
                // l'azione c'era nel modello e nessun comando la raggiungeva, quindi l'unico
                // modo di liberarsene era chiudere il caso.
                Button(role: .destructive) {
                    model.removeScan()
                    dismiss()
                } label: {
                    Label("Togli la scansione", systemImage: "trash")
                }
                .disabled(model.scan == nil)

                Spacer()
                Button("Registra") { register() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.scanLandmarks.count < 3 || model.volume == nil)
            }
        }
        .padding(Metrics.spacingLarge)
        .frame(width: 600)
    }

    // MARK: Le coppie

    @ViewBuilder
    private var landmarkEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NUOVA COPPIA")
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.textSecondary)

            HStack(spacing: Metrics.spacing) {
                Text("Sulla scansione")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                coordinateField("X", value: $scanPoint.x)
                coordinateField("Y", value: $scanPoint.y)
                coordinateField("Z", value: $scanPoint.z)
            }

            HStack(spacing: Metrics.spacing) {
                Text("Sulla CBCT")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                Text(positionText(model.crosshairMM))
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.textPrimary)
                Text("— dov'è il mirino adesso")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Button("Aggiungi coppia") {
                    model.scanLandmarks.append(
                        LandmarkPair(scanMM: scanPoint, volumeMM: model.crosshairMM))
                }
            }
        }
    }

    @ViewBuilder
    private var landmarkList: some View {
        if model.scanLandmarks.isEmpty {
            Text("Nessuna coppia. Ne servono almeno tre, e non allineate.")
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.scanLandmarks.enumerated()), id: \.element.id) { index, pair in
                    HStack(spacing: Metrics.spacing) {
                        Text("\(index + 1)")
                            .font(Typography.numericSmall)
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: 16, alignment: .trailing)
                        Text(positionText(pair.scanMM))
                        Text("→")
                            .foregroundStyle(Palette.textSecondary)
                        Text(positionText(pair.volumeMM))
                        Spacer()
                        Button {
                            model.scanLandmarks.removeAll { $0.id == pair.id }
                        } label: {
                            Image(systemName: "trash").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.textSecondary)
                    }
                    .font(Typography.numericSmall)
                }
            }
        }
    }

    // MARK: La zona di riferimento

    @ViewBuilder
    private var regionControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ZONA DI RIFERIMENTO SULLA CBCT")
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.textSecondary)

            Text(
                "Attorno al mirino, larga il doppio del raggio indicato. Sceglila su denti sani e "
                + "senza metallo: attorno a una corona la superficie estratta non è quella del "
                + "dente, è quella di un artefatto, e la registrazione risulterebbe precisa "
                + "rispetto a qualcosa che non esiste."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Metrics.spacingLarge) {
                SteppedValue(
                    label: "Raggio", value: regionHalfSizeMM, step: 5, format: "%.0f"
                ) { regionHalfSizeMM = min(max($0, 5), 60) }

                SteppedValue(
                    label: "Soglia GV", value: thresholdGV, step: 100, format: "%.0f"
                ) { thresholdGV = min(max($0, 200), 3000) }
            }
        }
    }

    // MARK: L'esito

    @ViewBuilder
    private func outcomeReport(_ outcome: ScanRegistrationOutcome) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Metrics.spacing) {
                Image(systemName: symbol(for: outcome.quality))
                    .foregroundStyle(colour(for: outcome.quality))
                Text(outcome.quality.localizedName)
                    .foregroundStyle(colour(for: outcome.quality))
                Text(
                    String(
                        format: "scarto %.2f mm · massimo %.2f mm · %d punti",
                        outcome.surfaceRMSMM, outcome.surfaceMaxMM, outcome.surfacePointCount
                    ).replacingOccurrences(of: ".", with: ",")
                )
                .foregroundStyle(Palette.textSecondary)
            }
            .font(Typography.numericSmall)

            Text(outcome.quality.explanation)
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func symbol(for quality: RegistrationQuality) -> String {
        switch quality {
        case .good: return "checkmark.seal.fill"
        case .acceptable: return "exclamationmark.triangle.fill"
        case .poor: return "xmark.octagon.fill"
        }
    }

    private func colour(for quality: RegistrationQuality) -> Color {
        switch quality {
        case .good: return Palette.safe
        case .acceptable: return Palette.warning
        case .poor: return Palette.danger
        }
    }

    // MARK: Azioni

    private func register() {
        let centre = model.crosshairMM
        let half = Vec3(regionHalfSizeMM, regionHalfSizeMM, regionHalfSizeMM)
        model.registerScan(
            inRegionMM: (min: centre - half, max: centre + half), thresholdGV: thresholdGV)
    }

    private func coordinateField(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textSecondary)
            TextField("", value: value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .font(Typography.numericSmall)
        }
    }

    private func positionText(_ point: Vec3) -> String {
        String(format: "%.1f  %.1f  %.1f", point.x, point.y, point.z)
            .replacingOccurrences(of: ".", with: ",")
    }
}
