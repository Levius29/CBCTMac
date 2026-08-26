import DICOMCore
import Foundation

// L'archivio degli esami.
//
// # Che cosa promette
//
// Che un esame archiviato oggi si riapra fra sei mesi senza la cartella DICOM da cui è venuto,
// e che si trovi partendo dal paziente. Nient'altro: non è una cartella clinica, non tiene
// referti, non parla con nessun PACS.
//
// # La forma su disco, e perché un indice
//
//     Archivio/
//       archivio.json          indice: pazienti, esami, riferimenti
//       esami/
//         <uuid>/
//           volume.json        geometria, rescale, unità
//           volume.bin         campioni Int16 little-endian
//           esame.json         paziente e parametri d'acquisizione
//           piano.cbctplan     il piano, se ne era stato salvato uno
//
// L'indice esiste per non dover aprire cinquanta cartelle per disegnare un elenco. È una copia
// di informazioni che stanno anche in `esame.json`, ed è una duplicazione consapevole: la
// ricostruzione dell'indice dalle cartelle è sempre possibile — `rebuildIndex` — e serve
// esattamente quando le due cose divergono.
//
// # Che cosa succede se il programma muore a metà
//
// Si scrive **prima la cartella dell'esame, poi l'indice**. Morendo in mezzo resta una cartella
// che l'indice non nomina: invisibile, recuperabile con `rebuildIndex`, e soprattutto
// innocua. L'ordine inverso lascerebbe un indice che promette un esame inesistente, cioè una
// riga che si può cliccare e non si apre.

public enum ArchiveError: Error, Sendable, LocalizedError {
    case entryNotFound(UUID)
    case rootNotWritable(URL, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .entryNotFound:
            return "L'esame non è più nell'archivio: forse è stato cancellato da un'altra "
                + "finestra, o la cartella è stata rimossa a mano."
        case .rootNotWritable(let url, let underlying):
            return "Impossibile scrivere nell'archivio in \(url.path): \(underlying)"
        }
    }
}

// MARK: - Voce d'archivio

/// Un esame archiviato.
public struct ArchiveEntry: Hashable, Sendable, Codable, Identifiable {

    public let id: UUID
    public var patient: PatientIdentity
    public var exam: ExamMetadata
    /// Quando è stato messo in archivio.
    public var storedAt: Date
    /// La cartella da cui è stato importato, per ritrovare i DICOM originali.
    public var sourcePath: String
    /// Byte occupati dai campioni.
    public var volumeBytes: Int
    /// Vero se accanto al volume c'è un piano.
    public var hasPlan: Bool
    /// Vero se accanto al volume c'è la scansione intraorale registrata.
    ///
    /// Opzionale perché non esisteva: una voce scritta prima non ha la chiave, e pretenderla
    /// renderebbe illeggibile un archivio che funziona.
    public var hasScan: Bool?
    /// Nota libera dell'utente sull'esame.
    public var note: String

    /// La chiave con cui questo esame si raggruppa sotto un paziente.
    ///
    /// Calcolata all'archiviazione e **conservata**, non ricalcolata a ogni lettura: correggere
    /// il nome di un paziente non deve spostare i suoi esami sotto un altro. Per un esame
    /// anonimo è l'identificatore della voce stessa, che gli dà un paziente tutto suo.
    public var patientKey: String

    public init(
        id: UUID = UUID(),
        patient: PatientIdentity,
        exam: ExamMetadata,
        storedAt: Date = Date(),
        sourcePath: String = "",
        volumeBytes: Int = 0,
        hasPlan: Bool = false,
        hasScan: Bool? = nil,
        note: String = "",
        patientKey: String? = nil
    ) {
        self.id = id
        self.patient = patient
        self.exam = exam
        self.storedAt = storedAt
        self.sourcePath = sourcePath
        self.volumeBytes = volumeBytes
        self.hasPlan = hasPlan
        self.hasScan = hasScan
        self.note = note
        self.patientKey = patientKey ?? patient.mergeKey ?? "anon:" + id.uuidString
    }

    /// Chiave d'ordinamento dell'esame nel tempo.
    public var chronologicalKey: String {
        DICOMDate.sortKey(date: exam.studyDate, time: exam.studyTime)
    }

    /// Riassunto per una riga d'elenco.
    public var summary: String {
        var parts: [String] = []
        if let date = DICOMDate.displayShort(exam.studyDate) { parts.append(date) }
        parts.append(exam.displayTitle)
        if let voxel = exam.displayVoxel { parts.append(voxel) }
        return parts.joined(separator: " · ")
    }
}

