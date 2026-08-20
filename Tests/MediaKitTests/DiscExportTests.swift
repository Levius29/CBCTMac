import DICOMCore
import Foundation
import Testing

@testable import MediaKit

// La cartella da consegnare.
//
// Il controllo che conta è l'incrocio fra l'indice e il disco: il DICOMDIR nomina i file per
// nome, e se i nomi non corrispondono a quelli davvero scritti l'indice è peggio che inutile —
// è un indice rotto, che manda il visore a cercare file che non ci sono.

@Suite("Esportazione su cartella")
struct DiscExportTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("disc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func phantom() throws -> Volume {
        try SyntheticVolume.makePhantom(
            columns: 40, rows: 30, slices: 12, spacingMM: Vec3(0.5, 0.5, 1))
    }

    private var identity: DICOMExportIdentity {
        DICOMExportIdentity(
            patientName: "Rossi^Mario", patientID: "PZ-1", studyInstanceUID: "1.2.3",
            studyDate: "20240312", studyDescription: "Controllo",
            seriesDescription: "CBCT mascellare")
    }

    // MARK: Quali fette

    @Test("Le fette scelte comprendono la prima e l'ultima")
    func theChosenSlicesIncludeTheFirstAndTheLast() {
        let indices = SlicePreviewBuilder.sliceIndices(count: 400, limit: 60)
        #expect(indices.count == 60)
        #expect(indices.first == 0)
        #expect(indices.last == 399)
        // A passo costante: fra un indice e il successivo la distanza non varia di più di uno.
        let steps = zip(indices, indices.dropFirst()).map { $1 - $0 }
        #expect((steps.max() ?? 0) - (steps.min() ?? 0) <= 1)
        #expect(indices == indices.sorted())
    }

    @Test("Se le fette sono poche si prendono tutte")
    func fewSlicesAreAllTaken() {
        #expect(SlicePreviewBuilder.sliceIndices(count: 12, limit: 60) == Array(0..<12))
        #expect(SlicePreviewBuilder.sliceIndices(count: 0, limit: 60).isEmpty)
        #expect(SlicePreviewBuilder.sliceIndices(count: 10, limit: 0).isEmpty)
        #expect(SlicePreviewBuilder.sliceIndices(count: 10, limit: 1) == [0])
    }

    // MARK: Le anteprime

    @Test("L'anteprima è ridotta ma non deformata")
    func thePreviewIsScaledDownWithoutDistortion() throws {
        let volume = try SyntheticVolume.makePhantom(
            columns: 800, rows: 600, slices: 4, spacingMM: Vec3(0.1, 0.1, 1))
        let previews = SlicePreviewBuilder.previews(
            of: volume, windowCenterGV: 600, windowWidthGV: 2400, maximumSide: 200)

        let first = try #require(previews.first)
        // Riduzione a fattore intero: 800 e 600 diviso quattro.
        #expect(first.width == 200)
        #expect(first.height == 150)
        #expect(previews.allSatisfy { $0.width == 200 && $0.height == 150 })
    }

    @Test("La finestra decide i grigi: sotto nero, sopra bianco")
    func theWindowDecidesTheGreys() throws {
        // Un volume abbastanza grande da contenere il cubo **e** l'aria attorno: quello piccolo
        // degli altri test sta tutto dentro il cubo, quindi ha un livello di grigio solo per
        // costruzione — e il controllo sui livelli non direbbe niente.
        let volume = try SyntheticVolume.makePhantom(
            columns: 60, rows: 60, slices: 30, spacingMM: Vec3(1, 1, 1))

        // La fetta di mezzo, non la prima: la prima è al bordo del campo ed è tutta aria.
        let middle = volume.geometry.sliceCount / 2

        // Finestra tutta sopra le densità del fantoccio: ogni pixel al minimo.
        let dark = SlicePreviewBuilder.previews(
            of: volume, windowCenterGV: 20000, windowWidthGV: 100)
        #expect(try Self.allPixelsEqual(try #require(dark.first { $0.sliceIndex == middle }), to: 0))

        // Finestra tutta sotto: ogni pixel al massimo.
        let bright = SlicePreviewBuilder.previews(
            of: volume, windowCenterGV: -20000, windowWidthGV: 100)
        #expect(
            try Self.allPixelsEqual(
                try #require(bright.first { $0.sliceIndex == middle }), to: 255))

        // Una finestra vera dà un'immagine con più di un livello di grigio: se il codice
        // saturasse sempre, i due test qui sopra passerebbero lo stesso.
        let real = SlicePreviewBuilder.previews(
            of: volume, windowCenterGV: 600, windowWidthGV: 2400)
        let levels = try Self.pixelLevels(try #require(real.first { $0.sliceIndex == middle }))
        #expect(levels.count > 2, "l'anteprima ha solo \(levels.count) livelli di grigio")
    }

    @Test("Un'ampiezza di finestra nulla non fa dividere per zero")
    func aZeroWindowWidthDoesNotDivideByZero() throws {
        let previews = SlicePreviewBuilder.previews(
            of: try phantom(), windowCenterGV: 600, windowWidthGV: 0, maximumSlices: 2)
        #expect(!previews.isEmpty)
        for preview in previews {
            #expect(try Self.pixelLevels(preview).allSatisfy { $0 == 0 || $0 == 255 })
        }
    }

    @Test("Le anteprime portano la quota della fetta")
    func previewsCarryTheirPosition() throws {
        let volume = try phantom()
        let previews = SlicePreviewBuilder.previews(
            of: volume, windowCenterGV: 600, windowWidthGV: 2400)

        #expect(previews.count == volume.geometry.sliceCount)
        // Il passo fra due quote è la spaziatura delle fette, che qui è un millimetro.
        let positions = previews.map(\.positionMM)
        for (a, b) in zip(positions, positions.dropFirst()) {
            #expect(abs(abs(b - a) - volume.geometry.sliceSpacingMM) < 1e-9)
        }
    }

    // MARK: La pagina

    @Test("La pagina non si lascia rompere da un nome di paziente")
    func thePageSurvivesAHostilePatientName() throws {
        let volume = try phantom()
        let previews = SlicePreviewBuilder.previews(
            of: volume, windowCenterGV: 600, windowWidthGV: 2400, maximumSlices: 3)
        var hostile = identity
        hostile.patientName = "</script><script>alert(1)</script>^\"x\""
        hostile.seriesDescription = "Serie <b>& altro</b>"

        let html = PreviewPage.html(
            identity: hostile, previews: previews,
            fileNames: previews.indices.map { "fetta\($0).png" }, sliceCount: 12)

        #expect(!html.contains("<script>alert"))
        #expect(html.contains("&lt;/script&gt;"))
        #expect(html.contains("&amp;"))
    }

    @Test("La pagina dice di non essere un visore diagnostico")
    func thePageSaysWhatItIsNot() throws {
        let volume = try phantom()
        let previews = SlicePreviewBuilder.previews(
            of: volume, windowCenterGV: 600, windowWidthGV: 2400, maximumSlices: 3)
        let html = PreviewPage.html(
            identity: identity, previews: previews,
            fileNames: previews.indices.map { "fetta\($0).png" }, sliceCount: 400)

        #expect(html.contains("non un visore diagnostico"))
        #expect(html.contains("non si misurano"))
        // E dice quante fette sta saltando, invece di far credere che siano tutte.
        #expect(html.contains("3 fette su 400"))
    }

    @Test("Gli array della pagina sono lunghi quanto le fette")
    func thePageArraysMatchTheSlices() throws {
        let volume = try phantom()
        let previews = SlicePreviewBuilder.previews(
            of: volume, windowCenterGV: 600, windowWidthGV: 2400, maximumSlices: 5)
        let names = previews.indices.map { "fetta\($0).png" }
        let html = PreviewPage.html(
            identity: identity, previews: previews, fileNames: names, sliceCount: 12)

        // Il cursore deve arrivare all'ultima e non oltre: un massimo sbagliato mostrerebbe una
        // fetta vuota in fondo.
        #expect(html.contains("max=\"\(previews.count - 1)\""))
        for name in names { #expect(html.contains("\"\(name)\"")) }
    }

    // MARK: La cartella intera

    @Test("La cartella contiene i dati, l'indice, l'anteprima e le istruzioni")
    func theFolderHasEverything() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("consegna")

        let volume = try phantom()
        let result = try DiscExport.write(
            volume: volume, identity: identity, to: directory,
            windowCenterGV: 600, windowWidthGV: 2400)

        let manager = FileManager.default
        #expect(result.dicomFiles.count == volume.geometry.sliceCount)
        #expect(manager.fileExists(atPath: result.dicomdir.path))
        #expect(manager.fileExists(atPath: result.indexPage.path))
        #expect(
            manager.fileExists(
                atPath: directory.appendingPathComponent("LEGGIMI.txt").path))
        #expect(result.previewCount == volume.geometry.sliceCount)

        let previews = try manager.contentsOfDirectory(
            atPath: directory.appendingPathComponent(DiscExport.previewFolderName).path)
        #expect(previews.filter { $0.hasSuffix(".png") }.count == result.previewCount)
        #expect(previews.contains("index.html"))
    }

    @Test("L'indice nomina esattamente i file che stanno sul disco")
    func theIndexNamesTheFilesThatAreReallyThere() throws {
        // Il guasto contro cui questo protegge: un cambio nel nome dei file scritti da
        // `DICOMWriter` senza il corrispondente cambio nell'indice. I due posti sono lontani, il
        // programma continuerebbe a esportare senza errori, e il visore troverebbe un indice che
        // rimanda a file inesistenti.
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("consegna")

        let volume = try phantom()
        let result = try DiscExport.write(
            volume: volume, identity: identity, to: directory,
            windowCenterGV: 600, windowWidthGV: 2400)

        let index = String(decoding: try Data(contentsOf: result.dicomdir), as: UTF8.self)
        let onDisk = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".dcm") }
            .sorted()

        #expect(onDisk.count == volume.geometry.sliceCount)
        for name in onDisk {
            #expect(index.contains(name), "l'indice non nomina \(name)")
        }
    }

    @Test("Il LEGGIMI dice che le anteprime non si misurano")
    func theReadmeSaysThePreviewsAreNotForMeasuring() {
        let text = DiscExport.readme(
            identity: identity, sliceCount: 400, previewCount: 60, applicationName: "3DMED")

        #expect(text.contains("400"))
        #expect(text.contains("non a misurarlo"))
        #expect(text.contains("DICOMDIR"))
        #expect(text.contains("non è certificato come dispositivo medico"))
        // Il nome del paziente arriva in forma leggibile, non coi caret del DICOM.
        #expect(text.contains("Rossi Mario"))
        #expect(!text.contains("Rossi^Mario"))
    }

    @Test("Un volume di una fetta sola produce una cartella coerente")
    func aSingleSliceVolumeStillProducesACoherentFolder() throws {
        // Il caso degenere, che è quello in cui i conti fatti su «tutte le fette meno una» vanno
        // a sbattere. Un volume più vuoto di così non si può costruire: `VolumeGeometry` non
        // permette zero fette, quindi il limite inferiore vero è questo.
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }

        let orientation = try #require(SliceOrientation.standardAxial)
        let geometry = try VolumeGeometry(
            columnCount: 4, rowCount: 4, sliceCount: 1,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: orientation, originMM: Vec3(0, 0, 0))
        let volume = try Volume(geometry: geometry, samples: [Int16](repeating: 0, count: 16))

        let directory = parent.appendingPathComponent("una")
        let result = try DiscExport.write(
            volume: volume, identity: identity, to: directory,
            windowCenterGV: 0, windowWidthGV: 100)

        #expect(result.dicomFiles.count == 1)
        // Una fetta, un'anteprima, e un indice che la nomina.
        #expect(result.previewCount == 1)
        let index = String(decoding: try Data(contentsOf: result.dicomdir), as: UTF8.self)
        #expect(index.contains(try #require(result.dicomFiles.first).lastPathComponent))
        // Il cursore della pagina ha un solo valore possibile, e non deve valere -1.
        let page = try String(contentsOf: result.indexPage, encoding: .utf8)
        #expect(page.contains("max=\"0\""))
    }

    // MARK: Lettura dei PNG prodotti

    /// I pixel di un'anteprima, srotolando il PNG che il costruttore ha prodotto.
    static func pixels(_ preview: SlicePreview) throws -> [UInt8] {
        let bytes = [UInt8](preview.pngData)
        // Il PNG è composto da noi con un solo IDAT e blocchi «stored»: si salta l'intestazione
        // e si legge il contenuto, verificando che le dimensioni tornino.
        var offset = 8
        var compressed = Data()
        while offset + 8 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if type == "IDAT" {
                compressed.append(Data(bytes[(offset + 8)..<(offset + 8 + length)]))
            }
            offset += 8 + length + 4
        }

        var raw: [UInt8] = []
        var cursor = 2
        let stream = [UInt8](compressed)
        var final = false
        while !final, cursor + 5 <= stream.count {
            final = stream[cursor] & 1 == 1
            let length = Int(stream[cursor + 1]) | Int(stream[cursor + 2]) << 8
            cursor += 5
            raw.append(contentsOf: stream[cursor..<(cursor + length)])
            cursor += length
        }

        var result: [UInt8] = []
        var index = 0
        for _ in 0..<preview.height {
            index += 1  // byte del filtro
            result.append(contentsOf: raw[index..<(index + preview.width)])
            index += preview.width
        }
        return result
    }

    static func allPixelsEqual(_ preview: SlicePreview, to value: UInt8) throws -> Bool {
        try pixels(preview).allSatisfy { $0 == value }
    }

    static func pixelLevels(_ preview: SlicePreview) throws -> Set<UInt8> {
        Set(try pixels(preview))
    }
}
