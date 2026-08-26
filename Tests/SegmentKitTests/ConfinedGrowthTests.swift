import DICOMCore
import Foundation
import Testing

@testable import SegmentKit

// Confinare la crescita, e perché è l'unico rimedio che dà un limite superiore.
//
// # Il fantoccio
//
// Un dente cilindrico piantato in una lastra d'osso, con attorno alla radice un guscio più scuro
// che fa da legamento parodontale — ma solo lungo il fianco, non sotto l'apice. È fatto così
// apposta: nell'osso vero la radice tocca la corticale in qualche punto, il legamento non fa mai
// il giro completo alla risoluzione di una CBCT, e quel punto di contatto è la porta da cui il
// fronte del dente esce e si prende la mandibola.
//
// # Che cosa dimostrano le prove, in ordine
//
// La prima misura il difetto: con un marcatore per parte il dente esce dalla porta e prende un
// ordine di grandezza in più di quel che gli spetta. La seconda misura il rimedio parziale —
// marcare l'osso in più punti — che riduce il danno e non lo elimina. La terza misura il rimedio
// vero, la scatola, che il danno lo taglia per costruzione.
//
// Le tre prove stanno insieme di proposito. Da sole, la prima sembrerebbe la segnalazione di un
// difetto irrisolto e la terza un valore arbitrario da aggiornare quando cambia; insieme dicono
// perché il parametro `within:` esiste, e nessuna delle tre si può togliere senza perdere il
// senso delle altre.

private struct ToothPhantom {
    var volume: Volume
    var boneSeedMM: Vec3
    var toothSeedMM: Vec3
    /// Quanti voxel il cilindro del dente occupa davvero: il metro di paragone delle prove.
    var toothVoxelCount: Int
    var geometry: VolumeGeometry { volume.geometry }
}

/// Costruisce il fantoccio.
///
/// - Parameters:
///   - rotated: scambia le direzioni di riga e colonna, così le stesse prove girano anche su un
///     volume che la matrice DICOM non allinea agli assi Patient.
///   - apexContact: quando è vero il legamento si ferma al fianco della radice e sotto l'apice
///     dente e osso si toccano alla stessa densità. È il caso duro, e va tenuto distinto: dove
///     due tessuti si toccano senza niente di più scuro in mezzo **non c'è un confine nel dato**,
///     e nessuna competizione lo trova. Le prove che seguono dicono l'una e l'altra cosa, e la
///     differenza fra le due è la sola misura onesta di che cosa questo strumento sa fare.
private func makeToothPhantom(rotated: Bool = false, apexContact: Bool = false) throws
    -> ToothPhantom
{
    let side = 48
    let spacing = 0.4
    let boneDensity: Int16 = 1200
    let toothDensity: Int16 = 1900
    let ligamentDensity: Int16 = 1000

    let orientation = try #require(
        SliceOrientation(
            columnDirection: rotated ? Vec3(0, 1, 0) : Vec3(1, 0, 0),
            rowDirection: rotated ? Vec3(-1, 0, 0) : Vec3(0, 1, 0)
        )
    )
    let geometry = try VolumeGeometry(
        columnCount: side, rowCount: side, sliceCount: side,
        columnSpacingMM: spacing, rowSpacingMM: spacing, sliceSpacingMM: spacing,
        orientation: orientation, originMM: Vec3(0, 0, 0)
    )

    var samples = [Int16](repeating: 0, count: side * side * side)
    var toothVoxels = 0
    let centre = Double(side) / 2
    for k in 0..<side {
        for j in 0..<side {
            for i in 0..<side {
                let x = Double(i), y = Double(j), z = Double(k)
                let radial = ((x - centre) * (x - centre) + (y - centre) * (y - centre))
                    .squareRoot()
                var value: Int16 = 0
                if z > 4, z < 28, x > 4, x < Double(side) - 4, y > 4, y < Double(side) - 4 {
                    value = boneDensity
                }
                // Il legamento lungo il fianco della radice.
                if radial >= 5, radial < 6.5, z > 8, z < 28 {
                    value = ligamentDensity
                }
                // E il suo tappo sotto l'apice, che c'è solo quando il contatto non è diretto.
                if !apexContact, radial < 6.5, z > 8, z <= 10 {
                    value = ligamentDensity
                }
                if radial < 5, z > 10, z < 42 {
                    value = toothDensity
                    toothVoxels += 1
                }
                samples[(k * side + j) * side + i] = value
            }
        }
    }

    let volume = try Volume(
        geometry: geometry, samples: samples,
        rescaleSlope: 1, rescaleIntercept: 0, densityUnit: .greyValue
    )
    return ToothPhantom(
        volume: volume,
        boneSeedMM: geometry.patientPoint(i: 8, j: 8, k: 16),
        toothSeedMM: geometry.patientPoint(i: side / 2, j: side / 2, k: 38),
        toothVoxelCount: toothVoxels
    )
}

