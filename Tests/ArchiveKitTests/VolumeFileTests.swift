import DICOMCore
import Foundation
import Testing

@testable import ArchiveKit

// Il volume su disco.
//
// La prova che conta è l'andata e ritorno: un volume scritto e riletto deve essere lo stesso
// volume, campione per campione e millimetro per millimetro. Un errore qui non dà un messaggio
// — dà un'anatomia leggermente spostata, che è la forma di guasto peggiore per un archivio,
// perché si scopre misurando.

@Suite("Volume archiviato")
struct VolumeFileTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("volumefile-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Volume piccolo e **anisotropo**, con orientamento non assiale e campioni tutti diversi.
    ///
    /// Anisotropo di proposito: su voxel isotropici uno scambio fra passo di riga e di colonna
    /// non produce alcun sintomo, ed è la trappola più insidiosa dell'intero formato.
    private func awkwardVolume() throws -> Volume {
        let orientation = try #require(
            SliceOrientation(
                columnDirection: Vec3(0.6, 0.8, 0),
                rowDirection: Vec3(-0.8, 0.6, 0)))
        let geometry = try VolumeGeometry(
            columnCount: 5, rowCount: 4, sliceCount: 3,
            columnSpacingMM: 0.25, rowSpacingMM: 0.4, sliceSpacingMM: 0.6,
            orientation: orientation,
            originMM: Vec3(-11.5, 7.25, -3.125))
        // Valori distinti, con negativi e con gli estremi di Int16.
        var samples = [Int16]()
        for index in 0..<geometry.voxelCount {
            samples.append(Int16(truncatingIfNeeded: index * 37 - 1000))
        }
        samples[0] = Int16.min
        samples[samples.count - 1] = Int16.max
        return try Volume(
            geometry: geometry, samples: samples,
            rescaleSlope: 1.5, rescaleIntercept: -1024, densityUnit: .greyValue)
    }

    @Test("Un volume scritto e riletto è lo stesso volume")
    func roundTripPreservesEverything() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = try awkwardVolume()
        try VolumeFile.write(original, to: directory)
        let reread = try VolumeFile.read(from: directory)

        #expect(reread.samples == original.samples)
        #expect(reread.geometry == original.geometry)
        #expect(reread.rescaleSlope == original.rescaleSlope)
        #expect(reread.rescaleIntercept == original.rescaleIntercept)
        #expect(reread.densityUnit == original.densityUnit)

        // La matrice è la cosa che conta davvero: un voxel deve tornare negli stessi
        // millimetri. Si prova su un vertice lontano dall'origine, dove un errore di
        // orientamento o di passo si amplifica invece di annullarsi.
        let corner = original.geometry.patientPoint(i: 4, j: 3, k: 2)
        let same = reread.geometry.patientPoint(i: 4, j: 3, k: 2)
        #expect(corner.distance(to: same) < 1e-12)
    }

    @Test("I passi di riga e colonna non si scambiano")
    func spacingsDoNotSwap() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = try awkwardVolume()
        try VolumeFile.write(original, to: directory)
        let reread = try VolumeFile.read(from: directory)

        #expect(reread.geometry.columnSpacingMM == 0.25)
        #expect(reread.geometry.rowSpacingMM == 0.4)
        #expect(reread.geometry.sliceSpacingMM == 0.6)
    }

    @Test("I byte sono little-endian, dichiarati e non assunti")
    func byteOrderIsExplicit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let geometry = try VolumeGeometry(
            columnCount: 2, rowCount: 1, sliceCount: 1,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: .standardAxial, originMM: .zero)
        // 0x0102 e −2: il primo distingue i due ordini, il secondo prova il segno.
        let volume = try Volume(geometry: geometry, samples: [0x0102, -2])
        try VolumeFile.write(volume, to: directory)

        let raw = try Data(contentsOf: directory.appendingPathComponent(VolumeFile.samplesName))
        #expect(raw.count == 4)
        #expect(Array(raw) == [0x02, 0x01, 0xFE, 0xFF])

        let header = try JSONDecoder().decode(
            VolumeFileHeader.self,
            from: Data(contentsOf: directory.appendingPathComponent(VolumeFile.headerName)))
        #expect(header.byteOrder == "little")
    }

    @Test("Un file troncato è un errore che si spiega, non un volume di rumore")
    func truncatedFileIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = try awkwardVolume()
        try VolumeFile.write(original, to: directory)

        // Si tagliano gli ultimi dieci campioni, come farebbe un disco pieno a metà scrittura.
        let samplesURL = directory.appendingPathComponent(VolumeFile.samplesName)
        let full = try Data(contentsOf: samplesURL)
        try full.prefix(full.count - 20).write(to: samplesURL)

        #expect(throws: VolumeFileError.self) {
            _ = try VolumeFile.read(from: directory)
        }
    }

    @Test("Una versione futura si rifiuta invece di interpretarla male")
    func futureVersionIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = try awkwardVolume()
        try VolumeFile.write(original, to: directory)

        let headerURL = directory.appendingPathComponent(VolumeFile.headerName)
        var header = try JSONDecoder().decode(
            VolumeFileHeader.self, from: Data(contentsOf: headerURL))
        header.version = VolumeFileHeader.currentVersion + 1
        try JSONEncoder().encode(header).write(to: headerURL)

        #expect(throws: VolumeFileError.self) {
            _ = try VolumeFile.read(from: directory)
        }
    }

    @Test("L'unità di densità sopravvive, e uno sconosciuto ripiega su GV")
    func densityUnitSurvives() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let geometry = try VolumeGeometry(
            columnCount: 1, rowCount: 1, sliceCount: 1,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: .standardAxial, originMM: .zero)
        let hounsfield = try Volume(
            geometry: geometry, samples: [0], densityUnit: .declaredHounsfield)
        try VolumeFile.write(hounsfield, to: directory)
        #expect(try VolumeFile.read(from: directory).densityUnit == .declaredHounsfield)

        // Un simbolo che non conosciamo deve dare GV, non HU: dichiarare HU su dati che non lo
        // sono invita a confrontarli con le soglie di letteratura, ed è il Contratto 4.
        let headerURL = directory.appendingPathComponent(VolumeFile.headerName)
        var header = try JSONDecoder().decode(
            VolumeFileHeader.self, from: Data(contentsOf: headerURL))
        header.densityUnit = "QUALCOSA"
        try JSONEncoder().encode(header).write(to: headerURL)
        #expect(try VolumeFile.read(from: directory).densityUnit == .greyValue)
    }

    @Test("La via veloce e quella portabile si accordano, in scrittura e in lettura")
    func fastAndPortablePathsAgree() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let volume = try awkwardVolume()
        try VolumeFile.write(volume, to: directory)
        let written = try Data(
            contentsOf: directory.appendingPathComponent(VolumeFile.samplesName))

        // Su Apple si percorre sempre la via veloce, quindi quella portabile non viene mai
        // eseguita — e una via che non si percorre non si sa se funziona. Confrontarle è
        // l'unico modo di verificare qui il ramo big-endian.
        #expect(written == VolumeFile.portableBytes(of: volume.samples))
        #expect(written.count == volume.samples.count * 2)

        // E la lettura nei due versi. Serviva: la prima volta questo test copriva la sola
        // scrittura, e una mutazione che invertiva i byte nella lettura portabile non faceva
        // fallire niente — il ramo non veniva percorso, e la mutazione era inerte.
        #expect(
            VolumeFile.portableSamples(from: written, count: volume.samples.count)
                == volume.samples)
    }

    @Test("Un volume con molti campioni sopravvive intatto all'andata e ritorno")
    func largerVolumeSurvives() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Non enorme, ma abbastanza da percorrere la copia in blocco invece di pochi campioni:
        // 64³ sono 262 144 valori, e coprono il caso in cui la lettura copia byte grezzi.
        let geometry = try VolumeGeometry(
            columnCount: 64, rowCount: 64, sliceCount: 64,
            columnSpacingMM: 0.3, rowSpacingMM: 0.3, sliceSpacingMM: 0.3,
            orientation: .standardAxial, originMM: Vec3(-9.6, -9.6, -9.6))
        var samples = [Int16]()
        samples.reserveCapacity(geometry.voxelCount)
        for index in 0..<geometry.voxelCount {
            samples.append(Int16(truncatingIfNeeded: index &* 2_654_435_761))
        }
        let volume = try Volume(geometry: geometry, samples: samples)

        try VolumeFile.write(volume, to: directory)
        let reread = try VolumeFile.read(from: directory)
        #expect(reread.samples == volume.samples)
        #expect(reread.geometry == volume.geometry)
    }
}
