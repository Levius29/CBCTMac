import ArtifactKit
import DICOMCore
import SegmentKit
import SwiftUI

// Riduzione delle strie da metallo.
//
// # Perché produce un volume nuovo invece di correggere quello aperto
//
// Perché così si può **verificare che abbia funzionato**. Il risultato compare accanto
// all'originale nell'albero dello studio, e passare dall'uno all'altro con un clic mostra la
// differenza dove conta — attorno alla corona, sul contorno della cresta. Correggendo sul posto
// resterebbe solo la parola del programma, e su un'operazione che *modifica i valori acquisiti*
// la parola del programma non basta.
//
// C'è una ragione più severa della comodità. Questa correzione cambia i numeri su cui poi si
// misura la densità ossea: un volume corretto non è più il dato acquisito, e confonderli
// significherebbe misurare su valori inventati senza saperlo. Restano due volumi distinti, con
// due nomi distinti, e la catena di provenienza dice quale è quale.
//
// # Che cosa fa davvero, detto senza abbellire
//
// La MAR vera lavora sulle **proiezioni**, prima della ricostruzione, e ricostruisce ciò che il
// metallo ha nascosto. Noi le proiezioni non le abbiamo: partiamo dal volume già ricostruito, e
// quello che si può fare lì è attenuare le strie — non riportare indietro l'informazione persa.
// La finestra lo dice, perché un utente che si aspetta di *vedere* l'osso dietro un perno moncone
// resterebbe deluso da un risultato che invece è il migliore possibile a valle.

struct ArtifactSheet: View {

    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var settings = ArtifactReductionSettings()
    @State private var useAutomaticThreshold = true
    @State private var manualThresholdGV = 2500.0
    @State private var isWorking = false
    @State private var failure: String?
    @State private var report: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingLarge) {
            Text("Riduci le strie da metallo")
                .font(Typography.sectionHeader)

            Text(
                "Individua le zone metalliche e attenua le strie che ne partono. Il risultato è "
                    + "un volume nuovo accanto all'originale: puoi passare dall'uno all'altro "
                    + "nell'albero dello studio per vedere che cosa è cambiato."
            )
            .font(Typography.body)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            Grid(alignment: .leading, horizontalSpacing: Metrics.spacingLarge, verticalSpacing: 8) {
                GridRow {
                    Text("Soglia del metallo").foregroundStyle(Palette.textSecondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Automatica", isOn: $useAutomaticThreshold)
                            .toggleStyle(.checkbox)
                        if !useAutomaticThreshold {
                            HStack {
                                Slider(value: $manualThresholdGV, in: 1000...6000, step: 50)
                                    .frame(width: 200)
                                Text("\(Int(manualThresholdGV)) GV")
                                    .font(Typography.numericSmall)
                            }
                        } else if let suggested {
                            Text("\(Int(suggested)) GV su questo volume")
                                .font(Typography.numericSmall)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                }

                GridRow {
                    Text("Margine attorno al metallo").foregroundStyle(Palette.textSecondary)
                    HStack {
                        Slider(value: $settings.dilationMM, in: 0...4, step: 0.25)
                            .frame(width: 200)
                        Text(
                            String(format: "%.2f mm", settings.dilationMM)
                                .replacingOccurrences(of: ".", with: ",")
                        )
                        .font(Typography.numericSmall)
                    }
                }

                GridRow {
                    Text("Volume minimo").foregroundStyle(Palette.textSecondary)
                    HStack {
                        Slider(value: $settings.minimumMetalVolumeMM3, in: 0.2...20, step: 0.2)
                            .frame(width: 200)
                        Text(
                            String(format: "%.1f mm³", settings.minimumMetalVolumeMM3)
                                .replacingOccurrences(of: ".", with: ",")
                        )
                        .font(Typography.numericSmall)
                    }
                }
            }

            // Il limite dichiarato, non nascosto in fondo a una documentazione.
            Label(
                "Attenua le strie sul volume già ricostruito. La correzione vera lavora sulle "
                    + "proiezioni della macchina, che qui non ci sono: l'osso nascosto dal metallo "
                    + "non torna, le righe che lo attraversano si smorzano.",
                systemImage: "info.circle"
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            Label(
                "Il volume corretto non è più il dato acquisito. Le densità misurate su di esso "
                    + "non sono confrontabili con quelle dell'originale.",
                systemImage: "exclamationmark.triangle"
            )
            .font(Typography.label)
            .foregroundStyle(Palette.warning)
            .fixedSize(horizontal: false, vertical: true)

            if let report {
                Text(report)
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.safe)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Text(failure)
                    .font(Typography.label)
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Chiudi") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isWorking ? "Elaborazione…" : "Riduci") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.volume == nil || isWorking)
            }
        }
        .padding(Metrics.spacingLarge)
        .frame(width: 580)
    }

    /// Soglia che il rilevatore sceglierebbe da sé, mostrata prima di procedere.
    ///
    /// Vederla serve a decidere se ha senso: su un volume senza metallo la soglia automatica cade
    /// nell'osso denso, e allora conviene metterla a mano invece di lasciare che il programma
    /// scambi una corticale per un perno.
    private var suggested: Double? {
        model.volume.map { MetalDetection.suggestedThresholdGV(for: $0) }
    }

    private func apply() {
        guard let volume = model.volume else { return }
        isWorking = true
        failure = nil
        report = nil

        var used = settings
        used.thresholdGV = useAutomaticThreshold ? nil : manualThresholdGV

        do {
            let processed = try ArtifactReduction.reduceMetalArtifacts(in: volume, settings: used)
            guard processed.provenance.isModified else {
                // Nessun metallo trovato è un esito ordinario, e va detto invece di produrre una
                // copia identica con un nome nuovo: l'albero si riempirebbe di volumi uguali.
                failure =
                    "Nessuna zona metallica trovata con questi parametri. Abbassa la soglia o il "
                    + "volume minimo, oppure il volume non ne contiene."
                isWorking = false
                return
            }
            model.adopt(
                volume: processed.volume, named: "Strie ridotte", operation: "Riduzione strie")
            report = summary(of: processed)
            isWorking = false
            dismiss()
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            isWorking = false
        }
    }

    private func summary(of processed: ProcessedVolume) -> String {
        let steps = processed.provenance.steps.map(\.name).joined(separator: ", ")
        return "Applicato: \(steps)."
    }
}
