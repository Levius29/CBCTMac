import Foundation
import Testing

@testable import DICOMCore

// Prova completa della catena: byte DICOM → scansione → ordinamento → volume → misure.
//
// È l'unico test che attraversa tutti i pezzi insieme, e serve proprio a questo: i test dei
// singoli moduli verificano ciascuno il proprio contratto, ma un volume sbagliato nasce quasi
// sempre da un malinteso *fra* due moduli — l'ordine dei campioni, la compensazione
// dell'intercetta, l'accoppiamento fra spaziatura di righe e colonne.
//
// Le serie si generano in memoria e si scrivono in una cartella temporanea, cancellata alla
// fine. Nessun dato clinico, nessuna fixture versionata.

@Suite("Catena completa: da file DICOM a volume")
struct VolumeBuilderTests {

    // MARK: Generazione di una serie

    /// Scrive una serie assiale con un cubo denso al centro.
    ///
    /// Il valore di ogni voxel è noto per costruzione, quindi le misure attese sono esatte e
    /// non stime.
    private func writeSeries(
        to directory: URL,
        columns: Int = 24,
        rows: Int = 24,
        slices: Int = 12,
        columnSpacing: Double = 0.5,
        rowSpacing: Double = 0.5,
        sliceSpacing: Double = 1.0,
        isSigned: Bool = false,
        bitsStored: Int = 12,
        intercept: Double = -1000,
        shuffle: Bool = true
    ) throws {

        let seriesUID = "1.2.826.0.1.3680043.9.7.1"
        let studyUID = "1.2.826.0.1.3680043.9.7"

        // Ordine di scrittura mescolato di proposito: se il costruttore si appoggiasse
        // all'ordine dei file invece che alla posizione, qui fallirebbe.
        var order = Array(0..<slices)
        if shuffle { order = order.reversed() }

        for k in order {
            var builder = DICOMByteStreamBuilder()
            builder.appendPreamble()

            // Gruppo meta: sempre Explicit VR Little Endian.
            var meta = DICOMByteStreamBuilder()
            meta.appendExplicit(
                tag: DICOMTags.mediaStorageSOPClassUID, vr: .UI,
                value: meta.paddedUI("1.2.840.10008.5.1.4.1.1.2"))
            meta.appendExplicit(
                tag: DICOMTags.mediaStorageSOPInstanceUID, vr: .UI,
                value: meta.paddedUI("\(seriesUID).\(k + 1)"))
            meta.appendExplicit(
                tag: DICOMTags.transferSyntaxUID, vr: .UI,
                value: meta.paddedUI("1.2.840.10008.1.2.1"))

            builder.appendExplicit(
                tag: DICOMTags.fileMetaGroupLength, vr: .UL,
                value: builder.littleEndianUInt32(UInt32(meta.bytes.count)))
            builder.appendRaw(meta.bytes)

            // Dataset.
            builder.appendExplicit(
                tag: DICOMTags.sopClassUID, vr: .UI,
                value: builder.paddedUI("1.2.840.10008.5.1.4.1.1.2"))
            builder.appendExplicit(
                tag: DICOMTags.sopInstanceUID, vr: .UI,
                value: builder.paddedUI("\(seriesUID).\(k + 1)"))
            builder.appendExplicit(
                tag: DICOMTags.modality, vr: .CS, value: builder.paddedText("CT"))
            builder.appendExplicit(
                tag: DICOMTags.manufacturer, vr: .LO, value: builder.paddedText("NewTom"))
            builder.appendExplicit(
                tag: DICOMTags.patientID, vr: .LO, value: builder.paddedText("TEST001"))
            builder.appendExplicit(
                tag: DICOMTags.studyInstanceUID, vr: .UI, value: builder.paddedUI(studyUID))
            builder.appendExplicit(
                tag: DICOMTags.seriesInstanceUID, vr: .UI, value: builder.paddedUI(seriesUID))

            // Numero di istanza deliberatamente **al contrario** rispetto alla posizione:
            // se l'ordinamento lo usasse, il volume risulterebbe capovolto.
            builder.appendExplicit(
                tag: DICOMTags.instanceNumber, vr: .IS,
                value: builder.paddedText("\(slices - k)"))

            let z = Double(k) * sliceSpacing
            builder.appendExplicit(
                tag: DICOMTags.imagePositionPatient, vr: .DS,
                value: builder.paddedText("0\\0\\\(z)"))
            builder.appendExplicit(
                tag: DICOMTags.imageOrientationPatient, vr: .DS,
                value: builder.paddedText("1\\0\\0\\0\\1\\0"))

            builder.appendExplicit(
                tag: DICOMTags.rows, vr: .US, value: uint16Bytes(UInt16(rows)))
            builder.appendExplicit(
                tag: DICOMTags.columns, vr: .US, value: uint16Bytes(UInt16(columns)))
            // PixelSpacing è [righe, colonne]: qui i due valori sono diversi apposta, così uno
            // scambio non passa inosservato.
            builder.appendExplicit(
                tag: DICOMTags.pixelSpacing, vr: .DS,
                value: builder.paddedText("\(rowSpacing)\\\(columnSpacing)"))
            builder.appendExplicit(
                tag: DICOMTags.sliceThickness, vr: .DS,
                value: builder.paddedText("\(sliceSpacing)"))
            builder.appendExplicit(
                tag: DICOMTags.bitsAllocated, vr: .US, value: uint16Bytes(16))
            builder.appendExplicit(
                tag: DICOMTags.bitsStored, vr: .US, value: uint16Bytes(UInt16(bitsStored)))
            builder.appendExplicit(
                tag: DICOMTags.highBit, vr: .US, value: uint16Bytes(UInt16(bitsStored - 1)))
            builder.appendExplicit(
                tag: DICOMTags.pixelRepresentation, vr: .US,
                value: uint16Bytes(isSigned ? 1 : 0))
            builder.appendExplicit(
                tag: DICOMTags.rescaleIntercept, vr: .DS,
                value: builder.paddedText("\(intercept)"))
            builder.appendExplicit(
                tag: DICOMTags.rescaleSlope, vr: .DS, value: builder.paddedText("1"))

            // Pixel: cubo denso di 8×8 voxel al centro nelle slice centrali.
            var pixels: [UInt8] = []
            pixels.reserveCapacity(columns * rows * 2)
            let dense = k >= 4 && k < 8
            for j in 0..<rows {
                for i in 0..<columns {
                    let inCube =
                        dense && i >= 8 && i < 16 && j >= 8 && j < 16
                    // Aria a −1000 e osso a 1200, memorizzati con l'intercetta applicata.
                    let density: Double = inCube ? 1200 : -1000
                    let stored = UInt16(max(0, min(Double((1 << bitsStored) - 1), density - intercept)))
                    pixels.append(UInt8(stored & 0xFF))
                    pixels.append(UInt8((stored >> 8) & 0xFF))
                }
            }
            builder.appendExplicit(tag: DICOMTags.pixelData, vr: .OW, value: pixels)

            let url = directory.appendingPathComponent(String(format: "slice_%03d.dcm", k))
            try Data(builder.bytes).write(to: url)
        }
    }

