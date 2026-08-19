import ArchiveKit
import SwiftUI

// L'archivio, e la domanda che lo precede.
//
// # Perché si chiede, invece di archiviare e basta
//
// Perché archiviare è una decisione su dei dati di una persona, e prenderla al posto
// dell'utente sarebbe sbagliato in tutt'e due i versi. Archiviando sempre, il fascicolo si
// riempie di esami guardati di sfuggita e di casi altrui. Non archiviando mai, si perde il
// lavoro proprio quando serviva. La domanda si fa una volta e la risposta si può rendere
// permanente, che è il compromesso che rispetta chi decide.

struct ArchivePromptSheet: View {

    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingLarge) {
            Text("Archiviare questo esame?")
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.textPrimary)

            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                Text(model.patient.isAnonymous ? "Esame senza paziente" : model.patient.displayName)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                if let line = subtitle {
                    Text(line)
                        .font(Typography.numericSmall)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(Metrics.spacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.chromeElevated)
            .clipShape(.rect(cornerRadius: 4))

            Text(
                "L'archivio conserva il volume ricostruito, i metadati e il piano, così l'esame "
                + "si riapre senza la cartella DICOM. **Non** conserva i file DICOM originali: "
                + "tienili tu se devi consegnarli."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            // Dove finiscono e in che stato: scritto qui, non da scoprire. Sono dati di una
            // persona su un disco, e chi archivia ha diritto di saperlo prima e non dopo.
            Label(
                "Vanno in \(AppModel.archiveRootURL.path), in chiaro. Li protegge la "
                + "cifratura del disco del Mac, non questo programma.",
                systemImage: "lock.open")
                .font(Typography.label)
                .foregroundStyle(Palette.warning)
                .fixedSize(horizontal: false, vertical: true)

            if model.patient.isAnonymous {
                Label(
                    "Senza nome né identificativo, questo esame avrà un paziente tutto suo: due "
                    + "esami anonimi non vengono uniti, perché potrebbero essere di due persone.",
                    systemImage: "person.fill.questionmark")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("Fai sempre così, non chiedermelo più", isOn: $remember)
                .font(Typography.label)
                .toggleStyle(.checkbox)

            HStack {
                Button("Non archiviare") {
                    if remember { model.archivePolicy = .never }
                    dismiss()
                }
                Spacer()
                Button("Archivia") {
                    if remember { model.archivePolicy = .always }
                    Task { await model.archiveCurrentExam() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Metrics.spacingLarge)
        .frame(width: 480)
        .background(Palette.chrome)
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let date = model.exam.displayDateTime { parts.append(date) }
        parts.append(model.exam.displayTitle)
        if let voxel = model.exam.displayVoxel { parts.append(voxel) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - L'archivio

struct ArchiveSheet: View {

    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedEntryID: UUID?
    @State private var noteDraft = ""

    private var selectedEntry: ArchiveEntry? {
        guard let id = selectedEntryID else { return nil }
        return model.archivedPatients.flatMap(\.entries).first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            header

            if model.archivedPatients.isEmpty {
                empty
            } else {
                list
            }

            if let entry = selectedEntry {
                Divider().overlay(Palette.separator)
                noteEditor(entry)
            }

            if let message = model.archiveMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(Typography.label)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footer
        }
        .padding(Metrics.spacingLarge)
        .frame(width: 720, height: 540)
        .background(Palette.chrome)
        .task { await model.reloadArchive() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack {
                Text("Archivio")
                    .font(Typography.sectionHeader)
                    .foregroundStyle(Palette.textPrimary)
                Spacer()
                Text(summary)
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.textSecondary)
            }
            TextField("Cerca un paziente, una data, un apparecchio…", text: $model.archiveSearchText)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var summary: String {
        let patients = model.archivedPatients.count
        let exams = model.archivedPatients.reduce(0) { $0 + $1.entries.count }
        let gigabytes = Double(model.archiveBytes) / 1_073_741_824
        let size = gigabytes >= 1
            ? String(format: "%.1f GB", gigabytes)
            : String(format: "%.0f MB", Double(model.archiveBytes) / 1_048_576)
        return "\(patients) pazienti · \(exams) esami · \(size)"
            .replacingOccurrences(of: ".", with: ",")
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Spacer()
            Text("L'archivio è vuoto.")
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
            Text(
                "Aprendo un esame il programma chiede se archiviarlo. Da lì in poi si riapre da "
                + "questa finestra, senza la cartella DICOM."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.spacingLarge) {
                ForEach(model.filteredArchivedPatients) { patient in
                    VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                        PatientHeader(patient: patient)
                        ForEach(patient.entries) { entry in
                            ExamRow(
                                model: model,
                                entry: entry,
                                isSelected: entry.id == selectedEntryID,
                                isOpen: entry.id == model.archivedExamID,
                                onSelect: { selectedEntryID = entry.id })
                        }
                    }
                }
            }
            .padding(.vertical, Metrics.spacingSmall)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// La nota dell'esame selezionato.
    ///
    /// # Perché una bozza locale e non un legame diretto
    ///
    /// Perché scriverla è battere trenta caratteri, e un legame diretto scriverebbe su disco a
    /// ogni tasto — trenta riscritture dell'indice per una frase. La bozza vive nella vista e
    /// arriva in archivio quando si conferma o si cambia selezione, che sono i due momenti in
    /// cui la frase è finita.
    private func noteEditor(_ entry: ArchiveEntry) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            Text("Nota su questo esame")
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
            HStack(spacing: Metrics.spacing) {
                TextField("Che cosa ricordare di questo esame", text: $noteDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitNote(entry) }
                Button("Salva") { commitNote(entry) }
                    .disabled(noteDraft == entry.note)
            }
        }
        .onChange(of: entry.id, initial: true) { noteDraft = entry.note }
    }

    private func commitNote(_ entry: ArchiveEntry) {
        let text = noteDraft
        guard text != entry.note else { return }
        Task { await model.setArchiveNote(text, for: entry) }
    }

    private var footer: some View {
        HStack {
            Button("Chiudi") { dismiss() }
            Button("Ricostruisci l'indice") {
                Task { await model.rebuildArchiveIndex() }
            }
            .help(
                "Rilegge le cartelle degli esami e riscrive l'indice. Serve quando i due "
                + "divergono: una scrittura interrotta, o una cartella copiata da un altro Mac.")
            Spacer()
            if model.isArchiving { ProgressView().controlSize(.small) }
            if let entry = selectedEntry {
                Button(role: .destructive) {
                    selectedEntryID = nil
                    Task { await model.removeArchived(entry) }
                } label: {
                    Label("Elimina", systemImage: "trash")
                }
                Button("Apri") {
                    Task { await model.openArchived(entry) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: Righe

private struct PatientHeader: View {
    let patient: ArchivedPatient

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
            Image(systemName: patient.identity.isAnonymous ? "person.fill.questionmark" : "person")
                .font(.system(size: 11))
                .foregroundStyle(Palette.textSecondary)
            Text(patient.identity.isAnonymous ? "Esame senza paziente" : patient.identity.displayName)
                .font(Typography.body.weight(.semibold))
                .foregroundStyle(Palette.textPrimary)
            if let line = detail {
                Text(line)
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
            Text("\(patient.entries.count)")
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private var detail: String? {
        var parts: [String] = []
        if let birth = patient.identity.displayBirthDate { parts.append(birth) }
        if !patient.identity.patientID.isEmpty { parts.append("ID " + patient.identity.patientID) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct ExamRow: View {

    let model: AppModel
    let entry: ArchiveEntry
    let isSelected: Bool
    let isOpen: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
            Text(ArchiveKit.DICOMDate.displayShort(entry.exam.studyDate) ?? "data ignota")
                .font(Typography.numericSmall)
                .foregroundStyle(isOpen ? Palette.accent : Palette.textPrimary)
                .frame(width: 78, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.exam.displayTitle)
                    .font(Typography.label)
                    .foregroundStyle(Palette.textPrimary)
                if let line = detail {
                    Text(line)
                        .font(Typography.numericSmall)
                        .foregroundStyle(Palette.textSecondary)
                }
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(Typography.numericSmall)
                        .foregroundStyle(Palette.textSecondary)
                        .italic()
                }
            }

            Spacer(minLength: Metrics.spacing)

            if entry.hasPlan {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.accent)
                    .help("Con un piano salvato")
            }
            Text(size)
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, Metrics.spacing)
        .background(isSelected ? Palette.accent.opacity(0.16) : Color.clear)
        .clipShape(.rect(cornerRadius: 4))
        .contentShape(.rect)
        .onTapGesture(count: 2) { Task { await model.openArchived(entry) } }
        .onTapGesture { onSelect() }
    }

    private var detail: String? {
        var parts: [String] = []
        if let device = entry.exam.displayDevice { parts.append(device) }
        if let voxel = entry.exam.displayVoxel { parts.append(voxel) }
        if let matrix = entry.exam.displayMatrix { parts.append(matrix) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var size: String {
        let megabytes = Double(entry.volumeBytes) / 1_048_576
        return String(format: "%.0f MB", megabytes)
    }
}
