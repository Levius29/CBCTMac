import DICOMCore
import Testing

@testable import SegmentKit

@Suite("Soglie e crescita di regione")
struct ThresholdRegionGrowingTests {
    @Test("La soglia seleziona solo i voxel della regione fornita")
    func thresholdRespectsWithinRegion() throws {
        let volume = try makeLinearVolume(samples: [-2, -1, 0, 1, 2], slope: 1, intercept: 0)
        var within = try #require(VolumeMask(geometry: volume.geometry))
        within.setLabel(9, i: 1, j: 0, k: 0)
        within.setLabel(9, i: 3, j: 0, k: 0)

        let mask = try ThresholdSegmentation.segment(
            volume, densityRange: -1...1, label: 4, within: within
        )

        #expect(mask.labels == [0, 4, 0, 4, 0])
    }

    @Test("Una slope negativa seleziona gli stessi voxel grezzi equivalenti")
    func negativeSlopeSelectsEquivalentRawVoxels() throws {
        let positive = try makeLinearVolume(samples: [-2, -1, 0, 1, 2], slope: 1, intercept: 0)
        let negative = try makeLinearVolume(samples: [2, 1, 0, -1, -2], slope: -1, intercept: 0)
        let a = try ThresholdSegmentation.segment(positive, densityRange: -1...1, label: 1, within: nil)
        let b = try ThresholdSegmentation.segment(negative, densityRange: -1...1, label: 1, within: nil)

        #expect(a.labels == [0, 1, 1, 1, 0])
        #expect(b.labels == [0, 1, 1, 1, 0])
        #expect(!b.voxelCounts().isEmpty)
        #expect(a.labels == b.labels)
    }

    @Test("Lo sfondo non può essere usato come etichetta di segmentazione")
    func segmentationRejectsBackgroundLabel() throws {
        let volume = try makeLinearVolume(samples: [0])

        var caught: SegmentKitError?
        do {
            _ = try ThresholdSegmentation.segment(volume, densityRange: 0...0, label: .zero, within: nil)
        } catch let error as SegmentKitError {
            caught = error
        } catch {
        }

        #expect(caught == .backgroundLabelNotAllowed)
    }

    @Test("La connettività diagonale differisce da quella per facce")
    func diagonalConnectivityDiffers() throws {
        let volume = try makeDiagonalPairVolume()
        let seed = volume.geometry.patientPoint(i: 1, j: 1, k: 1)
        let faces = try RegionGrowing.grow(in: volume, fromSeedMM: seed, densityRange: 100...100)
        let full = try RegionGrowing.grow(
            in: volume, fromSeedMM: seed, densityRange: 100...100, connectivity: .full
        )

        #expect(faces.voxelCounts()[1] == 1)
        #expect(full.voxelCounts()[1] == 2)
    }

    @Test("Il seme Patient viene convertito al voxel più vicino")
    func patientSeedGrowsExpectedRegion() throws {
        let volume = try makeLinearVolume(
            samples: [0, 100, 100, 0], columns: 4, rows: 1, slices: 1,
            slope: 1, intercept: 0, origin: Vec3(10, -3, 8)
        )
        let seed = volume.geometry.patientPoint(fromVoxel: Vec3(1.4, 0, 0))

        let mask = try RegionGrowing.grow(in: volume, fromSeedMM: seed, densityRange: 100...100)

        #expect(mask.labels == [0, 1, 1, 0])
    }

    @Test("I semi multipli mantengono le etichette nelle regioni disgiunte")
    func multipleSeedsGrowTheirOwnLabels() throws {
        let volume = try makeLinearVolume(samples: [100, 100, 0, 100, 100], columns: 5, rows: 1, slices: 1)
        let left = volume.geometry.patientPoint(i: 0, j: 0, k: 0)
        let right = volume.geometry.patientPoint(i: 4, j: 0, k: 0)

        let mask = try RegionGrowing.grow(
            in: volume,
            seeds: [(left, 3), (right, 8)],
            densityRange: 100...100
        )

        #expect(mask.labels == [3, 3, 0, 8, 8])
    }

    @Test("Due semi sovrapposti con etichette diverse segnalano il conflitto nominato")
    func duplicateSeedsWithDifferentLabelsThrowConflict() throws {
        let volume = try makeLinearVolume(samples: [100])
        let seed = volume.geometry.patientPoint(i: 0, j: 0, k: 0)

        var caught: SegmentKitError?
        do {
            _ = try RegionGrowing.grow(
                in: volume,
                seeds: [(seed, 3), (seed, 8)],
                densityRange: 100...100
            )
        } catch let error as SegmentKitError {
            caught = error
        } catch {
        }

        #expect(caught == .seedLabelConflict(index: 0, first: 3, second: 8))
    }