    private func uint16Bytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private func withTemporaryDirectory<R>(_ body: (URL) throws -> R) throws -> R {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CBCTMacTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    // MARK: Test

    @Test("Una serie completa diventa un volume con la geometria giusta")
    func buildsVolume() throws {
        try withTemporaryDirectory { directory in
            try writeSeries(to: directory)

            let scan = try DICOMScanner.scan(directory: directory, progress: nil)
            #expect(scan.failures.isEmpty, "fallimenti: \(scan.failures.map(\.reason))")

            let series = try #require(scan.patients.first?.studies.first?.series.first)
            #expect(series.instances.count == 12)

            let result = try VolumeBuilder.build(series: series)
            let geometry = result.volume.geometry

            #expect(geometry.columnCount == 24)
            #expect(geometry.rowCount == 24)
            #expect(geometry.sliceCount == 12)
            #expect(abs(geometry.sliceSpacingMM - 1.0) < 1e-9)
            #expect(result.geometryIssues.isEmpty)
        }
    }

    @Test("La spaziatura di righe e colonne non viene scambiata")
    func spacingIsNotSwapped() throws {
        // È la trappola che su voxel isotropici non dà alcun sintomo. Qui le due spaziature
        // sono diverse, quindi uno scambio si vede subito.
        try withTemporaryDirectory { directory in
            try writeSeries(to: directory, columnSpacing: 0.3, rowSpacing: 0.7)

            let scan = try DICOMScanner.scan(directory: directory, progress: nil)
            let series = try #require(scan.patients.first?.studies.first?.series.first)
            let geometry = try VolumeBuilder.build(series: series).volume.geometry

            #expect(abs(geometry.columnSpacingMM - 0.3) < 1e-9)
            #expect(abs(geometry.rowSpacingMM - 0.7) < 1e-9)

            // Verifica indipendente: un passo di colonna deve spostare di 0,3 mm.
            let origin = geometry.patientPoint(i: 0, j: 0, k: 0)
            let oneColumn = geometry.patientPoint(i: 1, j: 0, k: 0)
            let oneRow = geometry.patientPoint(i: 0, j: 1, k: 0)
            #expect(abs(oneColumn.distance(to: origin) - 0.3) < 1e-9)
            #expect(abs(oneRow.distance(to: origin) - 0.7) < 1e-9)
        }
    }

    @Test("L'ordinamento ignora InstanceNumber e usa la posizione")
    func ignoresInstanceNumber() throws {
        // I file sono scritti al contrario e InstanceNumber è a sua volta invertito rispetto
        // alla posizione: solo ordinando per proiezione sulla normale il volume viene diritto.
        try withTemporaryDirectory { directory in
            try writeSeries(to: directory, shuffle: true)

            let scan = try DICOMScanner.scan(directory: directory, progress: nil)
            let series = try #require(scan.patients.first?.studies.first?.series.first)
            let volume = try VolumeBuilder.build(series: series).volume

            // Il cubo denso occupa le slice da 4 a 7 in ordine geometrico. Se l'ordinamento
            // fosse rovesciato finirebbe fra la 4 e la 7 contate dall'altro capo, cioè fra la
            // 4 e la 7 dell'ordine invertito: qui si controlla che stia dove deve.
            let centre = Vec3(12 * 0.5, 12 * 0.5, 5.0)
            let inside = try #require(volume.densityValue(atPatient: centre))
            #expect(abs(inside - 1200) < 1.0, "al centro del cubo letto \(inside)")

            let outsideBelow = try #require(
                volume.densityValue(atPatient: Vec3(12 * 0.5, 12 * 0.5, 1.0)))
            #expect(abs(outsideBelow - (-1000)) < 1.0)
        }
    }