/// Un paziente con i suoi esami, dal più recente.
public struct ArchivedPatient: Hashable, Sendable, Identifiable {
    public let id: String
    public let identity: PatientIdentity
    public let entries: [ArchiveEntry]

    public init(id: String, identity: PatientIdentity, entries: [ArchiveEntry]) {
        self.id = id
        self.identity = identity
        self.entries = entries
    }

    /// Data dell'esame più recente, per ordinare l'elenco dei pazienti.
    public var mostRecentKey: String { entries.first?.chronologicalKey ?? "" }
}

/// Il contenuto di `archivio.json`.
public struct ArchiveIndex: Hashable, Sendable, Codable {
    public static let currentVersion = 1

    public var version: Int
    public var entries: [ArchiveEntry]

    public init(version: Int = ArchiveIndex.currentVersion, entries: [ArchiveEntry] = []) {
        self.version = version
        self.entries = entries
    }
}

// MARK: - Archivio

public struct PatientArchive: Sendable {

    public static let indexName = "archivio.json"
    public static let examsFolderName = "esami"
    public static let planName = "piano.cbctplan"
    public static let examName = "esame.json"
    public static let scanName = "scansione.stl"
    public static let snapshotsFolderName = "istantanee"

    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    public var indexURL: URL { rootURL.appendingPathComponent(Self.indexName) }
    public var examsURL: URL { rootURL.appendingPathComponent(Self.examsFolderName) }

    public func directory(for id: UUID) -> URL {
        examsURL.appendingPathComponent(id.uuidString)
    }

    // MARK: Indice

