import DICOMCore
import MeasureKit
import SwiftUI

// Verifica di accuratezza.
//
// # Perché un programma di misura deve poter essere messo alla prova dall'utente
//
// Perché la fiducia in un numero non si chiede, si guadagna. Tutta la catena — matrice DICOM,
// orientamento, piano di taglio, conversione clic-millimetri — può sbagliare in silenzio: un asse
// invertito o una spaziatura letta dal tag sbagliato producono immagini plausibili e misure
// sbagliate del dieci per cento, e nessun test di unità lo intercetta perché ogni pezzo è
// corretto rispetto alla propria specifica.
//
// Sul fantoccio sintetico la verifica prova la **composizione** della catena. Su un fantoccio
// acquisito davvero — un oggetto di geometria nota messo nell'apparecchio — la stessa procedura
// diventa il controllo di qualità della macchina, ed è il motivo per cui l'interfaccia è la
// stessa: cambia il volume, non il metodo.

struct VerificationSheet: View {

    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var results: [VerificationResult] = []
    @State private var hasRun = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingLarge) {
            Text("Verifica di accuratezza")
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.textPrimary)

            Text(
                "Misura sul volume aperto le grandezze note del fantoccio e le confronta con i "
                + "valori attesi. La tolleranza è due volte l'incertezza dichiarata per questo "
                + "voxel: dentro quella soglia la differenza non è distinguibile dal "
                + "campionamento, fuori c'è un difetto nella catena di coordinate."
            )
            .font(Typography.body)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if !model.isPhantomOpen {
                Label(
                    "Il volume aperto non è il fantoccio di riferimento. La verifica vale solo "
                        + "su un volume di geometria nota.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(Typography.label)
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
            }

            if hasRun {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(results) { result in
                        ResultRow(result: result)
                    }
                }

                summary
            }

            HStack {
                Button("Chiudi") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(hasRun ? "Rimisura" : "Verifica") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.volume == nil)
            }
        }
        .padding(Metrics.spacingLarge)
        .frame(width: 560)
    }

    @ViewBuilder
    private var summary: some View {
        let failed = results.filter { !$0.passed }
        if results.isEmpty {
            Text("Nessuna grandezza misurabile su questo volume.")
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
        } else if failed.isEmpty {
            Label(
                "Tutte le grandezze rientrano nella tolleranza.",
                systemImage: "checkmark.seal.fill"
            )
            .font(Typography.label)
            .foregroundStyle(Palette.safe)
        } else {
            Label(
                "\(failed.count) su \(results.count) fuori tolleranza. "
                    + "Non fidarti delle misure su questo volume finché non è chiarito.",
                systemImage: "xmark.octagon.fill"
            )
            .font(Typography.label)
            .foregroundStyle(Palette.danger)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func run() {
        guard let volume = model.volume else { return }
        results = AccuracyVerification.verifyPhantom(volume)
        hasRun = true
    }
}

private struct ResultRow: View {

    let result: VerificationResult

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(result.passed ? Palette.safe : Palette.danger)

            Text(result.name)
                .font(Typography.label)
                .foregroundStyle(Palette.textPrimary)

            Spacer(minLength: Metrics.spacing)

            // Atteso e misurato affiancati, e **poi** lo scarto: il confronto si legge da sé, e
            // lo scarto conferma invece di dover essere ricavato a mente.
            Text(value(result.expected, unit: result.unit))
                .foregroundStyle(Palette.textSecondary)
            Text("→")
                .foregroundStyle(Palette.textSecondary)
            Text(value(result.measured, unit: result.unit))
                .foregroundStyle(Palette.textPrimary)
            Text(result.formattedDeviation)
                .foregroundStyle(result.passed ? Palette.textSecondary : Palette.danger)
                .frame(width: 88, alignment: .trailing)
        }
        .font(Typography.numericSmall)
    }

    private func value(_ number: Double, unit: String) -> String {
        String(format: unit == "mm" ? "%.3f %@" : "%.0f %@", number, unit)
            .replacingOccurrences(of: ".", with: ",")
    }
}
