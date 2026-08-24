import DICOMCore
import Foundation
import Testing

@testable import SegmentKit

// Separare due cose che si toccano.
//
// # Il fantoccio, e perché è fatto così
//
// Due blocchi densi uniti da un ponte più scuro, lungo l'asse x. È il dente e l'osso ridotti
// all'osso: la radice sta dentro la mandibola, dentina e corticale hanno densità che si
// sovrappongono, e fra le due c'è lo spazio del legamento parodontale — un avvallamento, non un
// muro. Nessuna soglia lo separa, perché il ponte sta **sopra** la soglia che comprende la
// dentina; solo la competizione lo trova, perché è il punto più scuro del percorso.
//
// La prova che conta è la prima: il confine deve cadere **nel mezzo del ponte**, dove il dato è
// più debole, e non dove capita. Un riempimento normale, sullo stesso fantoccio, dà tutto a chi
// parte per primo — ed è la prova che segue.

@Suite("Crescita competitiva")
struct CompetitiveGrowthTests {

    /// Due blocchi a 2000, un ponte che scende fino a 900 nel mezzo, sfondo a 0.
    ///
    /// I blocchi stanno a x ∈ [2,9] e x ∈ [22,29]; il ponte a x ∈ [10,21] con un avvallamento a
    /// forma di V che tocca il minimo esattamente a x = 16.
    private func makeBridgedVolume(
        bridgeFloor: Double = 900, blockValue: Double = 2000
    ) throws -> Volume {
        let geometry = try VolumeGeometry(
            columnCount: 32, rowCount: 12, sliceCount: 12,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: .standardAxial, originMM: Vec3(0, 0, 0))

        var samples = [Int16](repeating: 0, count: geometry.voxelCount)
        for k in 2..<10 {
            for j in 2..<10 {
                for i in 0..<32 {
                    let value: Double
                    switch i {
                    case 2...9, 22...29:
                        value = blockValue
                    case 10...21:
                        // V simmetrica: il minimo cade a 16, cioè fra 15 e 16 non c'è dubbio su
                        // quale sia il punto più scuro.
                        let distance = Double(abs(i - 16))
                        value = bridgeFloor + (blockValue - bridgeFloor) * (distance / 6)
                    default:
                        value = 0
                    }
                    let index = i + j * 32 + k * 32 * 12
                    samples[index] = Int16(value.rounded())
                }
            }
        }
        return try Volume(geometry: geometry, samples: samples)
    }

    private func label(_ mask: VolumeMask, atX x: Int) -> SegmentLabel {
        mask.label(i: x, j: 6, k: 6)
    }

