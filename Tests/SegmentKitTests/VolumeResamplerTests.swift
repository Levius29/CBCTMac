import DICOMCore
import Foundation
import Testing

@testable import SegmentKit

@Suite("Ricampionamento del volume")
struct VolumeResamplerTests {
    @Test("I preset comprendono tutti i passi richiesti")
    func spacingPresetsCoverRequiredValues() {
        for spacing in [0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.75, 1.0] {
            #expect(VolumeResampler.spacingPresetsMM.contains(spacing))
        }
    }

    @Test("La densità resta nello stesso punto Patient ai tre passi")
    func patientGeometryDoesNotMove() throws {
        let source = try makeLinearDensityVolume()
        let point = source.geometry.patientPoint(fromVoxel: Vec3(8.3, 7.4, 6.2))
        let expected = try #require(source.interpolatedDensityValue(atPatient: point))

        for spacing in [0.15, 0.3, 0.5] {
            let result = try VolumeResampler.resampled(
                source,
                request: ResampleRequest(spacingMM: spacing)
            )
            let actual = try #require(result.interpolatedDensityValue(atPatient: point))
            #expect(abs(actual - expected) <= 1.0)
        }
    }

    @Test("La geometria Patient resta corretta con assi realmente ruotati")
    func rotatedPatientGeometryDoesNotMove() throws {
        let source = try makeLinearDensityVolume(rotated: true)
        let point = source.geometry.patientPoint(fromVoxel: Vec3(8.3, 7.4, 6.2))
        let expected = try #require(source.interpolatedDensityValue(atPatient: point))

        for spacing in [0.15, 0.3, 0.5] {
            let result = try VolumeResampler.resampled(
                source,
                request: ResampleRequest(spacingMM: spacing)
            )
            let actual = try #require(result.interpolatedDensityValue(atPatient: point))
            #expect(abs(actual - expected) <= 1.0)
            #expect(result.geometry.orientation == source.geometry.orientation)
        }
    }

    @Test("Il cubo resta venti millimetri e 1200 GV")
    func phantomCubeKeepsSizeAndDensity() throws {
        let source = try SyntheticVolume.makePhantom(
            columns: 220,
            rows: 220,
            slices: 220,
            spacingMM: Vec3(0.1, 0.1, 0.1)
        )

        for spacing in [0.15, 0.3, 0.5] {
            let result = try VolumeResampler.resampled(
                source,
                request: ResampleRequest(spacingMM: spacing)
            )
            let edge = try #require(foregroundExtentX(result, densityRange: 1100...1300))
            let centreDensity = try #require(result.interpolatedDensityValue(atPatient: .zero))
            #expect(abs(edge - 20.0) <= spacing)
            #expect(abs(centreDensity - 1200) <= 0.5)
            #expect(result.geometry.columnSpacingMM == spacing)
            #expect(result.geometry.rowSpacingMM == spacing)
            #expect(result.geometry.sliceSpacingMM == spacing)
            #expect(result.rescaleSlope == source.rescaleSlope)
            #expect(result.rescaleIntercept == source.rescaleIntercept)
            #expect(result.densityUnit == source.densityUnit)
        }
    }

    @Test("I conteggi coprono il box richiesto")
    func requestedSpacingCoversRegion() throws {
        let source = try makeLinearDensityVolume()
        let minimum = source.geometry.patientPoint(fromVoxel: Vec3(2.0, 3.0, 4.0))
        let maximum = source.geometry.patientPoint(fromVoxel: Vec3(12.0, 11.0, 10.0))
        let box = BoxMM(minMM: minimum, maxMM: maximum)
        let result = try VolumeResampler.resampled(
            source,
            request: ResampleRequest(spacingMM: 0.5, regionMM: box)
        )

        #expect(result.geometry.columnCount == 8)
        #expect(result.geometry.rowCount == 8)
        #expect(result.geometry.sliceCount == 8)
        #expect(result.geometry.physicalSizeMM.x >= 4.0)
        #expect(result.geometry.physicalSizeMM.y >= 4.0)
        #expect(result.geometry.physicalSizeMM.z >= 3.6)
    }

    @Test("Il downsampling media la struttura periodica invece di invertirne il contrasto")
    func downsamplingUsesCellAverage() throws {
        let orientation = try #require(SliceOrientation(
            columnDirection: Vec3(1, 0, 0),
            rowDirection: Vec3(0, 1, 0)
        ))
        let geometry = try VolumeGeometry(
            columnCount: 9,
            rowCount: 1,
            sliceCount: 1,
            columnSpacingMM: 1,
            rowSpacingMM: 1,
            sliceSpacingMM: 1,
            orientation: orientation,
            originMM: .zero
        )
        let source = try Volume(
            geometry: geometry,
            samples: [0, 1000, 0, 1000, 0, 1000, 0, 1000, 0]
        )
        // Il ritaglio colloca i nuovi centri sugli indici dispari 1, 3, 5 e 7. Un semplice
        // campionamento puntuale vede quindi sempre 1000, mentre ogni cella contiene anche 0.
        let region = BoxMM(
            minMM: Vec3(0.5, -0.5, -0.5),
            maxMM: Vec3(7.5, 0.5, 0.5)
        )
        let result = try VolumeResampler.resampled(
            source,
            request: ResampleRequest(spacingMM: 2, regionMM: region)
        )
        var pointSamples = [Int16]()
        for i in 0..<result.geometry.columnCount {
            let point = result.geometry.patientPoint(i: i, j: 0, k: 0)
            let density = source.densityValue(atPatient: point) ?? 0
            pointSamples.append(Int16(clamping: Int(density.rounded())))
        }

        #expect(result.samples == [500, 500, 500, 500])
        #expect(pointSamples == [1000, 1000, 1000, 1000])
    }

    @Test("Gli input invalidi falliscono prima dell'allocazione")
    func invalidRequestsThrowNamedErrors() throws {
        let source = try makeLinearDensityVolume()
        for spacing in [0.0, -0.1, Double.nan, Double.infinity] {
            var caught: ResampleError?
            do {
                _ = try VolumeResampler.resampled(
                    source,
                    request: ResampleRequest(spacingMM: spacing)
                )
            } catch let error as ResampleError {
                caught = error
            } catch {
            }
            guard let caught else {
                Issue.record("Era atteso invalidSpacing per \(spacing).")
                continue
            }
            guard case .invalidSpacing = caught else {
                Issue.record("Era atteso invalidSpacing per \(spacing).")
                continue
            }
        }

        let outside = BoxMM(minMM: Vec3(1000, 1000, 1000), maxMM: Vec3(1001, 1001, 1001))
        var empty: ResampleError?
        do {
            _ = try VolumeResampler.resampled(
                source,
                request: ResampleRequest(spacingMM: 0.2, regionMM: outside)
            )
        } catch let error as ResampleError {
            empty = error
        } catch {
        }
        #expect(empty == .emptyRegion)

        var excessive: ResampleError?
        do {
            _ = try VolumeResampler.resampled(
                source,
                request: ResampleRequest(spacingMM: 1, maximumVoxelCount: 7)
            )
        } catch let error as ResampleError {
            excessive = error
        } catch {
        }
        #expect(excessive == .tooManyVoxels(requested: 990, limit: 7))
    }
}
