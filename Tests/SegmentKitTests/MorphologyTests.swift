import DICOMCore
import Testing

@testable import SegmentKit

@Suite("Morfologia anisotropa")
struct MorphologyTests {
    @Test("La dilatazione converte un millimetro nei raggi specifici per asse")
    func dilationUsesMillimetresPerAxis() throws {
        let geometry = try makeMorphologyGeometry(columns: 15, rows: 15, slices: 9)
        var mask = try #require(VolumeMask(geometry: geometry))
        mask.setLabel(1, i: 7, j: 7, k: 4)

        let grown = try Morphology.dilated(mask, byMM: 1)
        let bounds = try #require(grown.voxelBounds(label: 1))

        #expect(bounds.min == (3, 3, 2))
        #expect(bounds.max == (11, 11, 6))
    }

    @Test("L'apertura di una sfera grande conserva la maggior parte del volume")
    func openingApproximatelyRoundTripsLargeSphere() throws {
        let geometry = try makeMorphologyGeometry(columns: 41, rows: 41, slices: 21)
        var mask = try #require(VolumeMask(geometry: geometry))
        let center = (i: 20, j: 20, k: 10)
        for k in 0..<geometry.sliceCount {
            for j in 0..<geometry.rowCount {
                for i in 0..<geometry.columnCount {
                    let dx = Double(i - center.i) * 0.25
                    let dy = Double(j - center.j) * 0.25
                    let dz = Double(k - center.k) * 0.50
                    if dx * dx + dy * dy + dz * dz <= 9 {
                        mask.setLabel(6, i: i, j: j, k: k)
                    }
                }
            }
        }
        let originalCount = try #require(mask.voxelCounts()[6])

        let opened = try Morphology.opened(mask, byMM: 1)
        let openedCount = try #require(opened.voxelCounts()[6])

        #expect(openedCount <= originalCount)
        #expect(Double(openedCount) / Double(originalCount) >= 0.70)
    }

    @Test("L'apertura elimina un granello inferiore al raggio")
    func openingRemovesSmallSpeck() throws {
        let geometry = try makeMorphologyGeometry(columns: 9, rows: 9, slices: 7)
        var mask = try #require(VolumeMask(geometry: geometry))
        mask.setLabel(4, i: 4, j: 4, k: 3)

        let opened = try Morphology.opened(mask, byMM: 1)

        #expect(opened.voxelCounts().isEmpty)
    }

    @Test("La chiusura riempie un piccolo buco interno")
    func closingFillsSmallHole() throws {
        let geometry = try makeMorphologyGeometry(columns: 11, rows: 11, slices: 9)
        var mask = try #require(VolumeMask(geometry: geometry))
        for k in 2...6 {
            for j in 2...8 {
                for i in 2...8 {
                    mask.setLabel(2, i: i, j: j, k: k)
                }
            }
        }
        mask.setLabel(VolumeMask.background, i: 5, j: 5, k: 4)

        let closed = try Morphology.closed(mask, byMM: 1)

        #expect(closed.label(i: 5, j: 5, k: 4) == 2)
    }

    @Test("Parametri di raggio non validi producono errori nominati")
    func invalidRadiiThrowNamedErrors() throws {
        let geometry = try makeMorphologyGeometry(columns: 3, rows: 3, slices: 3)
        let mask = try #require(VolumeMask(geometry: geometry))

        var negative: SegmentKitError?
        do {
            _ = try Morphology.dilated(mask, byMM: -0.01)
        } catch let error as SegmentKitError {
            negative = error
        } catch {
        }
        var nonFinite: SegmentKitError?
        do {
            _ = try Morphology.eroded(mask, byMM: .infinity)
        } catch let error as SegmentKitError {
            nonFinite = error
        } catch {
        }

        #expect(negative == .invalidMorphologyRadiusMM(-0.01))
        #expect(nonFinite == .invalidMorphologyRadiusMM(.infinity))
    }

