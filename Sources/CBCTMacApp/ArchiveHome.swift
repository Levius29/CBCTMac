import ArchiveKit
import SwiftUI

// La schermata d'avvio: l'archivio.
//
// # Perché non si apre più il fantoccio
//
// Il fantoccio all'avvio serviva quando non c'era un parser DICOM: dava qualcosa di reale da
// disegnare a un programma che altrimenti non poteva aprire niente. Adesso apre studi veri e
// li conserva, e partire da un cubo sintetico significa che la prima cosa che si vede a ogni
// avvio è l'unica che non interessa — e che il proprio lavoro sta dietro un menu.
//
// Il fantoccio resta, e non è un ripensamento: è il metro contro cui si prova la catena di
// misura, ed è quello che alimenta ⇧⌘V. Si carica quando serve, dal menu, invece di imporsi.

struct ArchiveHome: View {

    @Bindable var model: AppModel
    let onOpenFolder: () -> Void

    @State private var selectedEntryID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.separator)

            if let message = model.loadingMessage {
                loading(message)
            } else if model.archivedPatients.isEmpty {
                empty
            } else {
                list
            }

            if !model.loadIssues.isEmpty || model.archiveMessage != nil {
                Divider().overlay(Palette.separator)
                issues
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.viewportBackground)
        .task { await model.reloadArchive() }
    }

    // MARK: Testata

    private var header: some View {
        HStack(alignment: .center, spacing: Metrics.spacingLarge) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppIcon.displayName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(summary)
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.textSecondary)
            }

            Spacer(minLength: Metrics.spacing)

            if !model.archivedPatients.isEmpty {
                TextField("Cerca", text: $model.archiveSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }

            // Il pulsante che conta, e sta dove si guarda per primo.
            Button(action: onOpenFolder) {
                Label("Apri un nuovo esame…", systemImage: "folder.badge.plus")
            }
            .keyboardShortcut("o", modifiers: .command)
            .controlSize(.large)
        }
        .padding(Metrics.spacingLarge)
    }

    private var summary: String {
        guard !model.archivedPatients.isEmpty else { return "Archivio vuoto" }
        let patients = model.archivedPatients.count
        let exams = model.archivedPatients.reduce(0) { $0 + $1.entries.count }
        let gigabytes = Double(model.archiveBytes) / 1_073_741_824
        let size = gigabytes >= 1
            ? String(format: "%.1f GB", gigabytes)
            : String(format: "%.0f MB", Double(model.archiveBytes) / 1_048_576)
        let people = patients == 1 ? "1 paziente" : "\(patients) pazienti"
        let studies = exams == 1 ? "1 esame" : "\(exams) esami"
        return "\(people) · \(studies) · \(size)".replacingOccurrences(of: ".", with: ",")
    }

    // MARK: Stati

    private func loading(_ message: String) -> some View {
        VStack(spacing: Metrics.spacing) {
            Spacer()
            ProgressView()
            Text(message)
                .font(Typography.body)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var empty: some View {
        VStack(spacing: Metrics.spacing) {
            Spacer()
            Image(systemName: "tray")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.textSecondary.opacity(0.6))
            Text("Nessun esame in archivio")
                .font(Typography.body)
                .foregroundStyle(Palette.textPrimary)
            Text(
                "Apri la cartella DICOM di un esame: il programma chiede se archiviarlo, e da "
                + "quel momento si riapre da qui senza più bisogno della cartella."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
            .fixedSize(horizontal: false, vertical: true)

            Button("Apri un esame…", action: onOpenFolder)
                .padding(.top, Metrics.spacing)

            // Il fantoccio non sparisce: cambia posto. Qui, in fondo e in piccolo, per chi
            // vuole provare le misure senza avere ancora un esame da aprire.
            Button("Carica il fantoccio di prova") {
                Task { await model.loadSyntheticPhantom() }
            }
            .buttonStyle(.link)
            .font(Typography.label)
            .help(
                "Un cubo di venti millimetri con sfere di densità nota. Serve a verificare che "
                + "le misure siano giuste, ed è quello su cui lavora ⇧⌘V.")

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.spacingLarge) {
                ForEach(model.filteredArchivedPatients) { patient in
                    VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
                            Image(
                                systemName: patient.identity.isAnonymous
                                    ? "person.fill.questionmark" : "person")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.textSecondary)
                            Text(
                                patient.identity.isAnonymous
                                    ? "Esame senza paziente" : patient.identity.displayName
                            )
                            .font(Typography.body.weight(.semibold))
                            .foregroundStyle(Palette.textPrimary)
                            if let detail = patientDetail(patient) {
                                Text(detail)
                                    .font(Typography.numericSmall)
                                    .foregroundStyle(Palette.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }

                        ForEach(patient.entries) { entry in
                            HomeExamRow(
                                entry: entry,
                                isSelected: entry.id == selectedEntryID,
                                onSelect: { selectedEntryID = entry.id },
                                onOpen: { Task { await model.openArchived(entry) } })
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.spacingLarge)
            .padding(.vertical, Metrics.spacing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func patientDetail(_ patient: ArchivedPatient) -> String? {
        var parts: [String] = []
        if let birth = patient.identity.displayBirthDate { parts.append(birth) }
        if !patient.identity.patientID.isEmpty { parts.append("ID " + patient.identity.patientID) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var issues: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            if let message = model.archiveMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Typography.label)
                    .foregroundStyle(Palette.warning)
            }
            ForEach(model.loadIssues, id: \.self) { issue in
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(Typography.label)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacingLarge)
    }
}

// MARK: Riga

private struct HomeExamRow: View {

    let entry: ArchiveEntry
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
            Text(ArchiveKit.DICOMDate.displayShort(entry.exam.studyDate) ?? "data ignota")
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textPrimary)
                .frame(width: 82, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.exam.displayTitle)
                    .font(Typography.label)
                    .foregroundStyle(Palette.textPrimary)
                if let detail = detail {
                    Text(detail)
                        .font(Typography.numericSmall)
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            Spacer(minLength: Metrics.spacing)

            if entry.hasPlan {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.accent)
                    .help("Con un piano salvato")
            }
            if entry.hasScan == true {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.accent)
                    .help("Con la scansione intraorale registrata")
            }

            Button("Apri", action: onOpen)
                .buttonStyle(.borderless)
                .font(Typography.label)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, Metrics.spacing)
        .background(isSelected ? Palette.accent.opacity(0.16) : Palette.chrome.opacity(0.5))
        .clipShape(.rect(cornerRadius: 4))
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: onOpen)
        .onTapGesture(perform: onSelect)
    }

    private var detail: String? {
        var parts: [String] = []
        if let device = entry.exam.displayDevice { parts.append(device) }
        if let voxel = entry.exam.displayVoxel { parts.append(voxel) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
