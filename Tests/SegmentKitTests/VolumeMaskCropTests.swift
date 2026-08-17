import DICOMCore
import Testing

@testable import SegmentKit

@Suite("Maschere e ritagli di volume")
struct VolumeMaskCropTests {
    @Test("Rifiuta una maschera oltre il limite di 400 milioni di voxel")
    func rejectsMaskBeyondMaximumVoxelCount() throws {
        let geometry = try makeGeometry(columns: VolumeMask.maximumVoxelCount + 1, rows: 1, slices: 1)
        #expect(VolumeMask(geometry: geometry) == nil)
    }

    @Test("Conta etichette, volume e riquadro senza includere lo sfondo")
    func maskCountsAndBounds() throws {
        var mask = try #require(VolumeMask(geometry: try makeGeometry(columns: 4, rows: 3, slices: 2)))
        mask.setLabel(7, i: 1, j: 1, k: 0)
        mask.setLabel(7, i: 2, j: 2, k: 1)
        mask.setLabel(3, i: 3, j: 0, k: 1)

        #expect(mask.voxelCounts() == [7: 2, 3: 1])
        #expect(mask.volumeMM3(label: 7) == 3.08)
        #expect(mask.volumeMM3(label: nil) == 4.62)
        let labelBounds = try #require(mask.voxelBounds(label: 7))
        #expect(labelBounds.min.0 == 1 && labelBounds.min.1 == 1 && labelBounds.min.2 == 0)
        #expect(labelBounds.max.0 == 2 && labelBounds.max.1 == 2 && labelBounds.max.2 == 1)
        let allBounds = try #require(mask.voxelBounds(label: nil))
        #expect(allBounds.min.0 == 1 && allBounds.min.1 == 0 && allBounds.min.2 == 0)
        #expect(allBounds.max.0 == 3 && allBounds.max.1 == 2 && allBounds.max.2 == 1)
    }

    @Test("Gli accessi oltre il volume restituiscono sfondo e non modificano la maschera")
    func outOfRangeAccessIsSafe() throws {
        var mask = try #require(VolumeMask(geometry: try makeGeometry(columns: 2, rows: 2, slices: 2)))
        mask.setLabel(4, i: -1, j: 0, k: 0)
        mask.setLabel(4, i: 2, j: 0, k: 0)
        mask.setLabel(4, i: 0, j: 0, k: 2)

        #expect(mask.label(i: -1, j: 0, k: 0) == .zero)
        #expect(mask.label(i: 2, j: 0, k: 0) == .zero)
        #expect(mask.voxelCounts().isEmpty)
    }

    @Test("Unione, sottrazione e inversione rispettano le etichette multiregione")
    func maskAlgebraPreservesLabels() throws {
        let geometry = try makeGeometry(columns: 3, rows: 1, slices: 1)
        var first = try #require(VolumeMask(geometry: geometry))
        var second = try #require(VolumeMask(geometry: geometry))
        first.setLabel(2, i: 0, j: 0, k: 0)
        second.setLabel(2, i: 0, j: 0, k: 0)
        second.setLabel(8, i: 1, j: 0, k: 0)

        let united = try first.union(with: second)
        #expect(united.labels == [2, 8, 0])
        let subtracted = try united.subtracting(second)
        #expect(subtracted.labels == [0, 0, 0])
        #expect(united.inverted().labels == [0, 0, 1])
    }

    @Test("Unione segnala esattamente il conflitto di etichette e la geometria incompatibile")
    func maskAlgebraNamesConflicts() throws {
        let geometry = try makeGeometry(columns: 2, rows: 1, slices: 1)
        var first = try #require(VolumeMask(geometry: geometry))
        var conflicting = try #require(VolumeMask(geometry: geometry))
        first.setLabel(2, i: 0, j: 0, k: 0)
        conflicting.setLabel(5, i: 0, j: 0, k: 0)

        var conflict: SegmentKitError?
        do {
            _ = try first.union(with: conflicting)
        } catch let error as SegmentKitError {
            conflict = error
        } catch {
        }
        #expect(conflict == .labelConflict(index: 0, first: 2, second: 5))

        let different = try #require(VolumeMask(geometry: try makeGeometry(columns: 3, rows: 1, slices: 1)))
        var incompatibility: SegmentKitError?
        do {
            _ = try first.subtracting(different)
        } catch let error as SegmentKitError {
            incompatibility = error
        } catch {
        }
        #expect(incompatibility == .incompatibleGeometry)
    }