/// La scatola attorno al dente: generosa sul fianco, così comprende anche il legamento.
private func toothBox(_ phantom: ToothPhantom) -> BoxMM {
    let centre = phantom.toothSeedMM
    return BoxMM(
        minMM: Vec3(centre.x - 3.5, centre.y - 3.5, centre.z - 12),
        maxMM: Vec3(centre.x + 3.5, centre.y + 3.5, centre.z + 2)
    )
}

/// Il marcatore dell'osso **dentro** la scatola, di fianco alla radice.
///
/// Non è un dettaglio del fantoccio, è il modo in cui la funzione va usata: la scatola limita
/// dove si può assegnare, ma dentro di essa qualcuno deve contendere il terreno al dente. Un
/// marcatore d'osso lasciato dall'altra parte della mandibola sta fuori dalla scatola, non
/// compete, e il dente si prende tutto quel che la scatola contiene — osso incluso.
private func boneSeedInside(_ phantom: ToothPhantom) -> Vec3 {
    let side = phantom.geometry.columnCount
    return phantom.geometry.patientPoint(i: side / 2 + 8, j: side / 2, k: 20)
}

/// Quanti voxel della scatola stanno sopra la soglia: il tetto che il solo confinamento impone.
private func voxelsAboveThreshold(in box: BoxMM, of phantom: ToothPhantom) -> Int {
    let geometry = phantom.geometry
    var count = 0
    for k in 0..<geometry.sliceCount {
        for j in 0..<geometry.rowCount {
            for i in 0..<geometry.columnCount {
                let index = (k * geometry.rowCount + j) * geometry.columnCount + i
                guard phantom.volume.samples[index] >= 900 else { continue }
                if box.contains(geometry.patientPoint(i: i, j: j, k: k)) { count += 1 }
            }
        }
    }
    return count
}

@Suite("Crescita confinata")
struct ConfinedGrowthTests {

    @Test("Con un percorso più scuro attorno alla radice, la competizione basta da sola")
    func competitionAloneWorksWhenTheLigamentWraps() throws {
        let phantom = try makeToothPhantom()
        let mask = try CompetitiveGrowth.grow(
            in: phantom.volume,
            seeds: [
                (seedMM: phantom.boneSeedMM, label: 1), (seedMM: phantom.toothSeedMM, label: 2),
            ],
            densityRange: 900...4000
        )
        let tooth = mask.voxelCounts()[2] ?? 0
        // Il dente più il guscio del legamento che gli sta attorno, e niente osso: è il caso per
        // cui la competizione è stata scritta, e qui va misurato che lo risolve senza aiuti.
        #expect(tooth >= phantom.toothVoxelCount)
        #expect(tooth < phantom.toothVoxelCount * 3 / 2)
    }

    @Test("Dove dente e osso si toccano, la competizione da sola non tiene")
    func competitionLeaksThroughDirectContact() throws {
        let phantom = try makeToothPhantom(apexContact: true)
        let mask = try CompetitiveGrowth.grow(
            in: phantom.volume,
            seeds: [
                (seedMM: phantom.boneSeedMM, label: 1), (seedMM: phantom.toothSeedMM, label: 2),
            ],
            densityRange: 900...4000
        )
        let tooth = mask.voxelCounts()[2] ?? 0
        // Un ordine di grandezza in più: dall'apice il fronte esce e si prende la mandibola.
        // Non è un difetto dell'algoritmo — sotto l'apice non c'è niente di più scuro, quindi
        // non c'è nessun confine da trovare. È il motivo per cui serve un limite esterno.
        #expect(tooth > phantom.toothVoxelCount * 5)
    }

    @Test("Marcare l'osso in più punti riduce la fuga ma non la chiude")
    func manyBoneSeedsHelpButDoNotClose() throws {
        let phantom = try makeToothPhantom(apexContact: true)
        var seeds: [(seedMM: Vec3, label: SegmentLabel)] = [
            (seedMM: phantom.toothSeedMM, label: 2)
        ]
        for (i, j) in [(8, 8), (39, 8), (8, 39), (39, 39)] {
            seeds.append((seedMM: phantom.geometry.patientPoint(i: i, j: j, k: 16), label: 1))
        }
        let spread = try CompetitiveGrowth.grow(
            in: phantom.volume, seeds: seeds, densityRange: 900...4000)
        let single = try CompetitiveGrowth.grow(
            in: phantom.volume,
            seeds: [
                (seedMM: phantom.boneSeedMM, label: 1), (seedMM: phantom.toothSeedMM, label: 2),
            ],
            densityRange: 900...4000
        )

        let spreadTooth = spread.voxelCounts()[2] ?? 0
        #expect(spreadTooth < (single.voxelCounts()[2] ?? 0))
        // E resta comunque fuori misura: è la ragione per cui i marcatori non bastano.
        #expect(spreadTooth > phantom.toothVoxelCount * 2)
    }