    /// Legge l'indice. Un archivio che non esiste ancora è un indice vuoto, non un errore.
    public func loadIndex() throws -> ArchiveIndex {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return ArchiveIndex()
        }
        let data = try Data(contentsOf: indexURL)
        return try JSONDecoder.archive.decode(ArchiveIndex.self, from: data)
    }

    public func save(_ index: ArchiveIndex) throws {
        try createFolders()
        let data = try JSONEncoder.archive.encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    private func createFolders() throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: examsURL, withIntermediateDirectories: true)
        } catch {
            throw ArchiveError.rootNotWritable(rootURL, underlying: error.localizedDescription)
        }
    }

    // MARK: Archiviare

    /// Mette un esame in archivio, o ne aggiorna uno già presente.
    ///
    /// Lo stesso esame — stesso `SeriesInstanceUID` nello stesso studio — non entra due volte:
    /// riaprire la stessa cartella e riarchiviarla **sostituisce**. Senza questo controllo un
    /// archivio si riempirebbe di copie identiche a ogni apertura, e l'elenco del paziente
    /// diventerebbe illeggibile proprio per chi lo usa più spesso.
    ///
    /// - Parameter preservingExistingPlanWhenAbsent: conserva il piano trovato quando il
    ///   chiamante non ne porta uno. Serve a chi ha reimportato gli stessi DICOM ma non possiede
    ///   ancora la voce; chi l'ha aperta dall'archivio lascia il valore falso e può rimuoverlo.
    /// - Returns: la voce scritta.
    @discardableResult
    public func store(
        volume: Volume,
        patient: PatientIdentity,
        exam: ExamMetadata,
        sourcePath: String = "",
        plan: Data? = nil,
        preservingExistingPlanWhenAbsent: Bool = false
    ) throws -> ArchiveEntry {
        try createFolders()
        var index = try loadIndex()

        var metadata = exam
        metadata.adopt(geometry: volume.geometry)

        let existing = index.entries.firstIndex { $0.matches(exam: metadata) }
        let id = existing.map { index.entries[$0].id } ?? UUID()
        // La chiave del paziente si conserva quando la voce esiste già: un esame anonimo
        // riarchiviato deve restare sotto il paziente in cui l'utente lo ha già visto, non
        // finire sotto uno nuovo con lo stesso contenuto.
        let key = existing.map { index.entries[$0].patientKey }
            ?? patient.mergeKey ?? "anon:" + id.uuidString
        let note = existing.map { index.entries[$0].note } ?? ""
        let existingHasPlan = existing.map { index.entries[$0].hasPlan } ?? false
        // La scansione vive in un file separato e `store` non la riscrive: anche il distintivo
        // deve sopravvivere, altrimenti l'indice nega un file che è ancora presente sul disco.
        let existingHasScan = existing.flatMap { index.entries[$0].hasScan }

        let folder = directory(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try VolumeFile.write(volume, to: folder)

        var entry = ArchiveEntry(
            id: id,
            patient: patient,
            exam: metadata,
            storedAt: Date(),
            sourcePath: sourcePath,
            volumeBytes: VolumeFile.byteCount(of: volume),
            hasPlan: plan != nil || (preservingExistingPlanWhenAbsent && existingHasPlan),
            hasScan: existingHasScan,
            note: note,
            patientKey: key)

        let planURL = folder.appendingPathComponent(Self.planName)
        if let plan {
            try plan.write(to: planURL, options: .atomic)
        } else if !preservingExistingPlanWhenAbsent {
            // Riarchiviare senza piano toglie quello vecchio: lasciarlo significherebbe
            // riaprire l'esame e ritrovare un piano che si credeva di aver rimosso.
            try? FileManager.default.removeItem(at: planURL)
            entry.hasPlan = false
        }

        let encoder = JSONEncoder.archive
        try encoder.encode(entry).write(
            to: folder.appendingPathComponent(Self.examName), options: .atomic)

        if let existing {
            index.entries[existing] = entry
        } else {
            index.entries.append(entry)
        }
        try save(index)
        return entry
    }

    /// Scrive o rimuove il **solo piano** di un esame già archiviato.
    ///
    /// Separato da `store` per una ragione di peso, in senso letterale: un volume da 512³ occupa
    /// 268 MB, un piano qualche decina di kilobyte. Il piano cambia a ogni misura e a ogni
    /// impianto spostato; riscrivere il volume ogni volta significherebbe un quarto di gigabyte
    /// sul disco per aver mosso una piattaforma di mezzo millimetro.
    ///
    /// - Throws: se l'esame non è in archivio. Scrivere un piano per un esame che non c'è
    ///   lascerebbe una cartella orfana con dentro il solo piano.
    public func setPlan(_ plan: Data?, for id: UUID) throws {
        var index = try loadIndex()
        guard let position = index.entries.firstIndex(where: { $0.id == id }) else {
            throw ArchiveError.entryNotFound(id)
        }
        let folder = directory(for: id)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw ArchiveError.entryNotFound(id)
        }

        let planURL = folder.appendingPathComponent(Self.planName)
        if let plan {
            try plan.write(to: planURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: planURL)
        }

        index.entries[position].hasPlan = plan != nil
        try save(index)
        try? JSONEncoder.archive.encode(index.entries[position]).write(
            to: folder.appendingPathComponent(Self.examName), options: .atomic)
    }

    /// Scrive o rimuove la **sola scansione** di un esame già archiviato.
    ///
    /// Come `setPlan`, e per la stessa ragione di peso: una scansione intraorale è qualche
    /// megabyte, il volume duecentosessanta. Riscrivere il volume per aver importato uno STL
    /// sarebbe assurdo.
    ///
    /// Senza la scansione, riaprendo un caso si ritroverebbe il piano ma non la superficie su
    /// cui la dima appoggia — e la dima non si potrebbe più ricostruire.
    public func setScan(_ scan: Data?, for id: UUID) throws {
        var index = try loadIndex()
        guard let position = index.entries.firstIndex(where: { $0.id == id }) else {
            throw ArchiveError.entryNotFound(id)
        }
        let folder = directory(for: id)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw ArchiveError.entryNotFound(id)
        }

        let scanURL = folder.appendingPathComponent(Self.scanName)
        if let scan {
            try scan.write(to: scanURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: scanURL)
        }

        index.entries[position].hasScan = scan != nil
        try save(index)
        try? JSONEncoder.archive.encode(index.entries[position]).write(
            to: folder.appendingPathComponent(Self.examName), options: .atomic)
    }

    /// La cartella delle istantanee di un esame.
    public func snapshotsDirectory(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent(Self.snapshotsFolderName)
    }

    /// Aggiunge un'istantanea a un esame archiviato.
    ///
    /// Un file per istantanea, col proprio identificatore come nome. Non un unico archivio di
    /// immagini: cancellarne una diventerebbe riscrivere tutte le altre, e un'istantanea si
    /// cancella spesso — se ne prendono cinque e se ne tengono due.
    public func addSnapshot(_ png: Data, id snapshotID: UUID, for examID: UUID) throws {
        let index = try loadIndex()
        guard index.entries.contains(where: { $0.id == examID }) else {
            throw ArchiveError.entryNotFound(examID)
        }
        let folder = snapshotsDirectory(for: examID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(
            to: folder.appendingPathComponent(snapshotID.uuidString + ".png"), options: .atomic)
    }

    /// I byte di un'istantanea, se c'è.
    public func loadSnapshot(_ snapshotID: UUID, for examID: UUID) -> Data? {
        try? Data(
            contentsOf: snapshotsDirectory(for: examID)
                .appendingPathComponent(snapshotID.uuidString + ".png"))
    }

    /// Toglie un'istantanea. Silenzioso se non c'è: cancellare ciò che non esiste è già fatto.
    public func removeSnapshot(_ snapshotID: UUID, for examID: UUID) {
        try? FileManager.default.removeItem(
            at: snapshotsDirectory(for: examID)
                .appendingPathComponent(snapshotID.uuidString + ".png"))
    }

    /// Gli identificatori delle istantanee presenti sul disco per un esame.
    ///
    /// Dal **disco** e non da un elenco conservato: le due cose divergerebbero appena una
    /// scrittura si interrompe, e i file sono la verità. Ordinati per nome, che con degli UUID
    /// non significa niente — l'ordine che conta lo tiene il piano, che è dove l'utente le ha
    /// messe in fila.
    public func snapshotIdentifiers(for examID: UUID) -> [UUID] {
        let folder = snapshotsDirectory(for: examID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".png") else { return nil }
            return UUID(uuidString: String(name.dropLast(4)))
        }.sorted { $0.uuidString < $1.uuidString }
    }

    /// La scansione salvata con l'esame, se c'è.
    public func loadScan(id: UUID) -> Data? {
        try? Data(contentsOf: directory(for: id).appendingPathComponent(Self.scanName))
    }

    /// Aggiorna la nota di un esame, senza toccarne i dati.
    public func setNote(_ note: String, for id: UUID) throws {
        var index = try loadIndex()
        guard let position = index.entries.firstIndex(where: { $0.id == id }) else {
            throw ArchiveError.entryNotFound(id)
        }
        index.entries[position].note = note
        try save(index)
        try? JSONEncoder.archive.encode(index.entries[position]).write(
            to: directory(for: id).appendingPathComponent(Self.examName), options: .atomic)
    }

    // MARK: Riaprire

    public func loadVolume(id: UUID) throws -> Volume {
        let folder = directory(for: id)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw ArchiveError.entryNotFound(id)
        }
        return try VolumeFile.read(from: folder)
    }

    /// Il piano salvato con l'esame, se c'è.
    public func loadPlan(id: UUID) -> Data? {
        try? Data(contentsOf: directory(for: id).appendingPathComponent(Self.planName))
    }

    // MARK: Cancellare

    /// Toglie un esame dall'archivio, dati compresi.
    ///
    /// Prima l'indice, poi la cartella: è l'ordine inverso a quello dell'archiviazione, e per la
    /// stessa ragione. Fallendo in mezzo resta una cartella orfana, che è invisibile e
    /// innocua; nell'ordine opposto resterebbe una riga che non si apre.
    public func remove(id: UUID) throws {
        var index = try loadIndex()
        let before = index.entries.count
        index.entries.removeAll { $0.id == id }
        guard index.entries.count < before else { throw ArchiveError.entryNotFound(id) }
        try save(index)
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    // MARK: Interrogare

    /// I pazienti, ciascuno con i suoi esami dal più recente, ordinati per esame più recente.
    public func patients(in index: ArchiveIndex) -> [ArchivedPatient] {
        var groups: [String: [ArchiveEntry]] = [:]
        for entry in index.entries {
            groups[entry.patientKey, default: []].append(entry)
        }

        var result: [ArchivedPatient] = []
        for (key, entries) in groups {
            let ordered = entries.sorted { left, right in
                left.chronologicalKey == right.chronologicalKey
                    ? left.storedAt > right.storedAt
                    : left.chronologicalKey > right.chronologicalKey
            }
            // L'identità la dà l'esame più recente: se un nome è stato corretto in una
            // acquisizione successiva, è quella la versione buona.
            guard let newest = ordered.first else { continue }
            result.append(ArchivedPatient(id: key, identity: newest.patient, entries: ordered))
        }

        return result.sorted { left, right in
            left.mostRecentKey == right.mostRecentKey
                ? left.identity.displayName.localizedCompare(right.identity.displayName) == .orderedAscending
                : left.mostRecentKey > right.mostRecentKey
        }
    }

    /// Filtra i pazienti su un testo libero: nome, identificativo, data, descrizione, macchina.
    ///
    /// Un paziente compare se **lui** corrisponde, con tutti i suoi esami; oppure se
    /// corrisponde qualche suo esame, e allora con i soli esami che corrispondono. È la
    /// differenza fra cercare una persona e cercare un esame, e in una casella sola devono
    /// stare tutt'e due.
    public func search(_ text: String, in patients: [ArchivedPatient]) -> [ArchivedPatient] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return patients }

        var result: [ArchivedPatient] = []
        for patient in patients {
            if patient.identity.matches(needle) {
                result.append(patient)
                continue
            }
            let hits = patient.entries.filter { $0.matches(needle) }
            if !hits.isEmpty {
                result.append(
                    ArchivedPatient(id: patient.id, identity: patient.identity, entries: hits))
            }
        }
        return result
    }

    /// Byte occupati da tutti gli esami, secondo l'indice.
    public func totalBytes(in index: ArchiveIndex) -> Int {
        index.entries.reduce(0) { $0 + $1.volumeBytes }
    }

    // MARK: Ricostruzione

    /// Ricostruisce l'indice leggendo le cartelle degli esami.
    ///
    /// Serve quando indice e cartelle divergono: una scrittura interrotta, un `archivio.json`
    /// cancellato, una cartella copiata a mano da un altro Mac. Le cartelle sono la verità —
    /// contengono i dati — e l'indice è solo una comodità, quindi la ricostruzione va in questo
    /// verso e mai nell'altro.
    ///
    /// - Returns: l'indice ricostruito, già salvato.
    @discardableResult
    public func rebuildIndex() throws -> ArchiveIndex {
        try createFolders()
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(
            at: examsURL, includingPropertiesForKeys: nil)) ?? []

        var entries: [ArchiveEntry] = []
        for folder in folders {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { continue }
            guard
                let data = try? Data(contentsOf: folder.appendingPathComponent(Self.examName)),
                var entry = try? JSONDecoder.archive.decode(ArchiveEntry.self, from: data)
            else { continue }
            // Una cartella senza campioni è un'archiviazione interrotta: non entra nell'indice,
            // perché elencarla darebbe una riga che non si apre.
            guard manager.fileExists(
                atPath: folder.appendingPathComponent(VolumeFile.samplesName).path)
            else { continue }
            entry.hasPlan = manager.fileExists(
                atPath: folder.appendingPathComponent(Self.planName).path)
            entry.hasScan = manager.fileExists(
                atPath: folder.appendingPathComponent(Self.scanName).path)
            entries.append(entry)
        }

        let index = ArchiveIndex(entries: entries)
        try save(index)
        return index
    }
}