    @Test("Il raggio zero lascia invariata la maschera")
    func zeroRadiusPreservesMask() throws {
        let geometry = try makeMorphologyGeometry(columns: 4, rows: 3, slices: 2)
        var mask = try #require(VolumeMask(geometry: geometry))
        mask.setLabel(5, i: 0, j: 1, k: 1)
        mask.setLabel(9, i: 3, j: 2, k: 0)

        let dilated = try Morphology.dilated(mask, byMM: 0)
        let eroded = try Morphology.eroded(mask, byMM: 0)

        #expect(dilated.labels == mask.labels)
        #expect(eroded.labels == mask.labels)
    }

    @Test("La dilatazione conserva il centro e risolve le distanze pari con l'etichetta minore")
    func dilationPreservesExistingLabelsAndBreaksTiesByLowerLabel() throws {
        let geometry = try makeMorphologyGeometry(columns: 7, rows: 1, slices: 1)
        var mask = try #require(VolumeMask(geometry: geometry))
        mask.setLabel(8, i: 1, j: 0, k: 0)
        mask.setLabel(3, i: 5, j: 0, k: 0)

        let grown = try Morphology.dilated(mask, byMM: 0.5)

        #expect(grown.label(i: 1, j: 0, k: 0) == 8)
        #expect(grown.label(i: 3, j: 0, k: 0) == 3)
    }

    @Test("La provenienza originale preferisce il vicino multi-asse anche se ha etichetta maggiore")
    func dilationUsesClosestOriginalVoxelAcrossAxes() throws {
        let geometry = try makeMorphologyGeometry(columns: 6, rows: 2, slices: 1)
        var mask = try #require(VolumeMask(geometry: geometry))
        mask.setLabel(8, i: 0, j: 1, k: 0)
        mask.setLabel(3, i: 5, j: 0, k: 0)

        let grown = try Morphology.dilated(mask, byMM: 1.25)

        #expect(grown.label(i: 0, j: 0, k: 0) == 8)
    }

    @Test("Un pareggio multi-asse sceglie l'etichetta minore indipendentemente dall'ordine delle passate")
    func dilationBreaksOriginalMultiAxisTieByLowerLabel() throws {
        let geometry = try makeMorphologyGeometry(columns: 4, rows: 4, slices: 1)
        var mask = try #require(VolumeMask(geometry: geometry))
        mask.setLabel(8, i: 1, j: 2, k: 0)
        mask.setLabel(3, i: 2, j: 1, k: 0)

        let grown = try Morphology.dilated(mask, byMM: 0.25)

        #expect(grown.label(i: 2, j: 2, k: 0) == 3)
    }

    @Test("Un raggio almeno quanto la dimensione resta sicuro ai bordi")
    func radiusAtLeastDimensionDilatesAndErodesWithoutTrapping() throws {
        let geometry = try makeMorphologyGeometry(columns: 3, rows: 3, slices: 1)
        var seed = try #require(VolumeMask(geometry: geometry))
        seed.setLabel(7, i: 0, j: 0, k: 0)
        var solid = try #require(VolumeMask(geometry: geometry))
        for j in 0..<geometry.rowCount {
            for i in 0..<geometry.columnCount {
                solid.setLabel(7, i: i, j: j, k: 0)
            }
        }

        let dilated = try Morphology.dilated(seed, byMM: 100)
        let eroded = try Morphology.eroded(solid, byMM: 100)

        #expect(dilated.voxelCounts()[7] == 9)
        #expect(eroded.voxelCounts().isEmpty)
    }
}

private func makeMorphologyGeometry(columns: Int, rows: Int, slices: Int) throws -> VolumeGeometry {
    let orientation = try #require(
        SliceOrientation(columnDirection: Vec3(1, 0, 0), rowDirection: Vec3(0, 1, 0))
    )
    return try VolumeGeometry(
        columnCount: columns,
        rowCount: rows,
        sliceCount: slices,
        columnSpacingMM: 0.25,
        rowSpacingMM: 0.25,
        sliceSpacingMM: 0.50,
        orientation: orientation,
        originMM: Vec3(0, 0, 0)
    )
}
