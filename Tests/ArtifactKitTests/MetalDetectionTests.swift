import ArtifactKit
import DICOMCore
import SegmentKit
import Testing

@Suite("Rilevamento del metallo")
struct MetalDetectionTests {
    @Test("La soglia suggerita segue il rescale del volume")
    func suggestedThresholdUsesGreyValueScale() throws {
        var samples = [Int16](repeating: 100, count: 995)
        samples.append(contentsOf: [900, 910, 920, 930, 940])
        let first = try makeArtifactVolume(
            columns: 1000, rows: 1, slices: 1, samples: samples,
            slope: 1, intercept: 0
        )
        let second = try makeArtifactVolume(
            columns: 1000, rows: 1, slices: 1, samples: samples,
            slope: 2, intercept: -50
        )

        let a = MetalDetection.suggestedThresholdGV(for: first)
        let b = MetalDetection.suggestedThresholdGV(for: second)

        #expect(a > 100 && a < 940)
        #expect(abs(b - (a * 2 - 50)) < 1e-9)

        var negativeSamples = [Int16](repeating: 900, count: 995)
        negativeSamples.append(contentsOf: [100, 90, 80, 70, 60])
        let negative = try makeArtifactVolume(
            columns: 1000, rows: 1, slices: 1, samples: negativeSamples,
            slope: -1, intercept: 1000
        )
        let negativeThreshold = MetalDetection.suggestedThresholdGV(for: negative)
        #expect(negativeThreshold > 100 && negativeThreshold < 940)
    }

    @Test("Le regioni riportano volume, baricentro e intervallo di slice esatti")
    func detectReportsConnectedRegions() throws {
        let columns = 4
        let rows = 3
        let slices = 3
        var samples = [Int16](repeating: 10, count: columns * rows * slices)
        samples[(0 * rows + 1) * columns + 1] = 1000
        samples[(1 * rows + 1) * columns + 1] = 1000
        samples[(2 * rows + 2) * columns + 3] = 1000
        let volume = try makeArtifactVolume(
            columns: columns,
            rows: rows,
            slices: slices,
            samples: samples,
            columnSpacingMM: 0.5,
            rowSpacingMM: 1,
            sliceSpacingMM: 2
        )

        let detection = try MetalDetection.detect(
            in: volume,
            thresholdGV: 900,
            minimumVolumeMM3: 1.5
        )

        #expect(detection.regions.count == 1)
        let region = try #require(detection.regions.first)
        #expect(region.volumeMM3 == 2)
        #expect(region.sliceRange == 0...1)
        #expect(region.centroidMM.isApproximatelyEqual(to: Vec3(0.5, 1, 1), tolerance: 1e-12))
        #expect(detection.mask.voxelCounts()[region.label] == 2)
    }
}
