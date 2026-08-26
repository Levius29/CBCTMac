import DICOMCore
import Foundation
import MeshKit
import Testing

@testable import SegmentKit

// Il giro completo: dal volume al file che una stampante accetta.
//
// # Perché questa prova esiste, e perché sta qui e non in MeshKit
//
// Ogni pezzo della catena ha già le sue prove: la competizione separa, marching cubes chiude la
// superficie, Taubin non ritira, la decimazione non rovescia. Nessuna di quelle prove però
// guarda il **prodotto**, e su questo progetto è già successo tre volte che dei pezzi corretti
// non fossero raggiungibili insieme. Qui si guarda solo la fine: il byte che esce.
//
// Le condizioni sono quelle che uno slicer impone davvero, e non una in più:
//
// - **chiuso**, cioè nessuno spigolo percorso una volta sola e nessuno percorso più di due;
// - **un solo guscio**, perché le isole di rumore diventano schegge staccate sul piatto;
// - **normali all'esterno**, altrimenti il solido si stampa vuoto o non si stampa;
// - **un numero di triangoli che si possa aprire**, perché mezzo milione blocca lo slicer.

private func phantomWithTooth() throws -> (volume: Volume, boneMM: Vec3, toothMM: Vec3) {
    let side = 48
    let spacing = 0.4
    let orientation = try #require(
        SliceOrientation(columnDirection: Vec3(1, 0, 0), rowDirection: Vec3(0, 1, 0)))
    let geometry = try VolumeGeometry(
        columnCount: side, rowCount: side, sliceCount: side,
        columnSpacingMM: spacing, rowSpacingMM: spacing, sliceSpacingMM: spacing,
        orientation: orientation, originMM: Vec3(0, 0, 0))

    var samples = [Int16](repeating: 0, count: side * side * side)
    let centre = Double(side) / 2
    for k in 0..<side {
        for j in 0..<side {
            for i in 0..<side {
                let x = Double(i), y = Double(j), z = Double(k)
                let radial = ((x - centre) * (x - centre) + (y - centre) * (y - centre))
                    .squareRoot()
                var value: Int16 = 0
                if z > 4, z < 28, x > 4, x < Double(side) - 4, y > 4, y < Double(side) - 4 {
                    value = 1200
                }
                if radial >= 5, radial < 6.5, z > 8, z < 28 { value = 1000 }
                if radial < 6.5, z > 8, z <= 10 { value = 1000 }
                if radial < 5, z > 10, z < 42 { value = 1900 }
                samples[(k * side + j) * side + i] = value
            }
        }
    }
    let volume = try Volume(
        geometry: geometry, samples: samples, rescaleSlope: 1, rescaleIntercept: 0,
        densityUnit: .greyValue)
    return (
        volume,
        geometry.patientPoint(i: 8, j: 8, k: 16),
        geometry.patientPoint(i: side / 2, j: side / 2, k: 38)
    )
}

@Suite("Dal volume al file stampabile")
struct PrintablePipelineTests {

    @Test("Un dente separato esce chiuso, in un pezzo solo e con le normali all'esterno")
    func toothLeavesAsAPrintableSolid() throws {
        let phantom = try phantomWithTooth()
        let mask = try CompetitiveGrowth.grow(
            in: phantom.volume,
            seeds: [(seedMM: phantom.boneMM, label: 1), (seedMM: phantom.toothMM, label: 2)],
            densityRange: 900...4000)

        let raw = try #require(
            MaskSurface.mesh(of: mask, label: 2, spacingMM: 0.4, name: "Dente 46"))
        let smoothed = MeshSmoothing.taubin(raw, iterations: 12)
        let solid = MeshRepair.orientedOutward(MeshRepair.largestShell(of: smoothed))
        let report = MeshRepair.integrity(of: solid)

