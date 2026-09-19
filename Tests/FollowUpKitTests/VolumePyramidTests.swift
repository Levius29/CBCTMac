import DICOMCore
import Foundation
import Testing

@testable import FollowUpKit

// Una piramide sbagliata non si vede: la registrazione converge lo stesso, su un punto spostato
// di mezzo voxel per livello. Queste prove guardano la geometria, che è dove sta l'errore.

@Suite("Piramide dei volumi")
struct VolumePyramidTests {

    @Test("Il fattore 1 restituisce lo stesso volume")
    func factorOneChangesNothing() throws {
        let volume = try makeRampVolume()
        let reduced = try VolumePyramid.reduced(volume, by: 1)
        #expect(reduced.geometry == volume.geometry)
        #expect(reduced.samples == volume.samples)
    }

    @Test("Il passo cresce del fattore e le dimensioni calano")
    func reducedGeometryScales() throws {
        let volume = try makeRampVolume(columns: 8, rows: 6, slices: 4)
        let reduced = try VolumePyramid.reduced(volume, by: 2)
        #expect(reduced.geometry.columnCount == 4)
        #expect(reduced.geometry.rowCount == 3)
        #expect(reduced.geometry.sliceCount == 2)
        #expect(abs(reduced.geometry.columnSpacingMM - volume.geometry.columnSpacingMM * 2) < 1e-12)
        #expect(abs(reduced.geometry.rowSpacingMM - volume.geometry.rowSpacingMM * 2) < 1e-12)
        #expect(abs(reduced.geometry.sliceSpacingMM - volume.geometry.sliceSpacingMM * 2) < 1e-12)
    }

    @Test("L'origine cade al centro del primo blocco, non sul suo angolo")
    func reducedOriginSitsAtBlockCentre() throws {
        let volume = try makeRampVolume()
        let reduced = try VolumePyramid.reduced(volume, by: 2)
        let expected = volume.geometry.patientPoint(fromVoxel: Vec3(0.5, 0.5, 0.5))
        #expect(reduced.geometry.originMM.isApproximatelyEqual(to: expected, tolerance: 1e-9))
    }

    @Test("Il valore ridotto è la media del blocco")
    func reducedSampleIsBlockMean() throws {
        let volume = try makeRampVolume()
        let reduced = try VolumePyramid.reduced(volume, by: 2)
        // Blocco (0,0,0): otto voxel con valori 0, 1, 10, 11, 100, 101, 110, 111 → media 55,5.
        let first = try #require(reduced.rawValue(i: 0, j: 0, k: 0))
        #expect(first == 56)
    }

    @Test("Il rescale e l'unità del volume di partenza restano")
    func reducedKeepsRescale() throws {
        let volume = try SyntheticVolume.makePhantom(
            columns: 16, rows: 16, slices: 16, spacingMM: Vec3(1, 1, 1))
        let reduced = try VolumePyramid.reduced(volume, by: 2)
        #expect(reduced.rescaleSlope == volume.rescaleSlope)
        #expect(reduced.rescaleIntercept == volume.rescaleIntercept)
        #expect(reduced.densityUnit == volume.densityUnit)
    }

    @Test("Un fattore nullo o negativo è un errore, non un volume strano")
    func invalidFactorsThrow() throws {
        let volume = try makeRampVolume()
        #expect(throws: VolumeRegistrationError.self) {
            _ = try VolumePyramid.reduced(volume, by: 0)
        }
        #expect(throws: VolumeRegistrationError.self) {
            _ = try VolumePyramid.orderedFactors([2, -1])
        }
        #expect(throws: VolumeRegistrationError.self) {
            _ = try VolumePyramid.orderedFactors([])
        }
    }

    @Test("I fattori si riordinano dal grossolano al fine, senza ripetizioni")
    func factorsAreOrderedCoarseToFine() throws {
        #expect(try VolumePyramid.orderedFactors([1, 4, 2]) == [4, 2, 1])
        #expect(try VolumePyramid.orderedFactors([2, 2, 4]) == [4, 2])
        #expect(VolumePyramid.defaultShrinkFactors == [4, 2, 1])
    }
}
