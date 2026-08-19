import DICOMCore
import Foundation
import Testing

@testable import ArchiveKit

// L'archivio.
//
// Le prove che contano più delle altre sono due, e riguardano entrambe **chi finisce sotto chi**:
// che due esami dello stesso paziente si ritrovino insieme, e che due esami anonimi di persone
// diverse non si ritrovino insieme. Un archivio che sbaglia il primo è scomodo; uno che sbaglia
// il secondo mette due pazienti nella stessa cartella clinica, e non c'è modo di accorgersene
// guardando l'elenco.

@Suite("Archivio dei pazienti")
struct PatientArchiveTests {

    private func makeArchive() throws -> PatientArchive {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("archivio-" + UUID().uuidString)
        return PatientArchive(rootURL: url)
    }

    private func tinyVolume(slices: Int = 2) throws -> Volume {
        let geometry = try VolumeGeometry(
            columnCount: 3, rowCount: 3, sliceCount: slices,
            columnSpacingMM: 0.2, rowSpacingMM: 0.2, sliceSpacingMM: 0.2,
            orientation: .standardAxial, originMM: .zero)
        return try Volume(
            geometry: geometry,
            samples: [Int16](repeating: 700, count: geometry.voxelCount))
    }

    private func exam(
        series: String = "1.2.3.4", study: String = "1.2.3", date: String = "20260817",
        time: String = "101500", description: String = "CBCT mascellare"
    ) -> ExamMetadata {
        ExamMetadata(
            studyInstanceUID: study, seriesInstanceUID: series,
            studyDate: date, studyTime: time,
            seriesDescription: description,
            modality: "CT", manufacturer: "Carestream", modelName: "CS 9600",
            kvp: 90, tubeCurrentMA: 6.3)
    }

    // MARK: Andata e ritorno