    @Test("La soglia isola il cubo corticale del fantoccio nella regione centrale")
    func phantomThresholdSelectsCorticalCubeWithinCentralRegion() throws {
        let volume = try SyntheticVolume.makePhantom(
            columns: 120, rows: 120, slices: 120, spacingMM: Vec3(0.5, 0.5, 0.5)
        )
        let halfEdge = SyntheticVolume.cubeEdgeMM / 2
        let expectedCube = try makeAnalyticPatientBoxMask(
            geometry: volume.geometry,
            box: BoxMM(
                minMM: Vec3(-halfEdge, -halfEdge, -halfEdge),
                maxMM: Vec3(halfEdge, halfEdge, halfEdge)
            )
        )
        let regionHalfEdge = halfEdge + 2
        let centralRegion = try makeAnalyticPatientBoxMask(
            geometry: volume.geometry,
            box: BoxMM(
                minMM: Vec3(-regionHalfEdge, -regionHalfEdge, -regionHalfEdge),
                maxMM: Vec3(regionHalfEdge, regionHalfEdge, regionHalfEdge)
            )
        )

        let mask = try ThresholdSegmentation.segment(
            volume, densityRange: 1100...1300, label: 1, within: centralRegion
        )

        let regionVoxelCount = centralRegion.voxelCounts()[1] ?? 0
        let cubeVoxelCount = expectedCube.voxelCounts()[1] ?? 0
        #expect(regionVoxelCount > cubeVoxelCount)
        #expect(mask.labels == expectedCube.labels)
    }

    @Test("La crescita dal centro del cubo non raggiunge le sfere del fantoccio")
    func phantomGrowthContainsCubeButNoSphereCenters() throws {
        let volume = try SyntheticVolume.makePhantom(
            columns: 120, rows: 120, slices: 120, spacingMM: Vec3(0.5, 0.5, 0.5)
        )
        let mask = try RegionGrowing.grow(
            in: volume,
            fromSeedMM: Vec3(0, 0, 0),
            densityRange: 1100...1300
        )
        let halfEdge = SyntheticVolume.cubeEdgeMM / 2
        let expectedCube = try makeAnalyticPatientBoxMask(
            geometry: volume.geometry,
            box: BoxMM(
                minMM: Vec3(-halfEdge, -halfEdge, -halfEdge),
                maxMM: Vec3(halfEdge, halfEdge, halfEdge)
            )
        )

        #expect(mask.labels == expectedCube.labels)
    }

    @Test("Un limite di voxel interrompe la crescita con un errore nominato")
    func maximumVoxelCountStopsGrowth() throws {
        let volume = try makeLinearVolume(samples: [100, 100, 100], columns: 3, rows: 1, slices: 1)
        let seed = volume.geometry.patientPoint(i: 0, j: 0, k: 0)

        var caught: SegmentKitError?
        do {
            _ = try RegionGrowing.grow(
                in: volume, fromSeedMM: seed, densityRange: 100...100, maximumVoxels: 2
            )
        } catch let error as SegmentKitError {
            caught = error
        } catch {
        }

        #expect(caught == .maximumVoxelCountExceeded(maximum: 2))
    }

    @Test("La crescita su otto milioni di voxel non usa lo stack di chiamate")
    func iterativeGrowthHandlesFullTwoHundredCubedVolume() throws {
        let count = 200 * 200 * 200
        let volume = try makeLinearVolume(
            samples: [Int16](repeating: 100, count: count), columns: 200, rows: 200, slices: 200
        )
        let seed = volume.geometry.patientPoint(i: 100, j: 100, k: 100)

        let mask = try RegionGrowing.grow(in: volume, fromSeedMM: seed, densityRange: 100...100)

        #expect(mask.voxelCounts()[1] == count)
    }
}

private func makeLinearVolume(
    samples: [Int16],
    columns: Int? = nil,
    rows: Int = 1,
    slices: Int = 1,
    slope: Double = 1,
    intercept: Double = 0,
    origin: Vec3 = Vec3(0, 0, 0)
) throws -> Volume {
    let columnCount = columns ?? samples.count
    let orientation = try #require(SliceOrientation(columnDirection: Vec3(1, 0, 0), rowDirection: Vec3(0, 1, 0)))
    let geometry = try VolumeGeometry(
        columnCount: columnCount,
        rowCount: rows,
        sliceCount: slices,
        columnSpacingMM: 1,
        rowSpacingMM: 1,
        sliceSpacingMM: 1,
        orientation: orientation,
        originMM: origin
    )
    return try Volume(geometry: geometry, samples: samples, rescaleSlope: slope, rescaleIntercept: intercept)
}

private func makeDiagonalPairVolume() throws -> Volume {
    let columns = 3
    let rows = 3
    let slices = 3
    var samples = [Int16](repeating: 0, count: columns * rows * slices)
    samples[(1 * rows + 1) * columns + 1] = 100
    samples[(2 * rows + 2) * columns + 2] = 100
    return try makeLinearVolume(samples: samples, columns: columns, rows: rows, slices: slices)
}
