import DICOMCore
import SegmentKit
import SwiftUI

// Raddrizzare il volume sul piano occlusale.
//
// # Perché pesa più di quanto sembri
//
// Nessuno se ne accorge finché non apre una CBCT con la testa inclinata, cioè quasi sempre. Su un
// volume storto ogni misura verticale si legge di traverso: l'altezza di cresta misurata su una
// fetta obliqua non è l'altezza di cresta, e l'errore cresce con l'inclinazione senza che nulla lo
// dichiari.
//
// # Perché si posano i punti col mirino invece di trascinarli
//
// Perché il piano occlusale non si vede su una sola fetta. I tre punti — due cuspidi e un
// incisivo — stanno a quote diverse, e trovarli richiede di navigare fra le viste. Il mirino è già
// lo strumento con cui si naviga; posare un punto «dove sta adesso il mirino» riusa un gesto noto
// invece di aggiungerne uno.
//
// # L'avvertenza che questa finestra deve dare
//
// Ricampionare produce un volume in un **riferimento nuovo**, e le annotazioni esistenti vanno
// trasformate con la stessa rotazione. Il programma lo fa; la finestra lo dice, perché chi
// raddrizza dopo aver misurato deve sapere che le misure si sono mosse con l'anatomia e non sono
// rimaste indietro.

struct ReorientSheet: View {

    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var points: [Vec3] = []
    @State private var spacingMM = 0.3
    @State private var isWorking = false
    @State private var failure: String?

    private var plan: ReorientationPlan { ReorientationPlan(referencePointsMM: points) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingLarge) {
            Text("Raddrizza sul piano occlusale")
                .font(Typography.sectionHeader)

            Text(
                "Porta il mirino su un riferimento del piano occlusale e premi «Posa punto». "
                    + "Ne servono tre non allineati: di norma due cuspidi e un incisivo."
            )
            .font(Typography.body)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    HStack {
                        Text("Punto \(index + 1)")
                            .font(Typography.body)
                            .frame(width: 70, alignment: .leading)
                        Text(
                            String(
                                format: "L %.1f  P %.1f  S %.1f", point.x, point.y, point.z
                            ).replacingOccurrences(of: ".", with: ",")
                        )
                        .font(Typography.numericSmall)
                        .foregroundStyle(Palette.textSecondary)
                        Spacer()
                        Button("Togli") { points.remove(at: index) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Palette.danger)
                            .font(Typography.label)
                    }
                }
                if points.count < 3 {
                    Text("Mancano \(3 - points.count) punti.")
                        .font(Typography.label)
                        .foregroundStyle(Palette.warning)
                }
            }
            .frame(minHeight: 76, alignment: .top)

            HStack {
                Button("Posa punto") { points.append(model.crosshairMM) }
                    .disabled(points.count >= 3 || model.volume == nil)
                Button("Azzera") { points = [] }
                    .disabled(points.isEmpty)
                Spacer()
                LabeledControl("Passo") {
                    Picker("", selection: $spacingMM) {
                        ForEach([0.15, 0.2, 0.25, 0.3, 0.4, 0.5], id: \.self) { value in
                            Text(InspectorPanel.spacingText(value)).tag(value)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            ForEach(plan.validate(), id: \.self) { problem in
                Text("• \(problem)")
                    .font(Typography.label)
                    .foregroundStyle(Palette.warning)
            }

            if let angle = tiltDegrees {
                Text(
                    String(format: "Inclinazione rilevata: %.1f°", angle)
                        .replacingOccurrences(of: ".", with: ",")
                )
                .font(Typography.numeric)
                .foregroundStyle(Palette.textPrimary)
            }

            Label(
                "Il volume raddrizzato è un volume nuovo, in un riferimento nuovo. Misure, "
                    + "impianti e curve vengono trasformati con la stessa rotazione, quindi "
                    + "continuano a indicare lo stesso tessuto.",
                systemImage: "info.circle"
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if let failure {
                Text(failure)
                    .font(Typography.label)
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Annulla") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isWorking ? "Elaborazione…" : "Raddrizza") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(points.count < 3 || isWorking || !plan.validate().isEmpty)
            }
        }
        .padding(Metrics.spacingLarge)
        .frame(width: 560)
    }

    /// Di quanto è inclinato il piano posato rispetto all'orizzontale.
    ///
    /// Mostrarlo prima di procedere risponde alla domanda che ci si pone davvero: **vale la pena**
    /// ricampionare? Sotto un paio di gradi non cambia nulla di leggibile, e il ricampionamento
    /// costa una copia del volume e una perdita di nitidezza per interpolazione.
    private var tiltDegrees: Double? {
        guard let normal = plan.planeNormalMM else { return nil }
        let cosine = min(max(abs(normal.dot(Vec3(0, 0, 1))), 0), 1)
        return Foundation.acos(cosine) * 180 / .pi
    }

    /// Fuori dal thread dell'interfaccia, come la riduzione delle strie e per lo stesso motivo:
    /// ricampionare una CBCT a campo grande sono decine di secondi, e sul main actor sarebbero
    /// decine di secondi di finestra congelata.
    private func apply() {
        guard let volume = model.volume else { return }
        isWorking = true
        failure = nil

        let requestedPlan = plan
        let requestedSpacing = spacingMM

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    try VolumeReorientation.reoriented(
                        volume, plan: requestedPlan, spacingMM: requestedSpacing)
                }
            }.value

            isWorking = false
            switch outcome {
            case .success(let reoriented):
                model.adoptReoriented(reoriented, plan: requestedPlan)
                dismiss()
            case .failure(let error):
                failure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }
    }
}
