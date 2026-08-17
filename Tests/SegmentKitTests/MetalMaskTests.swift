import DICOMCore
import Testing

@testable import SegmentKit

@Suite("Maschera del metallo")
struct MetalMaskTests {
    @Test("La soglia in GV conserva soltanto il blocco e il granello a 8000 GV")
    func metalThresholdUsesDensityAndRescale() throws {
        let volume = try makeMetalVolume()

        let mask = try ThresholdSegmentation.metalMask(
            volume, thresholdGV: 8_000, dilationMM: 0, minimumVolumeMM3: 0
        )

        #expect(mask.labels.filter { $0 != VolumeMask.background }.count == 5)
        #expect(mask.label(i: 3, j: 2, k: 1) != VolumeMask.background)
        #expect(mask.label(i: 4, j: 3, k: 1) != VolumeMask.background)
        #expect(mask.label(i: 9, j: 7, k: 3) != VolumeMask.background)
        #expect(mask.label(i: 0, j: 0, k: 0) == VolumeMask.background)
    }

    @Test("La dilatazione fisica copre la penombra e il filtro scarta il granello")
    func metalMaskDilatesInPhysicalAxesAndRemovesIsolatedSpeck() throws {
        let volume = try makeMetalVolume()

        // Con spacing 0,5×1×2 mm, 0,6 mm diventa 2×1×1 voxel. Il blocco 2×2×1 diventa
        // 6×4×3 = 72 voxel, il granello al bordo 4×3×3 = 36 voxel; 37 mm³ separa i casi.
        let mask = try ThresholdSegmentation.metalMask(
            volume, thresholdGV: 8_000, dilationMM: 0.6, minimumVolumeMM3: 37
        )
        let bounds = try #require(mask.voxelBounds(label: 1))

        #expect(mask.voxelCounts()[1] == 72)
        #expect(mask.volumeMM3(label: 1) == 72)
        #expect(bounds.min.0 == 1)
        #expect(bounds.min.1 == 1)
        #expect(bounds.min.2 == 0)
        #expect(bounds.max.0 == 6)
        #expect(bounds.max.1 == 4)
        #expect(bounds.max.2 == 2)

        let originalMinimum = volume.geometry.patientPoint(i: 3, j: 2, k: 1)
        let dilatedMinimum = volume.geometry.patientPoint(i: bounds.min.0, j: bounds.min.1, k: bounds.min.2)
        #expect(originalMinimum.x - dilatedMinimum.x == 1)
        #expect(originalMinimum.y - dilatedMinimum.y == 1)
        #expect(originalMinimum.z - dilatedMinimum.z == 2)
        #expect(mask.label(i: 9, j: 7, k: 3) == VolumeMask.background)
    }

    @Test("I parametri non validi mantengono gli errori nominati dei tre passaggi")
    func metalMaskRejectsInvalidParametersWithExactErrors() throws {
        let volume = try makeMetalVolume()
        var thresholdError: SegmentKitError?
        var dilationError: SegmentKitError?
        var volumeError: SegmentKitError?

        do {
            _ = try ThresholdSegmentation.metalMask(
                volume, thresholdGV: .infinity, dilationMM: 0, minimumVolumeMM3: 0
            )
        } catch let error as SegmentKitError {
            thresholdError = error
        } catch {
        }
        do {
            _ = try ThresholdSegmentation.metalMask(
                volume, thresholdGV: 8_000, dilationMM: -0.1, minimumVolumeMM3: 0
            )
        } catch let error as SegmentKitError {
            dilationError = error
        } catch {
        }
        do {
            _ = try ThresholdSegmentation.metalMask(
                volume, thresholdGV: 8_000, dilationMM: 0, minimumVolumeMM3: -1
            )
        } catch let error as SegmentKitError {
            volumeError = error
        } catch {
        }

        #expect(thresholdError == .invalidMetalThresholdGV(.infinity))
        #expect(dilationError == .invalidMorphologyRadiusMM(-0.1))
        #expect(volumeError == .invalidMinimumComponentVolumeMM3(-1))
    }
}

private func makeMetalVolume() throws -> Volume {
    let orientation = try #require(
        SliceOrientation(columnDirection: Vec3(1, 0, 0), rowDirection: Vec3(0, 1, 0))
    )
    let geometry = try VolumeGeometry(
        columnCount: 11,
        rowCount: 9,
        sliceCount: 5,
        columnSpacingMM: 0.5,
        rowSpacingMM: 1,
        sliceSpacingMM: 2,
        orientation: orientation,
        originMM: Vec3(0, 0, 0)
    )
    var samples = [Int16](repeating: 0, count: geometry.voxelCount)
    for j in 2...3 {
        for i in 3...4 {
            samples[(1 * geometry.rowCount + j) * geometry.columnCount + i] = 4_000
        }
    }
    samples[(3 * geometry.rowCount + 7) * geometry.columnCount + 9] = 4_000
    samples[0] = 3_999
    return try Volume(geometry: geometry, samples: samples, rescaleSlope: 2, rescaleIntercept: 0)
}
