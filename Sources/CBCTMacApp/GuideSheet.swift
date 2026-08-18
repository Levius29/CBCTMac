import DICOMCore
import GuideKit
import SwiftUI

// Costruzione della dima chirurgica.
//
// # Il pezzo con cui il piano esce dal programma
//
// Fino a qui tutto resta a schermo. La dima è l'unica cosa che diventa un oggetto fisico, e da
// quel momento gli errori non si correggono più con un ⌘Z: si stampano.
//
// Per questo la finestra non si limita a costruire. Dichiara su che cosa sta costruendo — quanto
// vale la registrazione della scansione, che è il termine che limita tutto il resto — e mostra le
// verifiche prima di lasciare esportare. Una dima che il programma sa non essere stampabile non
// deve poter uscire per sbaglio.

struct GuideSheet: View {

    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var footprintRadiusMM = 12.0
    @State private var sleeveInnerMM = 5.0
    @State private var sleeveOuterMM = 7.0
    @State private var sleeveHeightMM = 5.0
    @State private var offsetToPlatformMM = 9.0

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingLarge) {
            Text("Costruisci la dima")
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.textPrimary)

            prerequisites
            parameters

            if let result = model.guideResult {
                report(result)
            }

            HStack {
                Button("Chiudi") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if let result = model.guideResult {
                    Button("Esporta STL…") { model.exportGuide() }
                        .disabled(!result.validation.isPrintable)
                        .help(
                            result.validation.isPrintable
                                ? "Salva la dima per la stampante."
                                : "Le verifiche non sono superate: esportarla darebbe un pezzo "
                                    + "che la stampante non sa interpretare.")
                }
                Button(model.isBuildingGuide ? "Costruzione…" : "Costruisci") { build() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.scan == nil || model.isBuildingGuide)
            }
        }
        .padding(Metrics.spacingLarge)
        .frame(width: 600)
    }

    // MARK: Su che cosa si costruisce

    @ViewBuilder
    private var prerequisites: some View {
        VStack(alignment: .leading, spacing: 5) {
            requirement(
                "Scansione intraorale importata",
                satisfied: model.scan != nil,
                missing: "La dima appoggia sui denti: senza scansione non c'è su cosa appoggiare.")

            requirement(
                registrationLabel,
                satisfied: model.scanRegistration?.quality == .good,
                missing:
                    "Il disallineamento della scansione è disallineamento della dima, e la dima "
                    + "non lo recupera. Sotto tre decimi di millimetro non è più il termine che "
                    + "limita l'accuratezza.")

            requirement(
                "\(model.implants.filter(\.isVisible).count) impianti da guidare",
                satisfied: !model.implants.filter(\.isVisible).isEmpty,
                missing: "Senza impianti pianificati la dima non ha boccole da collocare.")
        }
    }

    private var registrationLabel: String {
        guard let outcome = model.scanRegistration else { return "Scansione registrata" }
        return String(format: "Registrazione: %@ (%.2f mm)",
                      outcome.quality.localizedName, outcome.surfaceRMSMM)
            .replacingOccurrences(of: ".", with: ",")
    }

    @ViewBuilder
    private func requirement(_ title: String, satisfied: Bool, missing: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: satisfied ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(satisfied ? Palette.safe : Palette.warning)
                Text(title)
                    .font(Typography.label)
                    .foregroundStyle(Palette.textPrimary)
            }
            if !satisfied {
                Text(missing)
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.leading, 23)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Parametri

    @ViewBuilder
    private var parameters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("APPOGGIO E BOCCOLE")
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.textSecondary)

            HStack(spacing: Metrics.spacingLarge) {
                SteppedValue(
                    label: "Appoggio", value: footprintRadiusMM, step: 2, format: "%.0f"
                ) { footprintRadiusMM = min(max($0, 6), 30) }

                SteppedValue(
                    label: "Ø interno", value: sleeveInnerMM, step: 0.1, format: "%.1f"
                ) { sleeveInnerMM = min(max($0, 2), 8) }

                SteppedValue(
                    label: "Ø esterno", value: sleeveOuterMM, step: 0.1, format: "%.1f"
                ) { sleeveOuterMM = min(max($0, sleeveInnerMM + 0.5), 12) }
            }

            HStack(spacing: Metrics.spacingLarge) {
                SteppedValue(
                    label: "Altezza boccola", value: sleeveHeightMM, step: 0.5, format: "%.1f"
                ) { sleeveHeightMM = min(max($0, 2), 12) }

                SteppedValue(
                    label: "Offset", value: offsetToPlatformMM, step: 0.5, format: "%.1f"
                ) { offsetToPlatformMM = min(max($0, 4), 16) }
            }

            Text(
                "L'offset è la distanza fra la base della boccola e la piattaforma implantare, e "
                + "va preso dalle specifiche del kit chirurgico che userai: è quello a stabilire "
                + "la profondità di fresatura, e sbagliarlo sposta l'impianto di quanto sbagli."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Le verifiche

    @ViewBuilder
    private func report(_ result: GuideResult) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("VERIFICHE")
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.textSecondary)

            HStack(spacing: Metrics.spacingLarge) {
                check("Chiusa", result.validation.isWatertight)
                check("Orientata", result.validation.hasConsistentOrientation)
                Text(
                    String(format: "%.1f cm³", result.validation.volumeMM3 / 1000)
                        .replacingOccurrences(of: ".", with: ",")
                )
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textSecondary)
                if let thickness = result.validation.minimumWallThicknessMM {
                    Text(
                        String(format: "parete minima %.1f mm", thickness)
                            .replacingOccurrences(of: ".", with: ",")
                    )
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.textSecondary)
                }
            }

            ForEach(result.validation.warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.warning)
                    Text(warning)
                        .font(Typography.label)
                        .foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func check(_ title: String, _ passed: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(passed ? Palette.safe : Palette.danger)
            Text(title)
        }
        .font(Typography.numericSmall)
        .foregroundStyle(Palette.textPrimary)
    }

    private func build() {
        var configuration = GuideConfiguration()
        configuration.footprintRadiusMM = footprintRadiusMM
        Task {
            await model.buildGuide(
                footprintRadiusMM: footprintRadiusMM,
                sleeveInnerDiameterMM: sleeveInnerMM,
                sleeveOuterDiameterMM: sleeveOuterMM,
                sleeveHeightMM: sleeveHeightMM,
                offsetToPlatformMM: offsetToPlatformMM,
                configuration: configuration)
        }
    }
}