    @Test("La scatola mette un tetto anche dove il dato non ha un confine")
    func theBoxCapsTheHardCase() throws {
        let phantom = try makeToothPhantom(apexContact: true)
        let box = toothBox(phantom)
        let mask = try CompetitiveGrowth.grow(
            in: phantom.volume,
            seeds: [
                (seedMM: boneSeedInside(phantom), label: 1),
                (seedMM: phantom.toothSeedMM, label: 2),
            ],
            densityRange: 900...4000,
            within: box
        )
        let tooth = mask.voxelCounts()[2] ?? 0
        let ceiling = voxelsAboveThreshold(in: box, of: phantom)
        // Il tetto è la scatola, e vale per costruzione: qualunque cosa faccia il dato, fuori di
        // lì non si assegna niente. Il limite di sotto conta quanto quello di sopra — una
        // scatola che tagliasse via la radice passerebbe il solo limite superiore, e sarebbe un
        // risultato peggiore, non migliore.
        #expect(tooth >= phantom.toothVoxelCount)
        #expect(tooth <= ceiling)
        #expect(ceiling < phantom.toothVoxelCount * 4)
    }

    @Test("Con la scatola e un contendente dentro, il dente resta il dente")
    func confinedGrowthKeepsTheTooth() throws {
        let phantom = try makeToothPhantom()
        let mask = try CompetitiveGrowth.grow(
            in: phantom.volume,
            seeds: [
                (seedMM: boneSeedInside(phantom), label: 1),
                (seedMM: phantom.toothSeedMM, label: 2),
            ],
            densityRange: 900...4000,
            within: toothBox(phantom)
        )
        let tooth = mask.voxelCounts()[2] ?? 0
        #expect(tooth >= phantom.toothVoxelCount)
        #expect(tooth < phantom.toothVoxelCount * 3 / 2)
    }

    @Test("La scatola vale anche su un volume che la matrice DICOM ruota")
    func confinementSurvivesRotatedGeometry() throws {
        let phantom = try makeToothPhantom(rotated: true)
        let mask = try CompetitiveGrowth.grow(
            in: phantom.volume,
            seeds: [
                (seedMM: boneSeedInside(phantom), label: 1),
                (seedMM: phantom.toothSeedMM, label: 2),
            ],
            densityRange: 900...4000,
            within: toothBox(phantom)
        )
        let tooth = mask.voxelCounts()[2] ?? 0
        #expect(tooth >= phantom.toothVoxelCount)
        #expect(tooth < phantom.toothVoxelCount * 3 / 2)
    }

