import Foundation
import DICOMCore
import Testing

@testable import SegmentKit

@Suite("Componenti connesse e statistiche")
struct ConnectedComponentsStatisticsTests {
    @Test("Le componenti ignorano la label originale, sono ordinate e hanno centroidi Patient")
    func componentsAreSortedAndCentredInPatientCoordinates() throws {
        let geometry = try makeAnalysisGeometry(columns: 16, rows: 16, slices: 7, rotated: true)
        var mask = try #require(VolumeMask(geometry: geometry))
        let largerCenter = geometry.patientPoint(i: 4, j: 4, k: 3)
        let smallerCenter = geometry.patientPoint(i: 11, j: 10, k: 3)
        fillSphere(in: &mask, center: largerCenter, radiusMM: 3, label: 9)
        fillSphere(in: &mask, center: smallerCenter, radiusMM: 2, label: 2)

        let result = try ConnectedComponents.label(mask)

        #expect(result.components.count == 2)
        #expect(result.components.map(\.label) == [1, 2])
        #expect(result.components[0].voxelCount > result.components[1].voxelCount)
        #expect(result.mask.labels.filter { $0 == 1 }.count == result.components[0].voxelCount)
        #expect(result.components[0].centroidMM.isApproximatelyEqual(
            to: largerCenter, tolerance: 1e-12
        ))
        #expect(result.components[1].centroidMM.isApproximatelyEqual(
            to: smallerCenter, tolerance: 1e-12
        ))
    }

    @Test("Il filtro conserva la più grande e rimuove le componenti sotto il volume minimo")
    func componentFiltersRespectCountAndPhysicalVolume() throws {
        let geometry = try makeAnalysisGeometry(columns: 6, rows: 1, slices: 1)
        var mask = try #require(VolumeMask(geometry: geometry))
        mask.setLabel(6, i: 0, j: 0, k: 0)
        mask.setLabel(7, i: 2, j: 0, k: 0)
        mask.setLabel(8, i: 3, j: 0, k: 0)
        mask.setLabel(7, i: 4, j: 0, k: 0)

        let largest = try ConnectedComponents.keepingLargest(mask, count: 1)
        let filtered = try ConnectedComponents.removingSmaller(than: 12.0, from: mask)

        #expect(largest.labels == [0, 0, 7, 8, 7, 0])
        #expect(filtered.labels == [0, 0, 7, 8, 7, 0])
        let empty = try ConnectedComponents.keepingLargest(mask, count: 0)
        #expect(empty.voxelCounts().isEmpty)
    }

    @Test("Le isole oltre le 255 vengono dichiarate e restano sullo sfondo")
    func componentsBeyondLabelCapacityAreDiscardedExplicitly() throws {
        let geometry = try makeAnalysisGeometry(columns: 511, rows: 1, slices: 1)
        var mask = try #require(VolumeMask(geometry: geometry))
        for (island, i) in stride(from: 0, through: 510, by: 2).enumerated() {
            mask.setLabel(island.isMultiple(of: 2) ? 4 : 9, i: i, j: 0, k: 0)
        }

        let result = try ConnectedComponents.label(mask)
        let thresholdZero = try ConnectedComponents.removingSmaller(than: 0, from: mask)
        let allLargest = try ConnectedComponents.keepingLargest(mask, count: 256)

        #expect(result.components.count == 255)
        #expect(result.discarded == 1)
        #expect(result.mask.labels.filter { $0 != VolumeMask.background }.count == 255)
        #expect(result.mask.label(i: 0, j: 0, k: 0) == 1)
        #expect(result.mask.label(i: 508, j: 0, k: 0) == 255)
        #expect(result.mask.label(i: 510, j: 0, k: 0) == VolumeMask.background)
        #expect(thresholdZero.labels == mask.labels)
        #expect(allLargest.labels == mask.labels)
    }

    @Test("I filtri visitano e preservano le isole oltre la capacità di rietichettamento")
    func componentFiltersVisitBeyondLabelCapacity() throws {
        let geometry = try makeAnalysisGeometry(columns: 513, rows: 1, slices: 1)
        var mask = try #require(VolumeMask(geometry: geometry))
        for (island, i) in stride(from: 0, through: 512, by: 2).enumerated() {
            mask.setLabel(island.isMultiple(of: 2) ? 4 : 9, i: i, j: 0, k: 0)
        }
        var expectedLargest = mask
        expectedLargest.setLabel(.zero, i: 512, j: 0, k: 0)

        let voxelVolume = geometry.columnSpacingMM
            * geometry.rowSpacingMM
            * geometry.sliceSpacingMM
        let thresholded = try ConnectedComponents.removingSmaller(than: voxelVolume, from: mask)
        let largest = try ConnectedComponents.keepingLargest(mask, count: 256)

        #expect(thresholded.labels == mask.labels)
        #expect(largest.labels == expectedLargest.labels)
    }

    @Test("A parità di volume la componente col seme minore riceve la prima label")
    func equalComponentsBreakTiesBySeedIndex() throws {
        let geometry = try makeAnalysisGeometry(columns: 5, rows: 1, slices: 1)
        var mask = try #require(VolumeMask(geometry: geometry))
        mask.setLabel(8, i: 0, j: 0, k: 0)
        mask.setLabel(3, i: 4, j: 0, k: 0)

        let result = try ConnectedComponents.label(mask)

        #expect(result.mask.label(i: 0, j: 0, k: 0) == 1)
        #expect(result.mask.label(i: 4, j: 0, k: 0) == 2)
    }

    @Test("La connettività per facce non unisce un contatto diagonale")
    func faceAndFullConnectivityProduceDifferentComponents() throws {
        let geometry = try makeAnalysisGeometry(columns: 2, rows: 2, slices: 1)
        var mask = try #require(VolumeMask(geometry: geometry))
        mask.setLabel(1, i: 0, j: 0, k: 0)
        mask.setLabel(1, i: 1, j: 1, k: 0)

        let faces = try ConnectedComponents.label(mask, connectivity: .faces)
        let full = try ConnectedComponents.label(mask, connectivity: .full)

        #expect(faces.components.count == 2)
        #expect(full.components.count == 1)
    }

    @Test("I bounds della componente sono un AABB nello spazio Patient")
    func componentBoundsUsePatientCoordinates() throws {
        let geometry = try makeAnalysisGeometry(columns: 4, rows: 3, slices: 2, rotated: true)
        var mask = try #require(VolumeMask(geometry: geometry))
        mask.setLabel(4, i: 1, j: 1, k: 0)
        mask.setLabel(4, i: 2, j: 1, k: 0)

        let summary = try #require(try ConnectedComponents.label(mask).components.first)
        let first = geometry.patientPoint(i: 1, j: 1, k: 0)
        let second = geometry.patientPoint(i: 2, j: 1, k: 0)

        #expect(summary.boundsMM == BoxMM(
            minMM: Vec3(min(first.x, second.x), min(first.y, second.y), min(first.z, second.z)),
            maxMM: Vec3(max(first.x, second.x), max(first.y, second.y), max(first.z, second.z))
        ))
    }

    @Test("I parametri non rappresentabili producono errori nominati")
    func componentFilterRejectsInvalidParameters() throws {
        let geometry = try makeAnalysisGeometry(columns: 1, rows: 1, slices: 1)
        let mask = try #require(VolumeMask(geometry: geometry))

        var negativeCount: SegmentKitError?
        var negativeVolume: SegmentKitError?
        var nonFiniteVolume: SegmentKitError?
        do { _ = try ConnectedComponents.keepingLargest(mask, count: -1) }
        catch let error as SegmentKitError { negativeCount = error }
        catch { }
        let oversizedCount = try ConnectedComponents.keepingLargest(mask, count: 256)
        do { _ = try ConnectedComponents.removingSmaller(than: -1, from: mask) }
        catch let error as SegmentKitError { negativeVolume = error }
        catch { }
        do { _ = try ConnectedComponents.removingSmaller(than: .infinity, from: mask) }
        catch let error as SegmentKitError { nonFiniteVolume = error }
        catch { }

        #expect(negativeCount == .invalidComponentCount(-1))
        #expect(oversizedCount.labels == mask.labels)
        #expect(negativeVolume == .invalidMinimumComponentVolumeMM3(-1))
        #expect(nonFiniteVolume == .invalidMinimumComponentVolumeMM3(.infinity))
    }

    @Test("L'errore di conteggio spiega il solo limite negativo")
    func componentCountErrorDescriptionNamesNegativeLimit() {
        let negative = SegmentKitError.invalidComponentCount(-1).errorDescription ?? ""

        #expect(negative.localizedCaseInsensitiveContains("negativ"))
    }

    @Test("Le statistiche usano GV, varianza campionaria e la geometria esatta")
    func statisticsUseSampleVarianceAndRejectIncompatibleGeometry() throws {
        let geometry = try makeAnalysisGeometry(columns: 3, rows: 1, slices: 1)
        let volume = try Volume(
            geometry: geometry, samples: [1, 2, 4], rescaleSlope: -2, rescaleIntercept: 10
        )
        var mask = try #require(VolumeMask(geometry: geometry))
        for i in 0..<3 { mask.setLabel(5, i: i, j: 0, k: 0) }

        let statistics = try #require(try MaskAnalysis.statistics(of: volume, within: mask, label: nil))
        #expect(statistics.meanDensity == 10.0 - (14.0 / 3.0))
        #expect(abs(statistics.standardDeviation - 3.055050463303893) < 1e-12)
        #expect(statistics.minimumDensity == 2)
        #expect(statistics.maximumDensity == 8)
        #expect(statistics.densityUnitSymbol == "GV")

        let otherGeometry = try makeAnalysisGeometry(columns: 2, rows: 1, slices: 1)
        let otherMask = try #require(VolumeMask(geometry: otherGeometry))
        var caught: SegmentKitError?
        do {
            _ = try MaskAnalysis.statistics(of: volume, within: otherMask, label: nil)
        } catch let error as SegmentKitError {
            caught = error
        } catch {
        }
        #expect(caught == .incompatibleGeometry)
    }

    @Test("Una label richiesta seleziona il valore esatto, incluso lo sfondo")
    func statisticsCanSelectBackgroundExplicitly() throws {
        let geometry = try makeAnalysisGeometry(columns: 2, rows: 1, slices: 1)
        let volume = try Volume(geometry: geometry, samples: [10, 30])
        var mask = try #require(VolumeMask(geometry: geometry))
        mask.setLabel(1, i: 1, j: 0, k: 0)

        let statistics = try #require(try MaskAnalysis.statistics(of: volume, within: mask, label: 0))

        #expect(statistics.voxelCount == 1)
        #expect(statistics.meanDensity == 10)
        let absent = try MaskAnalysis.statistics(of: volume, within: mask, label: 2)
        #expect(absent == nil)
    }

    @Test("Un'area omogenea restituisce 1200 GV e deviazione standard nulla")
    func homogeneousStatisticsHaveZeroDeviationInGreyValues() throws {
        let volume = try SyntheticVolume.makePhantom(
            columns: 120, rows: 120, slices: 120, spacingMM: Vec3(0.5, 0.5, 0.5)
        )
        let halfEdge = SyntheticVolume.cubeEdgeMM / 2
        let mask = try makeAnalyticPatientBoxMask(
            geometry: volume.geometry,
            box: BoxMM(
                minMM: Vec3(-halfEdge, -halfEdge, -halfEdge),
                maxMM: Vec3(halfEdge, halfEdge, halfEdge)
            ),
            label: 3
        )

        let statistics = try #require(try MaskAnalysis.statistics(of: volume, within: mask, label: nil))
        let expectedVoxelCount = try #require(mask.voxelCounts()[3])

        #expect(statistics.meanDensity == 1200)
        #expect(statistics.standardDeviation == 0)
        #expect(statistics.densityUnitSymbol == "GV")
        #expect(statistics.voxelCount == expectedVoxelCount)
        #expect(statistics.volumeMM3 == mask.volumeMM3(label: 3))
        #expect(statistics.volumeMM3 == 8_000)
    }
}

private func fillSphere(in mask: inout VolumeMask, center: Vec3, radiusMM: Double, label: SegmentLabel) {
    let geometry = mask.geometry
    for k in 0..<geometry.sliceCount {
        for j in 0..<geometry.rowCount {
            for i in 0..<geometry.columnCount where geometry.patientPoint(i: i, j: j, k: k)
                .distance(to: center) <= radiusMM {
                mask.setLabel(label, i: i, j: j, k: k)
            }
        }
    }
}

private func makeAnalysisGeometry(
    columns: Int, rows: Int, slices: Int, rotated: Bool = false
) throws -> VolumeGeometry {
    let orientation = try #require(SliceOrientation(
        columnDirection: rotated ? Vec3(0, 1, 0) : Vec3(1, 0, 0),
        rowDirection: rotated ? Vec3(-1, 0, 0) : Vec3(0, 1, 0)
    ))
    return try VolumeGeometry(
        columnCount: columns,
        rowCount: rows,
        sliceCount: slices,
        columnSpacingMM: 2,
        rowSpacingMM: 1.5,
        sliceSpacingMM: 2,
        orientation: orientation,
        originMM: Vec3(11, -3, 7)
    )
}