    @Test("Il confine cade nel punto più scuro del ponte, non dove passa una soglia")
    func theBorderFallsAtTheDarkestPoint() throws {
        let volume = try makeBridgedVolume()
        let mask = try CompetitiveGrowth.grow(
            in: volume,
            seeds: [
                (seedMM: Vec3(5, 6, 6), label: 1),
                (seedMM: Vec3(26, 6, 6), label: 2),
            ],
            densityRange: 500...4000)

        // Ogni blocco resta suo.
        #expect(label(mask, atX: 3) == 1)
        #expect(label(mask, atX: 9) == 1)
        #expect(label(mask, atX: 23) == 2)
        #expect(label(mask, atX: 28) == 2)

        // Il ponte si divide **a metà**, che è dove sta il minimo.
        for x in 10...15 { #expect(label(mask, atX: x) == 1, "x=\\(x) doveva essere del primo") }
        for x in 17...21 { #expect(label(mask, atX: x) == 2, "x=\\(x) doveva essere del secondo") }
        // Il voxel del minimo va a uno dei due, non allo sfondo: nessun buco nel modello.
        #expect(label(mask, atX: 16) != VolumeMask.background)
    }

    @Test("Il riempimento normale invece dà tutto al primo che arriva")
    func plainFloodFillLeaks() throws {
        // È il difetto per cui questa crescita esiste, messo per iscritto: sullo stesso
        // fantoccio, con la stessa soglia, il riempimento non separa niente.
        let volume = try makeBridgedVolume()
        let mask = try RegionGrowing.grow(
            in: volume, fromSeedMM: Vec3(5, 6, 6),
            densityRange: 500...4000, label: 1)

        // Il seme è nel primo blocco, e la regione arriva fino in fondo al secondo.
        #expect(label(mask, atX: 3) == 1)
        #expect(label(mask, atX: 28) == 1, "il riempimento è colato nel secondo blocco")
    }

    @Test("Il confine segue il minimo anche quando lo si sposta")
    func theBorderFollowsTheMinimum() throws {
        // Ponte asimmetrico: il minimo a x = 12 invece che a 16. Il confine deve seguirlo — se
        // cadesse sempre a metà strada fra i semi, questa prova lo scoprirebbe e la prima no.
        let geometry = try VolumeGeometry(
            columnCount: 32, rowCount: 12, sliceCount: 12,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: .standardAxial, originMM: Vec3(0, 0, 0))
        var samples = [Int16](repeating: 0, count: geometry.voxelCount)
        for k in 2..<10 {
            for j in 2..<10 {
                for i in 2..<30 {
                    // Rampa che scende fino a 12 e poi risale: minimo netto a sinistra.
                    let value = i <= 12
                        ? 2000 - Double(i - 2) * 100
                        : 1000 + Double(i - 12) * 60
                    samples[i + j * 32 + k * 32 * 12] = Int16(value.rounded())
                }
            }
        }
        let volume = try Volume(geometry: geometry, samples: samples)

        let mask = try CompetitiveGrowth.grow(
            in: volume,
            seeds: [
                (seedMM: Vec3(3, 6, 6), label: 1),
                (seedMM: Vec3(28, 6, 6), label: 2),
            ],
            densityRange: 500...4000)

        #expect(label(mask, atX: 5) == 1)
        #expect(label(mask, atX: 25) == 2)
        // Il confine sta attorno al minimo, non a metà fra i due semi, che sarebbe x ≈ 15.
        var border = 0
        for x in 3..<28 where label(mask, atX: x) == 1 { border = x }
        #expect(border <= 14, "il confine è a \\(border), lontano dal minimo")
        #expect(border >= 10, "il confine è a \\(border), troppo a sinistra del minimo")
    }

    @Test("Tre regioni si spartiscono senza sovrapporsi né lasciare buchi")
    func threeRegionsPartitionCleanly() throws {
        let volume = try makeBridgedVolume()
        let mask = try CompetitiveGrowth.grow(
            in: volume,
            seeds: [
                (seedMM: Vec3(3, 6, 6), label: 1),
                (seedMM: Vec3(8, 6, 6), label: 1),
                (seedMM: Vec3(26, 6, 6), label: 2),
            ],
            densityRange: 500...4000)

        // Due semi con la stessa etichetta fanno una regione sola: è il modo di marcare l'osso
        // in più punti senza spezzarlo.
        #expect(label(mask, atX: 3) == 1)
        #expect(label(mask, atX: 8) == 1)

        // Nessun voxel sopra soglia resta senza padrone.
        var unassigned = 0
        for k in 2..<10 {
            for j in 2..<10 {
                for i in 2..<30 where mask.label(i: i, j: j, k: k) == VolumeMask.background {
                    unassigned += 1
                }
            }
        }
        #expect(unassigned == 0)
    }

    @Test("Fuori dalla fascia di densità non si assegna niente")
    func nothingIsAssignedOutsideTheBand() throws {
        let volume = try makeBridgedVolume()
        let mask = try CompetitiveGrowth.grow(
            in: volume,
            seeds: [(seedMM: Vec3(5, 6, 6), label: 1)],
            densityRange: 1800...4000)

        // Solo i blocchi, che stanno a 2000. Il ponte scende sotto e resta fuori.
        #expect(label(mask, atX: 5) == 1)
        #expect(label(mask, atX: 16) == VolumeMask.background)
        // E il secondo blocco non è connesso al seme dentro questa fascia.
        #expect(label(mask, atX: 26) == VolumeMask.background)
    }

    @Test("Un seme fuori dal volume o fuori soglia è un errore, non un risultato vuoto")
    func badSeedsAreErrors() throws {
        let volume = try makeBridgedVolume()
        #expect(throws: SegmentKitError.self) {
            _ = try CompetitiveGrowth.grow(
                in: volume, seeds: [(seedMM: Vec3(500, 500, 500), label: 1)],
                densityRange: 500...4000)
        }
        // Seme nell'aria, che sta a zero.
        #expect(throws: SegmentKitError.self) {
            _ = try CompetitiveGrowth.grow(
                in: volume, seeds: [(seedMM: Vec3(0, 0, 0), label: 1)],
                densityRange: 500...4000)
        }
        // Etichetta di sfondo: non identifica una regione.
        #expect(throws: SegmentKitError.self) {
            _ = try CompetitiveGrowth.grow(
                in: volume, seeds: [(seedMM: Vec3(5, 6, 6), label: 0)],
                densityRange: 500...4000)
        }
    }

    @Test("La regione non esce dal bordo della riga rientrando dall'altra parte")
    func regionsDoNotWrapAroundRowEdges() throws {
        // In un indice lineare il voxel all'estrema destra di una riga e quello all'estrema
        // sinistra della successiva distano uno: senza il controllo sulle coordinate, la regione
        // esce da una parte e rientra dall'altra. Il fantoccio ha densità alta fino al bordo.
        let geometry = try VolumeGeometry(
            columnCount: 16, rowCount: 8, sliceCount: 4,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: .standardAxial, originMM: Vec3(0, 0, 0))
        var samples = [Int16](repeating: 0, count: geometry.voxelCount)
        // Solo due colonne: l'ultima della riga 2 e la prima della riga 3.
        samples[15 + 2 * 16 + 1 * 128] = 2000
        samples[0 + 3 * 16 + 1 * 128] = 2000
        let volume = try Volume(geometry: geometry, samples: samples)

        let mask = try CompetitiveGrowth.grow(
            in: volume, seeds: [(seedMM: Vec3(15, 2, 1), label: 1)],
            densityRange: 500...4000)

        #expect(mask.label(i: 15, j: 2, k: 1) == 1)
        #expect(
            mask.label(i: 0, j: 3, k: 1) == VolumeMask.background,
            "la regione ha scavalcato il bordo della riga")
    }
}