    @Test("Il crop conserva coordinate Patient, densità e metadati con orientamento ruotato")
    func cropPreservesPatientCoordinates() throws {
        let source = try makeIndexedVolume(rotated: true)
        let box = patientAlignedBox(
            containingVoxelCorners: [Vec3(1.2, 1.3, 0.4), Vec3(4.2, 4.1, 3.2)],
            geometry: source.geometry
        )
        let cropped = try VolumeCrop.crop(source, toBoxMM: box)
        let patient = source.geometry.patientPoint(i: 3, j: 3, k: 2)
        let croppedVoxel = cropped.geometry.voxelPoint(fromPatient: patient)
        let i = Int(croppedVoxel.x.rounded())
        let j = Int(croppedVoxel.y.rounded())
        let k = Int(croppedVoxel.z.rounded())

        #expect(cropped.geometry.patientPoint(i: i, j: j, k: k)
            .isApproximatelyEqual(to: patient, tolerance: 1e-9))
        #expect(cropped.rawValue(i: i, j: j, k: k) == source.rawValue(i: 3, j: 3, k: 2))
        #expect(cropped.rescaleSlope == source.rescaleSlope)
        #expect(cropped.rescaleIntercept == source.rescaleIntercept)
        #expect(cropped.densityUnit == source.densityUnit)
    }

    @Test("Il crop conservativo contiene anche un riquadro Patient fra i centri voxel")
    func cropConservativelyContainsBox() throws {
        let source = try makeIndexedVolume()
        let box = BoxMM(minMM: Vec3(10.14, 20.22, 30.4), maxMM: Vec3(10.56, 20.88, 31.6))
        let cropped = try VolumeCrop.crop(source, toBoxMM: box)

        #expect(cropped.geometry.columnCount == 2)
        #expect(cropped.geometry.rowCount == 2)
        #expect(cropped.geometry.sliceCount == 2)
        for corner in [
            Vec3(box.minMM.x, box.minMM.y, box.minMM.z),
            Vec3(box.maxMM.x, box.minMM.y, box.minMM.z),
            Vec3(box.minMM.x, box.maxMM.y, box.minMM.z),
            Vec3(box.maxMM.x, box.maxMM.y, box.minMM.z),
            Vec3(box.minMM.x, box.minMM.y, box.maxMM.z),
            Vec3(box.maxMM.x, box.minMM.y, box.maxMM.z),
            Vec3(box.minMM.x, box.maxMM.y, box.maxMM.z),
            Vec3(box.maxMM.x, box.maxMM.y, box.maxMM.z),
        ] {
            let voxel = cropped.geometry.voxelPoint(fromPatient: corner)
            #expect(cropped.geometry.containsVoxel(voxel))
        }
    }

    @Test("Un box appena prima dell'origine include il voxel zero dopo ceil e clamp")
    func cropNearNegativeBoundaryIncludesFirstVoxel() throws {
        let source = try makeIndexedVolume()
        let box = BoxMM(minMM: Vec3(9.86, 20, 30), maxMM: Vec3(9.93, 20, 30))
        let cropped = try VolumeCrop.crop(source, toBoxMM: box)

        #expect(cropped.geometry.columnCount == 1)
        #expect(cropped.geometry.rowCount == 1)
        #expect(cropped.geometry.sliceCount == 1)
        #expect(cropped.rawValue(i: 0, j: 0, k: 0) == source.rawValue(i: 0, j: 0, k: 0))
    }

    @Test("Il crop da maschera applica il margine e richiede la stessa geometria")
    func cropToMaskUsesMarginAndExactGeometry() throws {
        let source = try makeIndexedVolume()
        var mask = try #require(VolumeMask(geometry: source.geometry))
        mask.setLabel(1, i: 2, j: 2, k: 1)
        let cropped = try VolumeCrop.crop(source, toMask: mask, marginMM: 0.5)
        #expect(cropped.geometry.columnCount == 3)
        #expect(cropped.geometry.rowCount == 3)
        #expect(cropped.geometry.sliceCount == 3)

        let mismatched = try #require(VolumeMask(geometry: try makeGeometry(columns: 5)))
        var incompatibility: SegmentKitError?
        do {
            _ = try VolumeCrop.crop(source, toMask: mismatched, marginMM: 0)
        } catch let error as SegmentKitError {
            incompatibility = error
        } catch {
        }
        #expect(incompatibility == .incompatibleGeometry)
    }

    @Test("Un crop fuori dal volume segnala un errore nominato")
    func cropOutsideVolumeThrowsNamedError() throws {
        let source = try makeIndexedVolume()
        let outside = BoxMM(minMM: Vec3(100, 100, 100), maxMM: Vec3(101, 101, 101))
        var error: SegmentKitError?
        do {
            _ = try VolumeCrop.crop(source, toBoxMM: outside)
        } catch let caught as SegmentKitError {
            error = caught
        } catch {
        }
        #expect(error == .cropOutsideVolume)
    }
}
