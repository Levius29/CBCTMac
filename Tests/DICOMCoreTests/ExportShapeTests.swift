import Foundation
import Testing

@testable import DICOMCore

// Le forme in cui le CBCT arrivano davvero, lette da file scritti da un altro programma.
//
// # Perché queste prove usano fixture versionate
//
// Le altre prove di questo modulo generano i file in memoria, e va bene: provano la catena.
// Queste provano un'altra cosa — che leggiamo il formato come lo scrive il resto del mondo — e
// per quella un file scritto da noi non vale niente: lettore e scrittore sbaglierebbero insieme.
// Le fixture sono di pydicom; `Tools/make-dicom-fixtures.py` dice come sono fatte e le rigenera.
//
// Il volume dentro è lo stesso in tutte: 6 × 5 × 4 voxel, ogni voxel vale `100·k + 10·j + i`
// in valore grezzo, con spaziature diverse per asse e un'origine diversa da zero. Un voxel
// fuori posto, un asse scambiato o un'origine persa cambiano un numero che qui si controlla.

@Suite("Le forme vere delle esportazioni CBCT")
struct ExportShapeTests {

    private static let columns = 6
    private static let rows = 5
    private static let slices = 4

    private func fixture(_ name: String) throws -> URL {
        let root = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// Scansiona la cartella e pretende una serie sola, come la scrive il generatore.
    private func onlySeries(in folder: URL) throws -> (ScannedSeries, ScanResult) {
        let result = try DICOMScanner.scan(directory: folder, progress: nil)
        let series = result.patients.flatMap(\.studies).flatMap(\.series)
        #expect(series.count == 1)
        return (try #require(series.first), result)
    }

    /// Geometria e contenuto attesi, voxel per voxel.
    private func expectReferenceVolume(_ volume: Volume) {
        let geometry = volume.geometry
        #expect(geometry.columnCount == Self.columns)
        #expect(geometry.rowCount == Self.rows)
        #expect(geometry.sliceCount == Self.slices)
        #expect(abs(geometry.columnSpacingMM - 0.4) < 1e-9)
        #expect(abs(geometry.rowSpacingMM - 0.5) < 1e-9)
        #expect(abs(geometry.sliceSpacingMM - 0.75) < 1e-9)
        #expect(geometry.originMM.distance(to: Vec3(-10, -20, 30)) < 1e-9)

        var misplaced = 0
        for k in 0..<Self.slices {
            for j in 0..<Self.rows {
                for i in 0..<Self.columns {
                    let expected = Int16(100 * k + 10 * j + i)
                    if volume.rawValue(i: i, j: j, k: k) != expected { misplaced += 1 }
                }
            }
        }
        #expect(misplaced == 0)
        // Il rescale sta nei gruppi funzionali nei multiframe: se non lo si leggesse, qui
        // ci sarebbe 321 invece di −679.
        #expect(volume.densityValue(i: 1, j: 2, k: 3) == -679.0)
    }

    @Test(
        "Un'Enhanced CT in un file solo si apre come volume intero",
        arguments: ["enhanced-explicit", "enhanced-implicit", "enhanced-rle"])
    func enhancedMultiframeOpens(shape: String) throws {
        let (series, scan) = try onlySeries(in: try fixture(shape))
        #expect(scan.failures.isEmpty)
        #expect(series.instances.count == 1)
        #expect(series.instances.first?.frameCount == Self.slices)
        #expect(series.instances.first?.framePositionsAreDeduced == false)

        let seen = ProgressRecorder()
        let result = try VolumeBuilder.build(series: series) { seen.record($0) }
        expectReferenceVolume(result.volume)
        #expect(result.warnings.isEmpty)
        #expect(result.geometryIssues.isEmpty)
        // `RescaleType` sta anch'esso nel gruppo condiviso: letto lì, con l'intercetta a −1000,
        // dichiara Hounsfield. Letto solo al primo livello non ci sarebbe, e direbbe GV.
        #expect(result.volume.densityUnit == .declaredHounsfield)
        #expect(seen.last == VolumeLoadProgress(completedSlices: 4, totalSlices: 4))
    }

    @Test("Un multiframe senza gruppi funzionali si apre, e dice che le posizioni sono dedotte")
    func legacyMultiframeOpensWithWarning() throws {
        let (series, scan) = try onlySeries(in: try fixture("legacy-multiframe"))
        #expect(scan.failures.isEmpty)
        #expect(series.modality == "OT")
        #expect(series.isImageSeries)
        #expect(series.instances.first?.framePositionsAreDeduced == true)

        let result = try VolumeBuilder.build(series: series)
        expectReferenceVolume(result.volume)
        #expect(result.warnings.count == 1)
        #expect(result.warnings.first?.contains("dedotte") == true)
    }

    @Test("Il CD del centro si apre: DICOMDIR e visualizzatore non sono errori")
    func radiologyCDOpens() throws {
        let (series, scan) = try onlySeries(in: try fixture("cd"))
        // DICOMDIR, Viewer.exe, dicom.dll, autorun.inf: nessuno è un'immagine, nessuno è un
        // errore da mostrare.
        #expect(scan.failures.isEmpty)
        #expect(series.instances.count == Self.slices)
        // I file non hanno estensione, sono in Implicit VR, e l'InstanceNumber va al contrario.
        let result = try VolumeBuilder.build(series: series)
        expectReferenceVolume(result.volume)
        #expect(result.warnings.isEmpty)
    }

    @Test("Un programma Windows non passa per un DICOM senza preambolo")
    func windowsExecutableIsNotDICOM() {
        // L'intestazione di un .exe vero: «MZ», poi 90 00 03 00 00 00. Letta come DICOM
        // implicito è il tag (5A4D,0090) lungo tre byte — plausibile per il controllo di prima.
        let executable = Data([0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00])
            + Data(count: 502)
        #expect(throws: DICOMParsingError.notDICOM(sourceName: "Viewer.exe")) {
            _ = try DICOMParser.parse(
                data: executable, depth: .metadataOnly, sourceName: "Viewer.exe")
        }
    }

    @Test("Le sequenze annidate si leggono, item per item")
    func nestedSequencesAreRead() throws {
        let url = try fixture("enhanced-explicit").appendingPathComponent("CBCT.dcm")
        let parsed = try DICOMParser.parse(url: url, depth: .metadataOnly)
        let frames = try #require(parsed.dataset.items(DICOMTags.perFrameFunctionalGroupsSequence))
        #expect(frames.count == Self.slices)
        // Il primo fotogramma del file è la fetta più alta: 30 + 3 · 0,75.
        let first = frames.first?.items(DICOMTags.planePositionSequence)?.first
        #expect(first?.vec3(DICOMTags.imagePositionPatient) == Vec3(-10, -20, 32.25))
        // Il valore dell'elemento sequenza resta vuoto, come prima che le sequenze si leggessero.
        #expect(parsed.dataset[DICOMTags.perFrameFunctionalGroupsSequence]?.value.isEmpty == true)
    }

    @Test("Una sequenza illeggibile si salta come prima, senza perdere il file")
    func unreadableSequenceIsSkipped() throws {
        // Una sequenza a lunghezza definita che dentro non ha item ma spazzatura: leggerla
        // fallisce, saltarla no. Il file deve aprirsi esattamente come prima.
        let sequenceTag = DICOMTag(group: 0x0009, element: 0x1010)
        var builder = DICOMByteStreamBuilder()
        builder.appendPreamble()
        builder.appendExplicit(
            tag: DICOMTags.transferSyntaxUID, vr: .UI,
            value: builder.paddedUI("1.2.840.10008.1.2.1"))
        builder.appendExplicit(tag: sequenceTag, vr: .SQ, value: [0x12, 0x34, 0x56, 0x78])
        builder.appendExplicit(tag: DICOMTags.modality, vr: .CS, value: builder.paddedText("CT"))

        let parsed = try DICOMParser.parse(
            data: builder.data, depth: .metadataOnly, sourceName: "sequenza-rotta.dcm")
        #expect(parsed.dataset.items(sequenceTag)?.isEmpty == true)
        #expect(parsed.dataset.string(DICOMTags.modality) == "CT")
    }

    @Test("Il gruppo del fotogramma vince su quello condiviso, che vince sul primo livello")
    func frameGroupsTakePrecedence() {
        func text(_ tag: DICOMTag, _ vr: VR, _ value: String) -> DICOMElement {
            var bytes = Array(value.utf8)
            if bytes.count % 2 != 0 { bytes.append(0x20) }
            return DICOMElement(tag: tag, vr: vr, value: Data(bytes))
        }
        func sequence(_ tag: DICOMTag, _ items: [DICOMDataset]) -> DICOMElement {
            DICOMElement(tag: tag, vr: .SQ, value: Data(), isBigEndian: false, items: items)
        }

        let sharedMeasures = DICOMDataset(elements: [
            text(DICOMTags.pixelSpacing, .DS, "0.5\\0.4"),
            text(DICOMTags.sliceThickness, .DS, "0.75"),
        ])
        let frameMeasures = DICOMDataset(elements: [
            text(DICOMTags.pixelSpacing, .DS, "0.3\\0.2")
        ])
        let dataset = DICOMDataset(elements: [
            text(DICOMTags.pixelSpacing, .DS, "9\\9"),
            text(DICOMTags.sliceThickness, .DS, "9"),
            sequence(
                DICOMTags.sharedFunctionalGroupsSequence,
                [DICOMDataset(elements: [sequence(DICOMTags.pixelMeasuresSequence, [sharedMeasures])])]),
            sequence(
                DICOMTags.perFrameFunctionalGroupsSequence,
                [DICOMDataset(elements: [sequence(DICOMTags.pixelMeasuresSequence, [frameMeasures])])]),
        ])

        let layout = FrameLayout(dataset: dataset)
        // La spaziatura sta nel gruppo del fotogramma; lo spessore solo in quello condiviso.
        #expect(layout.pixelSpacing == PixelSpacing(rowMM: 0.3, columnMM: 0.2))
        #expect(layout.sliceThicknessMM == 0.75)
    }
}

/// Raccoglie gli avanzamenti, che arrivano da una chiusura `@Sendable`.
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [VolumeLoadProgress] = []

    func record(_ progress: VolumeLoadProgress) {
        lock.lock()
        values.append(progress)
        lock.unlock()
    }

    var last: VolumeLoadProgress? {
        lock.lock()
        defer { lock.unlock() }
        return values.last
    }
}