// MARK: - Corrispondenze

extension ArchiveEntry {
    /// Due voci sono lo stesso esame quando lo sono le due serie DICOM.
    ///
    /// Con gli UID quando ci sono: sono universalmente unici per definizione. Senza — capita su
    /// export anonimizzati che li rigenerano o li tolgono — si ripiega su paziente, data e
    /// dimensioni, che insieme sbagliano di rado; e sbagliando lasciano due copie, che è il
    /// verso meno dannoso dell'errore.
    public func matches(exam other: ExamMetadata) -> Bool {
        if !exam.seriesInstanceUID.isEmpty, !other.seriesInstanceUID.isEmpty {
            return exam.seriesInstanceUID == other.seriesInstanceUID
                && exam.studyInstanceUID == other.studyInstanceUID
        }
        return exam.studyDate == other.studyDate
            && exam.studyTime == other.studyTime
            && exam.seriesDescription == other.seriesDescription
            && exam.columnCount == other.columnCount
            && exam.rowCount == other.rowCount
            && exam.sliceCount == other.sliceCount
    }

    /// Corrispondenza con un testo di ricerca già ridotto a minuscolo.
    public func matches(_ needle: String) -> Bool {
        let haystack = [
            exam.studyDescription, exam.seriesDescription, exam.protocolName,
            exam.manufacturer, exam.modelName, exam.stationName, exam.institutionName,
            exam.modality, note,
            DICOMDate.displayShort(exam.studyDate) ?? "",
            DICOMDate.display(exam.studyDate) ?? "",
            exam.studyDate,
        ]
        return haystack.contains { $0.lowercased().contains(needle) }
    }
}

extension PatientIdentity {
    /// Corrispondenza con un testo di ricerca già ridotto a minuscolo.
    public func matches(_ needle: String) -> Bool {
        let haystack = [
            displayName, name, patientID, birthDate,
            DICOMDate.displayShort(birthDate) ?? "",
        ]
        return haystack.contains { $0.lowercased().contains(needle) }
    }
}

// MARK: - Codifica

extension JSONEncoder {
    /// Ordinato e indentato: un archivio deve restare leggibile a occhio fra dieci anni anche
    /// senza questo software.
    fileprivate static var archive: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var archive: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
