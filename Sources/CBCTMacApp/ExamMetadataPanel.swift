import ArchiveKit
import SwiftUI

// Chi è il paziente e com'è stato fatto l'esame.
//
// # Perché è una cosa che deve stare a schermo, e non in una finestra da aprire
//
// Perché è l'informazione che risponde alla domanda «sto guardando la persona giusta?». Nessuna
// misura, nessun impianto e nessuna relazione valgono niente se l'immagine è di un altro
// paziente, e quel controllo si fa una volta all'apertura e poi ogni volta che si torna dopo
// una pausa. Un dato che serve così spesso non può costare l'apertura di una finestra.
//
// Fino a oggi la barra del titolo scriveva il nome della **serie** — «CBCT mascellare» — e il
// piano di lavoro dava per fatta la voce «nome del paziente nella barra del titolo». Non lo era.

struct ExamMetadataPanel: View {

    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if model.patient.isAnonymous && model.exam.studyDate.isEmpty {
                // Un fantoccio, o un export privo di tutto. Dirlo è meglio che mostrare cinque
                // righe vuote, che si leggono come un difetto del programma.
                Label(
                    model.isPhantomOpen
                        ? "Fantoccio sintetico: nessun paziente."
                        : "Questo esame non porta metadati del paziente.",
                    systemImage: model.isPhantomOpen ? "cube.transparent" : "person.fill.questionmark")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                patientBlock
            }

            if !examRows.isEmpty {
                Divider().overlay(Palette.separator)
                ForEach(examRows, id: \.label) { row in
                    MetadataRow(label: row.label, value: row.value)
                }
            }

            if model.archivedExamID != nil {
                Label("In archivio", systemImage: "checkmark.seal")
                    .font(Typography.label)
                    .foregroundStyle(Palette.safe)
            } else if !model.isPhantomOpen, model.volume != nil {
                Button {
                    Task { await model.archiveCurrentExam() }
                } label: {
                    Label("Archivia questo esame", systemImage: "tray.and.arrow.down")
                        .font(Typography.label)
                }
                .disabled(model.isArchiving)
            }
        }
    }

    private var patientBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.patient.displayName)
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Nascita, sesso e identificativo su una riga sola: sono i tre dati con cui si
            // conferma di avere davanti la persona giusta, e separarli su tre righe li
            // allontanerebbe proprio mentre si confrontano.
            if let line = patientLine {
                Text(line)
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var patientLine: String? {
        var parts: [String] = []
        if let birth = model.patient.displayBirthDate { parts.append(birth) }
        if let sex = model.patient.displaySex { parts.append(sex) }
        if !model.patient.patientID.isEmpty { parts.append("ID " + model.patient.patientID) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Le righe dell'esame, saltando quelle che il file non porta.
    ///
    /// Saltando e non riempiendo con un trattino: cinque trattini in colonna sembrano un guasto,
    /// mentre due righe piene si leggono per quello che sono.
    private var examRows: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        let exam = model.exam
        if let date = exam.displayDateTime { rows.append(("Esame", date)) }
        if !exam.displayTitle.isEmpty, exam.displayTitle != "Esame" {
            rows.append(("Serie", exam.displayTitle))
        }
        if let device = exam.displayDevice { rows.append(("Apparecchio", device)) }
        if let exposure = exam.displayExposure { rows.append(("Esposizione", exposure)) }
        if let voxel = exam.displayVoxel { rows.append(("Voxel", voxel)) }
        if let matrix = exam.displayMatrix { rows.append(("Matrice", matrix)) }
        if let fov = exam.displayFieldOfView { rows.append(("Campo", fov)) }
        if !exam.institutionName.isEmpty { rows.append(("Struttura", exam.institutionName)) }
        return rows.map { (label: $0.0, value: $0.1) }
    }
}

private struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
            Text(label)
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