    @Test("I dati senza segno a 16 bit ricevono la compensazione dell'intercetta")
    func compensatesInterceptForUnsigned16Bit() throws {
        // Con BitsStored 16 il decoder trasla di −32768 per far entrare i valori in Int16.
        // Se la compensazione mancasse, ogni densità risulterebbe spostata di 32768 e
        // l'immagine sarebbe identica: è il motivo per cui questo test esiste.
        try withTemporaryDirectory { directory in
            try writeSeries(to: directory, bitsStored: 16)

            let scan = try DICOMScanner.scan(directory: directory, progress: nil)
            let series = try #require(scan.patients.first?.studies.first?.series.first)
            let volume = try VolumeBuilder.build(series: series).volume

            let centre = Vec3(12 * 0.5, 12 * 0.5, 5.0)
            let inside = try #require(volume.densityValue(atPatient: centre))
            #expect(
                abs(inside - 1200) < 1.0,
                "atteso 1200 GV, letto \(inside): controlla la compensazione dell'intercetta")

            let air = try #require(volume.densityValue(atPatient: Vec3(0.5, 0.5, 5.0)))
            #expect(abs(air - (-1000)) < 1.0)
        }
    }

    @Test("Un apparecchio CBCT produce valori etichettati GV, non HU")
    func cbctIsLabelledGreyValue() throws {
        // Il produttore dichiarato è NewTom, cioè una CBCT, anche se Modality vale CT.
        // Il Contratto 4 impone GV: dichiarare HU offrirebbe al clinico un numero
        // apparentemente confrontabile con la letteratura, e non lo è.
        try withTemporaryDirectory { directory in
            try writeSeries(to: directory)

            let scan = try DICOMScanner.scan(directory: directory, progress: nil)
            let series = try #require(scan.patients.first?.studies.first?.series.first)
            let volume = try VolumeBuilder.build(series: series).volume

            #expect(volume.densityUnit == .greyValue)
            #expect(volume.densityUnit.symbol == "GV")
        }
    }

    @Test("La scansione riporta l'avanzamento senza saltare slice")
    func reportsProgress() throws {
        try withTemporaryDirectory { directory in
            try writeSeries(to: directory)

            let scan = try DICOMScanner.scan(directory: directory, progress: nil)
            let series = try #require(scan.patients.first?.studies.first?.series.first)

            let recorded = Mutex<[Int]>([])
            _ = try VolumeBuilder.build(series: series) { progress in
                recorded.withLock { $0.append(progress.completedSlices) }
            }

            let values = recorded.withLock { $0 }
            #expect(values == Array(1...12))
        }
    }

    @Test("Una serie senza spaziatura pixel viene rifiutata")
    func rejectsMissingPixelSpacing() throws {
        // Senza spaziatura si potrebbe pur sempre mostrare l'immagine, ma ogni misura sarebbe
        // un numero privo di unità. Meglio rifiutare che produrre misure false.
        let series = ScannedSeries(
            seriesInstanceUID: "x", seriesNumber: nil, description: nil, modality: "CT",
            instances: [
                ScannedInstance(
                    url: URL(fileURLWithPath: "/dev/null"),
                    sopInstanceUID: "a", seriesInstanceUID: "x", studyInstanceUID: "y",
                    instanceNumber: 1, positionMM: Vec3(0, 0, 0),
                    orientation: .standardAxial)
            ],
            rows: 8, columns: 8, pixelSpacingMM: nil, sliceThicknessMM: 1,
            isImageSeries: true)

        #expect(throws: VolumeBuildError.self) {
            _ = try VolumeBuilder.build(series: series)
        }
    }
}

/// Contenitore sincronizzato minimale, per raccogliere valori da una chiusura `@Sendable`.
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