    @Test("Un seme fuori dalla scatola è un errore, non una regione vuota")
    func seedOutsideTheBoxIsAnError() throws {
        let phantom = try makeToothPhantom()
        #expect(throws: SegmentKitError.seedOutsideRestriction) {
            _ = try CompetitiveGrowth.grow(
                in: phantom.volume,
                seeds: [
                    (seedMM: phantom.boneSeedMM, label: 1),
                    (seedMM: phantom.toothSeedMM, label: 2),
                ],
                densityRange: 900...4000,
                // Una scatola stretta attorno al solo dente: il marcatore dell'osso resta fuori.
                within: BoxMM(
                    minMM: phantom.toothSeedMM - Vec3(2, 2, 2),
                    maxMM: phantom.toothSeedMM + Vec3(2, 2, 2))
            )
        }
    }

    @Test("Una scatola che non tocca il volume si rifiuta invece di non fare niente")
    func boxOutsideTheVolumeIsRefused() throws {
        let phantom = try makeToothPhantom()
        #expect(throws: SegmentKitError.cropOutsideVolume) {
            _ = try CompetitiveGrowth.grow(
                in: phantom.volume,
                seeds: [(seedMM: phantom.toothSeedMM, label: 2)],
                densityRange: 900...4000,
                within: BoxMM(minMM: Vec3(500, 500, 500), maxMM: Vec3(600, 600, 600))
            )
        }
    }

    @Test("Anche il riempimento semplice si lascia confinare")
    func regionGrowingHonoursTheBox() throws {
        let phantom = try makeToothPhantom(apexContact: true)
        let free = try RegionGrowing.grow(
            in: phantom.volume, fromSeedMM: phantom.toothSeedMM, densityRange: 900...4000)
        let confined = try RegionGrowing.grow(
            in: phantom.volume, fromSeedMM: phantom.toothSeedMM, densityRange: 900...4000,
            within: toothBox(phantom))

        let freeCount = free.voxelCounts()[1] ?? 0
        let confinedCount = confined.voxelCounts()[1] ?? 0
        // Senza scatola il riempimento cola nell'osso e prende tutto ciò che sta sopra soglia;
        // con la scatola si ferma alle sue facce. Il riempimento semplice non ha contendenti,
        // quindi il suo tetto è esattamente ciò che nella scatola sta sopra soglia — e non il
        // dente: separare non è compito suo.
        #expect(freeCount > phantom.toothVoxelCount * 5)
        #expect(confinedCount >= phantom.toothVoxelCount)
        #expect(confinedCount <= voxelsAboveThreshold(in: toothBox(phantom), of: phantom))
        #expect(confinedCount < freeCount / 3)
    }

    @Test("Fuori dalla scatola non resta etichettato nemmeno un voxel")
    func nothingIsLabelledOutsideTheBox() throws {
        let phantom = try makeToothPhantom(apexContact: true)
        let box = toothBox(phantom)
        let mask = try CompetitiveGrowth.grow(
            in: phantom.volume,
            seeds: [(seedMM: phantom.toothSeedMM, label: 2)],
            densityRange: 900...4000,
            within: box
        )
        let geometry = phantom.geometry
        var strays = 0
        for k in 0..<geometry.sliceCount {
            for j in 0..<geometry.rowCount {
                for i in 0..<geometry.columnCount
                where mask.label(i: i, j: j, k: k) != VolumeMask.background {
                    if !box.contains(geometry.patientPoint(i: i, j: j, k: k)) { strays += 1 }
                }
            }
        }
        #expect(strays == 0)
    }

    @Test("La soglia dentro il riquadro dà l'arcata invece del pezzo più grosso che c'è")
    func thresholdInsideTheBoxGivesTheArch() throws {
        // Due blocchi densi separati: l'arcata, più piccola, e qualcosa di più voluminoso
        // altrove — che su una CBCT vera è la colonna, o il mento appoggiato al mentoniera.
        // «Tieni il pezzo più grande» da solo restituisce il secondo, ed è esattamente il modo
        // in cui questo comando delude chi voleva stampare la mandibola.
        let side = 48
        let spacing = 0.4
        let orientation = try #require(
            SliceOrientation(columnDirection: Vec3(1, 0, 0), rowDirection: Vec3(0, 1, 0)))
        let geometry = try VolumeGeometry(
            columnCount: side, rowCount: side, sliceCount: side,
            columnSpacingMM: spacing, rowSpacingMM: spacing, sliceSpacingMM: spacing,
            orientation: orientation, originMM: Vec3(0, 0, 0))

        var samples = [Int16](repeating: 0, count: side * side * side)
        var archVoxels = 0, spineVoxels = 0
        for k in 0..<side {
            for j in 0..<side {
                for i in 0..<side {
                    let index = (k * side + j) * side + i
                    if (5..<15).contains(k), (4..<44).contains(i), (4..<18).contains(j) {
                        samples[index] = 1200
                        archVoxels += 1
                    }
                    if (5..<40).contains(k), (10..<38).contains(i), (28..<44).contains(j) {
                        samples[index] = 1500
                        spineVoxels += 1
                    }
                }
            }
        }
        #expect(spineVoxels > archVoxels)

        let volume = try Volume(
            geometry: geometry, samples: samples, rescaleSlope: 1, rescaleIntercept: 0,
            densityUnit: .greyValue)

        let unbounded = try ConnectedComponents.keepingLargest(
            try ThresholdSegmentation.segment(
                volume, densityRange: 900...4000, label: 1, within: nil),
            count: 1)
        #expect((unbounded.voxelCounts()[1] ?? 0) == spineVoxels)

        let archBox = BoxMM(
            minMM: geometry.patientPoint(i: 3, j: 3, k: 4),
            maxMM: geometry.patientPoint(i: 44, j: 20, k: 16))
        let bounded = try ConnectedComponents.keepingLargest(
            try ThresholdSegmentation.segment(
                volume, densityRange: 900...4000, label: 1, within: nil, insideBoxMM: archBox),
            count: 1)
        #expect((bounded.voxelCounts()[1] ?? 0) == archVoxels)
    }
}