    @Test("Un esame archiviato si riapre, volume compreso")
    func storeAndReopen() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.rootURL) }

        let volume = try tinyVolume()
        let entry = try archive.store(
            volume: volume,
            patient: PatientIdentity(patientID: "P1", name: "Rossi^Mario", birthDate: "19800101"),
            exam: exam(),
            sourcePath: "/Volumi/CBCT/Rossi")

        #expect(entry.volumeBytes == volume.samples.count * 2)
        #expect(entry.exam.sliceCount == 2, "le dimensioni si prendono dalla geometria")
        #expect(entry.sourcePath == "/Volumi/CBCT/Rossi")

        let reread = try archive.loadVolume(id: entry.id)
        #expect(reread.samples == volume.samples)

        let index = try archive.loadIndex()
        #expect(index.entries.count == 1)
    }

    @Test("Un archivio che non esiste ancora è vuoto, non un errore")
    func missingArchiveIsEmpty() throws {
        let archive = try makeArchive()
        let index = try archive.loadIndex()
        #expect(index.entries.isEmpty)
    }

    // MARK: Chi finisce sotto chi

    @Test("Due esami dello stesso paziente stanno sotto lo stesso paziente")
    func sameIdentifierGroups() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.rootURL) }

        let identity = PatientIdentity(patientID: "P1", name: "Rossi^Mario", birthDate: "19800101")
        try archive.store(
            volume: try tinyVolume(), patient: identity,
            exam: exam(series: "S1", date: "20250310"))
        try archive.store(
            volume: try tinyVolume(), patient: identity,
            exam: exam(series: "S2", date: "20260817"))

        let patients = archive.patients(in: try archive.loadIndex())
        #expect(patients.count == 1)
        #expect(patients[0].entries.count == 2)
        // Dal più recente: è l'ordine in cui si cerca un esame.
        #expect(patients[0].entries[0].exam.studyDate == "20260817")
    }

    @Test("Senza identificativo bastano nome e data di nascita")
    func nameAndBirthDateGroup() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.rootURL) }

        let identity = PatientIdentity(name: "Bianchi^Anna", birthDate: "19751122")
        try archive.store(
            volume: try tinyVolume(), patient: identity, exam: exam(series: "S1"))
        try archive.store(
            volume: try tinyVolume(), patient: identity, exam: exam(series: "S2"))

        #expect(archive.patients(in: try archive.loadIndex()).count == 1)
    }

    @Test("Due esami anonimi restano due pazienti distinti")
    func anonymousExamsStaySeparate() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.rootURL) }

        // Nessun identificativo, nessun nome, nessuna data di nascita: due persone diverse che
        // il file non distingue. Metterle insieme sarebbe il guasto peggiore dell'archivio.
        let anonymous = PatientIdentity()
        #expect(anonymous.isAnonymous)

        try archive.store(volume: try tinyVolume(), patient: anonymous, exam: exam(series: "S1"))
        try archive.store(volume: try tinyVolume(), patient: anonymous, exam: exam(series: "S2"))

        let patients = archive.patients(in: try archive.loadIndex())
        #expect(patients.count == 2, "due anonimi non sono la stessa persona")
    }

    @Test("Correggere il nome non sposta gli esami sotto un altro paziente")
    func keyIsStableAcrossRenames() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.rootURL) }

        let anonymous = PatientIdentity()
        let first = try archive.store(
            volume: try tinyVolume(), patient: anonymous, exam: exam(series: "S1"))

        // Lo stesso esame riarchiviato, stavolta con un nome: deve restare la stessa voce e lo
        // stesso paziente, non comparirne uno nuovo accanto al vecchio.
        let named = PatientIdentity(name: "Verdi^Luca", birthDate: "19900505")
        let second = try archive.store(
            volume: try tinyVolume(), patient: named, exam: exam(series: "S1"))

        #expect(first.id == second.id)
        #expect(first.patientKey == second.patientKey)
        let patients = archive.patients(in: try archive.loadIndex())
        #expect(patients.count == 1)
        #expect(patients[0].identity.displayName == "Luca Verdi")
    }

    // MARK: Doppioni

    @Test("Riaprire e riarchiviare la stessa serie sostituisce invece di duplicare")
    func reArchivingReplaces() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.rootURL) }

        let identity = PatientIdentity(patientID: "P1")
        let first = try archive.store(
            volume: try tinyVolume(slices: 2), patient: identity, exam: exam())
        let second = try archive.store(
            volume: try tinyVolume(slices: 4), patient: identity, exam: exam())

        #expect(first.id == second.id)
        let index = try archive.loadIndex()
        #expect(index.entries.count == 1)
        // E i dati sono quelli nuovi, non i vecchi.
        #expect(try archive.loadVolume(id: second.id).geometry.sliceCount == 4)
    }

    @Test("Serie diverse dello stesso studio restano esami distinti")
    func differentSeriesStayDistinct() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.rootURL) }

        let identity = PatientIdentity(patientID: "P1")
        try archive.store(volume: try tinyVolume(), patient: identity, exam: exam(series: "S1"))
        try archive.store(volume: try tinyVolume(), patient: identity, exam: exam(series: "S2"))
        #expect(try archive.loadIndex().entries.count == 2)
    }

    @Test("Senza UID si ripiega su data, ora e dimensioni")
    func withoutUIDsFallsBackToFacts() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.rootURL) }

        let identity = PatientIdentity(patientID: "P1")
        let anonymised = exam(series: "", study: "")
        try archive.store(volume: try tinyVolume(), patient: identity, exam: anonymised)
        try archive.store(volume: try tinyVolume(), patient: identity, exam: anonymised)
        #expect(try archive.loadIndex().entries.count == 1, "stessa acquisizione, una voce sola")

        // Un'ora diversa è un'altra acquisizione.
        try archive.store(
            volume: try tinyVolume(), patient: identity,
            exam: exam(series: "", study: "", time: "143000"))
        #expect(try archive.loadIndex().entries.count == 2)
    }

    // MARK: Il piano

    @Test("Il piano viaggia con l'esame, e riarchiviare senza toglie quello vecchio")
    func planTravelsWithTheExam() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.rootURL) }

        let identity = PatientIdentity(patientID: "P1")
        let plan = Data("{\"misure\":3}".utf8)
        let stored = try archive.store(
            volume: try tinyVolume(), patient: identity, exam: exam(), plan: plan)

        #expect(stored.hasPlan)
        #expect(archive.loadPlan(id: stored.id) == plan)

        // Riarchiviando senza piano, quello vecchio non deve sopravvivere: riaprire l'esame e
        // ritrovare un piano che si credeva rimosso è peggio che non averlo salvato.
        let again = try archive.store(
            volume: try tinyVolume(), patient: identity, exam: exam(), plan: nil)
        #expect(!again.hasPlan)
        #expect(archive.loadPlan(id: again.id) == nil)
    }

    // MARK: Cancellazione

    @Test("Cancellare toglie la voce e i dati")
    func removeDeletesEverything() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.rootURL) }

        let entry = try archive.store(
            volume: try tinyVolume(), patient: PatientIdentity(patientID: "P1"), exam: exam())
        let folder = archive.directory(for: entry.id)
        #expect(FileManager.default.fileExists(atPath: folder.path))

        try archive.remove(id: entry.id)
        #expect(try archive.loadIndex().entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(throws: ArchiveError.self) { _ = try archive.loadVolume(id: entry.id) }
    }

    @Test("Cancellare due volte lo dice invece di tacere")
    func removingTwiceThrows() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.rootURL) }

        let entry = try archive.store(
            volume: try tinyVolume(), patient: PatientIdentity(patientID: "P1"), exam: exam())
        try archive.remove(id: entry.id)
        #expect(throws: ArchiveError.self) { try archive.remove(id: entry.id) }
    }

    // MARK: Ricerca

    @Test("La ricerca trova la persona con tutti i suoi esami, e l'esame da solo")
    func searchFindsBoth() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.rootURL) }

        let mario = PatientIdentity(patientID: "P1", name: "Rossi^Mario", birthDate: "19800101")
        try archive.store(
            volume: try tinyVolume(), patient: mario,
            exam: exam(series: "S1", date: "20250310", description: "CBCT mascellare"))
        try archive.store(
            volume: try tinyVolume(), patient: mario,
            exam: exam(series: "S2", date: "20260817", description: "CBCT mandibola"))
        try archive.store(
            volume: try tinyVolume(),
            patient: PatientIdentity(patientID: "P2", name: "Bianchi^Anna"),
            exam: exam(series: "S3", date: "20260101", description: "CBCT mascellare"))

        let patients = archive.patients(in: try archive.loadIndex())
        #expect(patients.count == 2, "tre esami, ma Rossi ne ha due")

        // Cercando la persona: tutti i suoi esami.
        let byName = archive.search("rossi", in: patients)
        #expect(byName.count == 1)
        #expect(byName[0].entries.count == 2)

        // Cercando l'esame: solo quelli che corrispondono, e di chiunque siano.
        let byExam = archive.search("mandibola", in: patients)
        #expect(byExam.count == 1)
        #expect(byExam[0].entries.count == 1)

        let shared = archive.search("mascellare", in: patients)
        #expect(shared.count == 2)
        #expect(shared.allSatisfy { $0.entries.count == 1 })

        // Una data si cerca come la si legge.
        #expect(archive.search("17/08/2026", in: patients).count == 1)

        // E un testo vuoto non filtra niente.
        #expect(archive.search("   ", in: patients).count == 2)
    }

    // MARK: Ricostruzione

    @Test("L'indice si ricostruisce dalle cartelle, che sono la verità")
    func indexRebuildsFromFolders() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.rootURL) }

        let identity = PatientIdentity(patientID: "P1", name: "Rossi^Mario")
        let first = try archive.store(
            volume: try tinyVolume(), patient: identity, exam: exam(series: "S1"))
        try archive.store(volume: try tinyVolume(), patient: identity, exam: exam(series: "S2"))

        // Un `archivio.json` perso: i dati ci sono ancora, e devono tornare.
        try FileManager.default.removeItem(at: archive.indexURL)
        #expect(try archive.loadIndex().entries.isEmpty)

        let rebuilt = try archive.rebuildIndex()
        #expect(rebuilt.entries.count == 2)
        #expect(rebuilt.entries.contains { $0.id == first.id })
        #expect(try archive.loadVolume(id: first.id).geometry.sliceCount == 2)
    }

    @Test("Un'archiviazione interrotta non entra nell'indice ricostruito")
    func halfWrittenFolderIsSkipped() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.rootURL) }

        let entry = try archive.store(
            volume: try tinyVolume(), patient: PatientIdentity(patientID: "P1"), exam: exam())

        // Si toglie il file dei campioni, come se la scrittura fosse morta a metà. La voce
        // resta descritta, ma non si può aprire: elencarla darebbe una riga che non funziona.
        try FileManager.default.removeItem(
            at: archive.directory(for: entry.id).appendingPathComponent(VolumeFile.samplesName))

        #expect(try archive.rebuildIndex().entries.isEmpty)
    }

    // MARK: Note

    @Test("La nota si scrive e sopravvive alla ricostruzione")
    func noteSurvives() throws {
        let archive = try makeArchive()
        defer { try? FileManager.default.removeItem(at: archive.rootURL) }

        let entry = try archive.store(
            volume: try tinyVolume(), patient: PatientIdentity(patientID: "P1"), exam: exam())
        try archive.setNote("Controllare il 46 prima di pianificare", for: entry.id)

        #expect(try archive.loadIndex().entries[0].note.contains("46"))
        #expect(try archive.rebuildIndex().entries[0].note.contains("46"))

        // E riarchiviare lo stesso esame non la cancella: la nota è dell'utente, il volume no.
        try archive.store(
            volume: try tinyVolume(), patient: PatientIdentity(patientID: "P1"), exam: exam())
        #expect(try archive.loadIndex().entries[0].note.contains("46"))
    }
}
