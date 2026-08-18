import DICOMCore
import ImplantKit
import MeasureKit
import ReportKit
import StudyKit
import SwiftUI

// La scheda «Rivedi»: il piano finito, riletto.
//
// # Perché una scheda e non un pulsante «stampa»
//
// Rivedere non è esportare. Prima di consegnare un piano lo si ripercorre: quanti impianti,
// quanto vicini al nervo, che misure sono state prese, su quale volume. La relazione stampata
// serve dopo, e serve a qualcun altro.
//
// # Perché è di sola lettura, e perché lo dice
//
// In rilettura si guarda con attenzione e si tocca senza pensarci. Uno strumento attivo qui
// significa spostare un impianto mentre lo si esamina, senza accorgersene, con le stesse
// conseguenze di una modifica deliberata e meno attenzione di una. Il modo forza lo strumento su
// «naviga» e lo scrive nella barra, perché uno strumento che non risponde e non si spiega
// sembra un difetto del programma.
//
// # Che cosa **non** c'è qui
//
// L'impaginazione della relazione, con le immagini e le intestazioni. Quella è un'altra cosa e
// arriverà come tale: qui si rilegge a schermo, lì si produce un documento. Confonderle
// significherebbe fare male entrambe.

struct ReviewPanel: View {

    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingLarge) {
            issuesSection
            Divider().overlay(Palette.separator)
            volumeSection
            Divider().overlay(Palette.separator)
            implantSection
            Divider().overlay(Palette.separator)
            measurementSection
            Divider().overlay(Palette.separator)
            disclaimer
        }
    }

    // MARK: Che cosa non torna

    /// I problemi del piano, in cima e prima dei numeri.
    ///
    /// In cima perché è ciò che si deve vedere per primo: una scheda che elenca prima i valori e
    /// poi i problemi si legge nell'ordine sbagliato. E qui e non solo nella relazione, perché la
    /// relazione la si esporta a lavoro finito, mentre questi sono da vedere **mentre** lo si fa.
    @ViewBuilder
    private var issuesSection: some View {
        let issues = model.planIssues
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            SectionHeader("DA RISOLVERE")

            if issues.isEmpty {
                Text("Niente da segnalare su ciò che il programma sa verificare.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(issues) { issue in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: symbol(for: issue.severity))
                            .font(.system(size: 10))
                            .foregroundStyle(colour(for: issue.severity))
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(issue.title)
                                .font(Typography.label)
                                .foregroundStyle(colour(for: issue.severity))
                            Text(issue.detail)
                                .font(Typography.label)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func symbol(for severity: PlanIssueSeverity) -> String {
        switch severity {
        case .blocking: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .note: return "info.circle"
        }
    }

    private func colour(for severity: PlanIssueSeverity) -> Color {
        switch severity {
        case .blocking: return Palette.danger
        case .warning: return Palette.warning
        case .note: return Palette.textSecondary
        }
    }

    // MARK: Volume

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            SectionHeader("VOLUME")

            if let entry = model.library.selected {
                LabeledContent2("Nome", entry.name)
                LabeledContent2("Griglia", entry.summary)
                // La catena di provenienza è la risposta a «da dove viene questo numero»: un
                // valore letto su un volume ricampionato due volte non è un valore letto sui
                // dati originali, e chi rilegge deve poterlo sapere senza indagare.
                if model.library.depth(of: entry.id) > 0 {
                    LabeledContent2(
                        "Provenienza", model.library.provenanceDescription(of: entry.id))
                }
                LabeledContent2("Unità", model.reconstructionLabel)
            } else {
                emptyNote("Nessuno studio aperto.")
            }
        }
    }

    // MARK: Impianti

    private var implantSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            SectionHeader("IMPIANTI (\(model.implants.count))")

            if model.implants.isEmpty {
                emptyNote("Nessun impianto pianificato.")
            } else {
                ForEach(model.implants) { implant in
                    implantRow(implant)
                }
            }
        }
    }

    @ViewBuilder
    private func implantRow(_ implant: ImplantPlacement) -> some View {
        let report = model.safetyReports[implant.id]
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Metrics.spacing) {
                Circle()
                    .fill(Color(hexString: implant.colorHex) ?? Palette.textSecondary)
                    .frame(width: 8, height: 8)
                Text(implant.label.isEmpty ? "Impianto" : implant.label)
                    .font(Typography.body)
                    .foregroundStyle(Palette.textPrimary)
                Spacer(minLength: 0)
                Text(
                    String(format: "Ø%.1f × %.0f mm", implant.model.diameterMM,
                        implant.model.lengthMM)
                        .replacingOccurrences(of: ".", with: ",")
                )
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textSecondary)
            }

            // Il riscontro peggiore, non tutti: in rilettura serve sapere se c'è qualcosa da
            // guardare, e i dettagli stanno nel pannello di sicurezza dove si può agire.
            if let worst = report?.findings.max(by: { $0.level < $1.level }) {
                Label(
                    "\(worst.structureName) · \(worst.formattedDistance)",
                    systemImage: worst.level == .safe ? "checkmark.circle" : "exclamationmark.triangle.fill"
                )
                .font(Typography.label)
                .foregroundStyle(color(for: worst.level))
            }

            if let angulation = report?.angulationDegrees {
                Text(
                    String(format: "Inclinazione %.0f° sulla verticale", angulation)
                )
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(Metrics.spacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.chromeElevated, in: .rect(cornerRadius: 5))
    }

    private func color(for level: SafetyLevel) -> Color {
        switch level {
        case .safe: return Palette.safe
        case .caution: return Palette.caution
        case .danger: return Palette.danger
        }
    }

    // MARK: Misure

    private var measurementSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            SectionHeader("MISURE (\(model.annotations.count))")

            if model.annotations.isEmpty {
                emptyNote("Nessuna misura registrata.")
            } else {
                ForEach(model.annotations) { annotation in
                    MeasurementRow(
                        annotation: annotation,
                        statistics: model.roiStatistics[annotation.id],
                        isSelected: false)
                }
            }
        }
    }

    // MARK: Avvertenza

    private var disclaimer: some View {
        // Ripetuta qui e non solo nel banner in cima: questa è la schermata da cui si esce per
        // andare a operare, ed è il punto in cui l'avvertenza va riletta.
        Label(
            "Software non certificato come dispositivo medico. Ogni decisione clinica resta "
                + "dell'operatore.",
            systemImage: "exclamationmark.triangle"
        )
        .font(Typography.label)
        .foregroundStyle(Palette.warning)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Riga «etichetta: valore» dell'ispettore.
///
/// Non si usa `LabeledContent` di SwiftUI perché il suo stile predefinito allinea a destra su una
/// larghezza che qui è stretta, e i valori lunghi — una catena di provenienza — finiscono
/// troncati proprio dove servono per intero.
struct LabeledContent2: View {

    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
            Text(value)
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
