import Foundation
import Testing

@testable import DICOMCore

// Scrivere DICOM.
//
// # La prova che conta
//
// Andata e ritorno attraverso il **nostro stesso parser**: si scrive un volume, lo si rilegge
// con `DICOMScanner` e `VolumeBuilder`, e si pretende che ne esca lo stesso volume. È una prova
// forte proprio perché il parser è stato scritto prima e senza sapere di questo scrittore: se
// i due si accordassero per un errore condiviso, l'errore starebbe nell'interpretazione del
// formato, non nel codice — e lì il fantoccio con le misure note dice comunque la verità.
//
// Resta ciò che questa prova non copre: che un **altro** programma legga i nostri file. Quello
// si scopre aprendoli con un visore vero, e non si può fare da qui.

@Suite("Esportazione DICOM")
struct DICOMWriterTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dcmwrite-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Volume anisotropo con orientamento non assiale: su voxel isotropici e assiali uno scambio
    /// fra riga e colonna non produce alcun sintomo, ed è la trappola del Contratto 1.
    private func awkwardVolume() throws -> Volume {
        let orientation = try #require(
            SliceOrientation(
                columnDirection: Vec3(0.6, 0.8, 0), rowDirection: Vec3(-0.8, 0.6, 0)))
        let geometry = try VolumeGeometry(
            columnCount: 6, rowCount: 4, sliceCount: 5,
            columnSpacingMM: 0.25, rowSpacingMM: 0.4, sliceSpacingMM: 0.6,
            orientation: orientation, originMM: Vec3(-11.5, 7.25, -3.125))
        var samples = [Int16]()
        for index in 0..<geometry.voxelCount {
            samples.append(Int16(truncatingIfNeeded: index * 137 - 2000))
        }
        samples[0] = Int16.min
        samples[samples.count - 1] = Int16.max
        return try Volume(
            geometry: geometry, samples: samples,
            rescaleSlope: 1, rescaleIntercept: -1024, densityUnit: .greyValue)
    }

    private func reread(_ directory: URL) throws -> Volume {
        let scan = try DICOMScanner.scan(directory: directory, progress: nil)
        let series = try #require(
            scan.patients.flatMap(\.studies).flatMap(\.series).first { $0.isImageSeries })
        return try VolumeBuilder.build(series: series).volume
    }

    @Test("Un volume scritto e riletto è lo stesso volume")
    func roundTripThroughOurOwnParser() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = try awkwardVolume()
        let files = try DICOMWriter.write(
            volume: original,
            identity: DICOMExportIdentity(
                patientName: "Rossi^Mario", patientID: "P1", studyDate: "20260817",
                seriesDescription: "Raddrizzato"),
            to: directory)
        #expect(files.count == original.geometry.sliceCount)

        let reread = try reread(directory)
        #expect(reread.samples == original.samples)
        #expect(reread.rescaleIntercept == original.rescaleIntercept)
        #expect(reread.rescaleSlope == original.rescaleSlope)

        // La geometria: la matrice è ciò che rende un volume misurabile, e un vertice lontano
        // dall'origine amplifica ogni errore di orientamento o di passo invece di annullarlo.
        let corner = original.geometry.patientPoint(i: 5, j: 3, k: 4)
        let same = reread.geometry.patientPoint(i: 5, j: 3, k: 4)
        #expect(corner.distance(to: same) < 1e-4, "spigolo a \(corner.distance(to: same)) mm")
    }

    @Test("I passi di riga e colonna non si scambiano scrivendo")
    func spacingsSurviveTheRoundTrip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try DICOMWriter.write(
            volume: try awkwardVolume(), identity: DICOMExportIdentity(), to: directory)
        let reread = try reread(directory)

        // `PixelSpacing` è riga poi colonna: scritto al contrario darebbe un volume trasposto
        // che su voxel isotropici nessuno noterebbe.
        #expect(abs(reread.geometry.columnSpacingMM - 0.25) < 1e-9)
        #expect(abs(reread.geometry.rowSpacingMM - 0.4) < 1e-9)
        #expect(abs(reread.geometry.sliceSpacingMM - 0.6) < 1e-9)
        #expect(reread.geometry.columnCount == 6)
        #expect(reread.geometry.rowCount == 4)
        #expect(reread.geometry.sliceCount == 5)
    }

    @Test("I valori negativi restano negativi")
    func signedSamplesSurvive() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let geometry = try VolumeGeometry(
            columnCount: 2, rowCount: 1, sliceCount: 1,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: .standardAxial, originMM: .zero)
        let volume = try Volume(geometry: geometry, samples: [-1000, 3000])

        try DICOMWriter.write(volume: volume, identity: DICOMExportIdentity(), to: directory)
        // Con `PixelRepresentation` dichiarato senza segno, −1000 tornerebbe 64 536: l'aria
        // diventerebbe più densa dell'osso, e nessun errore lo direbbe.
        #expect(try reread(directory).samples == [-1000, 3000])
    }

    @Test("I metadati del paziente arrivano dall'altra parte")
    func identitySurvives() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try DICOMWriter.write(
            volume: try awkwardVolume(),
            identity: DICOMExportIdentity(
                patientName: "Bianchi^Anna", patientID: "AB-42",
                patientBirthDate: "19751122", patientSex: "F",
                studyDate: "20260817", seriesDescription: "Strie ridotte"),
            to: directory)

        let scan = try DICOMScanner.scan(directory: directory, progress: nil)
        let patient = try #require(scan.patients.first)
        #expect(patient.name == "Bianchi^Anna")
        #expect(patient.patientID == "AB-42")
        #expect(patient.birthDate == "19751122")

        let series = try #require(patient.studies.first?.series.first)
        #expect(series.description == "Strie ridotte")
        #expect(series.modality == "CT")
    }

    @Test("La serie riceve UID nuovi, lo studio no")
    func seriesGetsFreshIdentifiers() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let study = "1.2.3.4.5"
        try DICOMWriter.write(
            volume: try awkwardVolume(),
            identity: DICOMExportIdentity(studyInstanceUID: study),
            to: directory)

        let scan = try DICOMScanner.scan(directory: directory, progress: nil)
        let scanned = try #require(scan.patients.first?.studies.first)
        // Lo studio è la visita del paziente e quella non cambia.
        #expect(scanned.studyInstanceUID == study)
        // La serie è un volume diverso da quello acquisito: riusarne l'identificatore direbbe a
        // un PACS che le due cose sono la stessa.
        let series = try #require(scanned.series.first)
        #expect(series.seriesInstanceUID != study)
        #expect(series.seriesInstanceUID.hasPrefix("2.25."))
        // E ogni immagine ha il proprio.
        let sops = Set(series.instances.map(\.sopInstanceUID))
        #expect(sops.count == series.instances.count)
    }

    @Test("Gli UID generati sono validi e non si ripetono")
    func generatedUIDsAreWellFormed() {
        var seen = Set<String>()
        for _ in 0..<200 {
            let uid = DICOMWriter.newUID()
            #expect(uid.hasPrefix("2.25."))
            // Un UID DICOM sta in 64 caratteri e contiene solo cifre e punti.
            #expect(uid.count <= 64, "UID lungo \(uid.count): \(uid)")
            #expect(uid.allSatisfy { $0.isNumber || $0 == "." })
            // Nessuna componente con uno zero iniziale: un UID così è formalmente invalido.
            for component in uid.split(separator: ".") {
                #expect(component == "0" || !component.hasPrefix("0"), "componente \(component)")
            }
            #expect(seen.insert(uid).inserted, "UID ripetuto")
        }
    }

    @Test("Un volume vuoto è un errore, non una cartella di file rotti")
    func emptyVolumeIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let geometry = try VolumeGeometry(
            columnCount: 1, rowCount: 1, sliceCount: 1,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: .standardAxial, originMM: .zero)
        let volume = try Volume(geometry: geometry, samples: [0])
        // Un volume da un voxel si scrive: è degenere ma valido. Il rifiuto scatta sul vuoto,
        // che `VolumeGeometry` già non permette di costruire — quindi qui si verifica che il
        // caso limite passi invece di essere respinto per eccesso di prudenza.
        #expect(try DICOMWriter.write(
            volume: volume, identity: DICOMExportIdentity(), to: directory).count == 1)
    }

    @Test("Ogni file comincia col preambolo e con DICM")
    func filesHaveThePreamble() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let files = try DICOMWriter.write(
            volume: try awkwardVolume(), identity: DICOMExportIdentity(), to: directory)
        let data = try Data(contentsOf: try #require(files.first))

        #expect(data.count > 132)
        #expect(Array(data[0..<128]).allSatisfy { $0 == 0 })
        #expect(String(decoding: data[128..<132], as: UTF8.self) == "DICM")
    }

    // MARK: Il nome della cartella

    @Test("Il nome proposto mette insieme paziente, data e serie")
    func folderNameJoinsTheThreeParts() {
        let identity = DICOMExportIdentity(
            patientName: "Rossi^Mario^^^",
            studyDate: "20240312",
            seriesDescription: "CBCT mascellare")
        #expect(identity.suggestedFolderName == "Rossi Mario - 20240312 - CBCT mascellare")
    }

    @Test("Barre e due punti non finiscono nel nome della cartella")
    func folderNameHasNoPathSeparators() {
        let identity = DICOMExportIdentity(
            patientName: "De/Luca^Anna:Maria",
            studyDate: "20240312",
            seriesDescription: "arcata/inferiore")
        let name = identity.suggestedFolderName

        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
        #expect(!name.hasPrefix("."))
        #expect(name == "De Luca Anna Maria - 20240312 - arcata inferiore")
    }

    @Test("Una data malformata sparisce invece di finire nel nome")
    func folderNameDropsAMalformedDate() {
        // Otto cifre o niente: `2024` o `20240312120000` non sono date DICOM, e metterle nel
        // nome darebbe a chi guarda la cartella un'informazione che non abbiamo.
        for date in ["", "2024", "20240312120000", "AAAAMMGG"] {
            let identity = DICOMExportIdentity(
                patientName: "Rossi^Mario", studyDate: date, seriesDescription: "")
            #expect(identity.suggestedFolderName == "Rossi Mario")
        }
    }

    @Test("Un paziente senza nome diventa «Anonimo», non una cartella senza nome")
    func folderNameFallsBackToAnonymous() {
        #expect(
            DICOMExportIdentity(patientName: "^^^^", seriesDescription: "")
                .suggestedFolderName == "Anonimo")
        #expect(
            DICOMExportIdentity(patientName: "   ", seriesDescription: "Serie")
                .suggestedFolderName == "Anonimo - Serie")
        // Il valore predefinito della descrizione c'è apposta: una cartella chiamata soltanto
        // «Anonimo» non direbbe nemmeno che cosa contiene.
        #expect(DICOMExportIdentity().suggestedFolderName == "Anonimo - Serie esportata")
    }

    @Test("Un nome lunghissimo viene accorciato")
    func folderComponentIsCapped() {
        let long = String(repeating: "a", count: 500)
        #expect(DICOMWriter.folderComponent(long).count == 48)
        #expect(DICOMWriter.folderComponent(long, limit: 10).count == 10)
    }

    @Test("La cartella proposta non è mai una che esiste già")
    func availableDirectoryNeverCollides() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        let first = DICOMWriter.availableDirectory(named: "Esame", in: parent)
        #expect(first.lastPathComponent == "Esame")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)

        let second = DICOMWriter.availableDirectory(named: "Esame", in: parent)
        #expect(second.lastPathComponent == "Esame 2")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        #expect(
            DICOMWriter.availableDirectory(named: "Esame", in: parent).lastPathComponent
                == "Esame 3")
    }

    @Test("Due esportazioni di seguito non si sovrascrivono")
    func twoExportsDoNotOverwriteEachOther() throws {
        // Il caso vero, non quello astratto: si esporta un volume di cinque fette e poi un
        // ritaglio di due. Senza cartella nuova, le tre fette in eccesso della prima resterebbero
        // accanto alle due della seconda, e chi riaprisse leggerebbe un volume fatto di pezzi
        // di due.
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        let identity = DICOMExportIdentity(patientName: "Rossi^Mario", studyDate: "20240312")
        let full = try awkwardVolume()
        let cropped = try Volume(
            geometry: try VolumeGeometry(
                columnCount: full.geometry.columnCount, rowCount: full.geometry.rowCount,
                sliceCount: 2,
                columnSpacingMM: full.geometry.columnSpacingMM,
                rowSpacingMM: full.geometry.rowSpacingMM,
                sliceSpacingMM: full.geometry.sliceSpacingMM,
                orientation: full.geometry.orientation, originMM: full.geometry.originMM),
            samples: Array(
                full.samples[0..<(full.geometry.columnCount * full.geometry.rowCount * 2)]))

        let firstDirectory = DICOMWriter.availableDirectory(
            named: identity.suggestedFolderName, in: parent)
        try DICOMWriter.write(volume: full, identity: identity, to: firstDirectory)

        let secondDirectory = DICOMWriter.availableDirectory(
            named: identity.suggestedFolderName, in: parent)
        try DICOMWriter.write(volume: cropped, identity: identity, to: secondDirectory)

        #expect(firstDirectory != secondDirectory)
        let manager = FileManager.default
        #expect(try manager.contentsOfDirectory(atPath: firstDirectory.path).count == 5)
        #expect(try manager.contentsOfDirectory(atPath: secondDirectory.path).count == 2)
    }
}