        #expect(report.isWatertight)
        #expect(report.shellCount == 1)
        #expect(report.volumeMM3 > 0)
        // Il dente del fantoccio è un cilindro da 2 mm di raggio e 12,4 mm: circa 156 mm³, più
        // il guscio del legamento che la competizione gli lascia attorno. Il limite serve a
        // intercettare il caso in cui la separazione fallisce e il modello diventa la mandibola.
        #expect(report.volumeMM3 > 100)
        #expect(report.volumeMM3 < 600)
    }

    @Test("La lisciatura toglie le scalette senza assottigliare il dente")
    func smoothingDoesNotThinTheTooth() throws {
        let phantom = try phantomWithTooth()
        let mask = try CompetitiveGrowth.grow(
            in: phantom.volume,
            seeds: [(seedMM: phantom.boneMM, label: 1), (seedMM: phantom.toothMM, label: 2)],
            densityRange: 900...4000)
        let raw = try #require(
            MaskSurface.mesh(of: mask, label: 2, spacingMM: 0.4, name: "Dente 46"))
        let smoothed = MeshSmoothing.taubin(raw, iterations: 12)

        let before = abs(raw.signedVolumeMM3())
        let after = abs(smoothed.signedVolumeMM3())
        // Cinque per cento: sotto il decimo di millimetro sul raggio di un dente, cioè meno
        // dell'errore con cui la soglia lo ha ritagliato. Un ritiro maggiore si sentirebbe
        // provando il modello stampato, ed è la ragione per cui questo numero è qui.
        #expect(abs(after - before) / before < 0.05)
        #expect(MeshRepair.integrity(of: smoothed).isWatertight)
    }

    @Test("Il bilancio di triangoli si rispetta e il solido resta chiuso")
    func decimationKeepsTheSolidClosed() throws {
        let phantom = try phantomWithTooth()
        let mask = try CompetitiveGrowth.grow(
            in: phantom.volume,
            seeds: [(seedMM: phantom.boneMM, label: 1), (seedMM: phantom.toothMM, label: 2)],
            densityRange: 900...4000)
        let raw = try #require(
            MaskSurface.mesh(of: mask, label: 2, spacingMM: 0.4, name: "Dente 46"))
        let budget = raw.triangleCount / 4
        let reduced = MeshDecimation.simplified(
            MeshSmoothing.taubin(raw, iterations: 8), targetTriangleCount: budget)

        #expect(reduced.triangleCount <= budget)
        let report = MeshRepair.integrity(of: reduced)
        #expect(report.openEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
    }

    @Test("STL e OBJ escono e si rileggono uguali")
    func bothFormatsSurviveTheRoundTrip() throws {
        let phantom = try phantomWithTooth()
        let mask = try CompetitiveGrowth.grow(
            in: phantom.volume,
            seeds: [(seedMM: phantom.boneMM, label: 1), (seedMM: phantom.toothMM, label: 2)],
            densityRange: 900...4000)
        let raw = try #require(
            MaskSurface.mesh(of: mask, label: 2, spacingMM: 0.4, name: "Dente 46"))
        let solid = MeshRepair.orientedOutward(
            MeshDecimation.simplified(
                MeshSmoothing.taubin(raw, iterations: 8), targetTriangleCount: 4_000))

        // L'OBJ conserva gli indici, quindi torna identico.
        let obj = try MeshIO.load(data: MeshIO.export(solid, as: .obj), name: "dente.obj")
        #expect(obj.triangles.count == solid.triangles.count)
        #expect(obj.verticesMM.count == solid.verticesMM.count)

        // L'STL binario invece scrive **tre vertici per triangolo in Float32** e non ha indici:
        // rileggendolo i vertici tornano moltiplicati per tre finché non li si risalda, e le
        // coordinate hanno la precisione del Float e non del Double. Il confronto quindi si fa
        // sui triangoli dopo la saldatura, e non sui byte — aspettarsi l'uguaglianza esatta
        // sarebbe aspettarsi che il formato conservi ciò che per progetto non conserva.
        let stl = try MeshIO.load(data: MeshIO.export(solid, as: .stlBinary), name: "dente.stl")
        #expect(stl.triangles.count == solid.triangles.count)
        #expect(stl.welded(toleranceMM: 1e-3).verticesMM.count == solid.verticesMM.count)
    }

    @Test("L'osso di ritorno è il resto, e anche lui esce stampabile")
    func theBoneComesOutPrintableToo() throws {
        let phantom = try phantomWithTooth()
        let mask = try CompetitiveGrowth.grow(
            in: phantom.volume,
            seeds: [(seedMM: phantom.boneMM, label: 1), (seedMM: phantom.toothMM, label: 2)],
            densityRange: 900...4000)
        let raw = try #require(
            MaskSurface.mesh(of: mask, label: 1, spacingMM: 0.4, name: "Osso"))
        let solid = MeshRepair.orientedOutward(MeshRepair.largestShell(of: raw))
        let report = MeshRepair.integrity(of: solid)
        #expect(report.isWatertight)
        #expect(report.volumeMM3 > 0)
    }
}
